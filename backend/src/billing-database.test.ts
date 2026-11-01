import 'dotenv/config';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { after, before, it } from 'node:test';
import { deepStrictEqual, equal, ok, rejects } from 'node:assert/strict';
import { Pool } from 'pg';
import { CreateInvoiceRequest } from './billing-types';
import { getDatabasePool } from './database';
import { PostgresBillingRepository } from './postgres-billing-repository';
import { createPostgresStockRepository } from './postgres-stock-repository';
import { centsToMoney, lineTotalCents } from './billing-validation';

const isConfigured = Boolean(
  process.env.DB_HOST &&
    process.env.DB_NAME &&
    process.env.DB_USER &&
    process.env.DB_PASSWORD,
);
const schema = `billing_test_${randomUUID().replace(/-/g, '')}`;
let testPool: Pool | undefined;
let repository: PostgresBillingRepository | undefined;
let productId = '';
let configuredProductId = '';
let optionalCodeProductId = '';
let fifoProductId = '';
let testSchemaCreated = false;

before(async () => {
  if (!isConfigured) return;

  const adminPool = getDatabasePool();
  await adminPool.query(`CREATE SCHEMA "${schema}"`);
  testSchemaCreated = true;
  testPool = new Pool({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT ?? '5432'),
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    options: `-c search_path=${schema}`,
  });
  repository = new PostgresBillingRepository(testPool);

  await testPool.query(`
    CREATE TABLE app_users (
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      username TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL
    )
  `);
  await testPool.query(
    "INSERT INTO app_users (username, password_hash, role) VALUES ('test-cashier', 'test-hash', 'cashier')",
  );

  for (const migration of [
    '002_create_products.sql',
    '003_create_invoices.sql',
    '004_gst_payments.sql',
    '005_receipt_cashier_snapshot.sql',
    '006_reports_inventory_audit.sql',
    '007_optional_product_codes_stock_settings.sql',
    '008_business_invoice_totals.sql',
    '009_business_phone.sql',
    '010_custom_product_gst_rates.sql',
    '011_shop_gst_rate.sql',
    '012_void_invoices.sql',
    '013_product_selling_quantities.sql',
    '014_stock_batches.sql',
    '016_stock_purchase_units.sql',
  ]) {
    const sql = await readFile(
      path.resolve(__dirname, '../migrations', migration),
      'utf8',
    );
    await testPool.query(sql);
  }
  await testPool.query(
    'UPDATE shop_settings SET stock_tracking_enabled = TRUE WHERE id = 1',
  );

  const product = await testPool.query<{ id: string }>(
    `INSERT INTO products (
       name, sku, category, unit, purchase_price, selling_price,
       stock_quantity, low_stock_threshold, gst_rate
     ) VALUES ('TEST ONLY - Snapshot Apples', 'BILLING-TEST-1', 'Fruit', 'kg', 1.00, 2.50, 100.000, 1.000, 0)
     RETURNING id`,
  );
  productId = product.rows[0].id;
  const configuredProduct = await testPool.query<{ id: string }>(
    `INSERT INTO products (
       name, sku, category, unit, purchase_price, selling_price,
       selling_quantity, stock_quantity, low_stock_threshold, gst_rate
     ) VALUES ('TEST ONLY - Rice 100g', 'BILLING-TEST-RICE', 'Test', 'g', 1.00, 8.00, 100.000, 1000.000, 0.000, 0)
     RETURNING id`,
  );
  configuredProductId = configuredProduct.rows[0].id;
  await testPool.query(
    `INSERT INTO products (
       name, sku, category, unit, purchase_price, selling_price,
       stock_quantity, low_stock_threshold, gst_rate
     ) VALUES ('TEST ONLY - Test Piece', 'BILLING-TEST-PIECE', 'Test', 'piece', 1.00, 2.50, 4.000, 1.000, 0)`,
  );
  const optionalCodeProduct = await testPool.query<{ id: string }>(
    `INSERT INTO products (
       name, sku, category, unit, purchase_price, selling_price,
       stock_quantity, low_stock_threshold, gst_rate
     ) VALUES ('TEST ONLY - No Code', NULL, 'Test', 'piece', 1.00, 2.50, 10.000, 0.000, 0)
     RETURNING id`,
  );
  optionalCodeProductId = optionalCodeProduct.rows[0].id;
  const fifoProduct = await testPool.query<{ id: string }>(
    `INSERT INTO products (
       name, sku, category, unit, purchase_price, selling_price,
       selling_quantity, opening_stock_quantity, stock_quantity,
       low_stock_threshold, gst_rate
     ) VALUES ('TEST ONLY - FIFO Oil', 'BILLING-TEST-FIFO', 'Test',
               'litre', 45.00, 120.00, 1.000, 0.000, 0.000, 0.000, 0)
     RETURNING id`,
  );
  fifoProductId = fifoProduct.rows[0].id;
  await testPool.query(
    `INSERT INTO stock_batches (
       product_id, batch_type, received_quantity, remaining_quantity,
       purchase_quantity, purchase_unit, purchase_price, purchased_at
     )
     SELECT id, 'opening', stock_quantity, stock_quantity, stock_quantity,
            unit, purchase_price, created_at
     FROM products
     WHERE name LIKE 'TEST ONLY - %'
       AND NOT EXISTS (
         SELECT 1 FROM stock_batches batch
         WHERE batch.product_id = products.id
       )`,
  );
});

after(async () => {
  if (testPool) await testPool.end();
  if (testSchemaCreated) {
    await getDatabasePool().query(`DROP SCHEMA "${schema}" CASCADE`);
  }
});

function invoiceRequest(
  idempotencyKey: string,
  quantity: string,
  method: 'cash' | 'upi' | 'card' = 'cash',
): CreateInvoiceRequest {
  return {
    idempotencyKey,
    items: [{ productId, quantity }],
    saleStateCode: '00',
    discountAmount: '0.00',
    gstAmount: '0.00',
    payments: [
      {
        method,
        amount: centsToMoney(lineTotalCents('2.50', quantity)),
      },
    ],
  };
}

it(
  'uses transactions, preserves snapshots, deducts stock, and numbers concurrent invoices sequentially',
  { skip: !isConfigured },
  async () => {
    ok(repository);
    await repository.updateGstSettings({
      gstEnabled: false,
      gstRate: '0.00',
      priceMode: 'exclusive',
      stateCode: '33',
      businessName: 'Test Shop',
      businessAddress: '',
      businessPhone: '555-0100',
      gstin: '',
    });
    const firstKey = randomUUID();
    const first = await repository.createInvoice(
      '1',
      invoiceRequest(firstKey, '1.125'),
    );
    ok(/^INV-\d{4}-00000001$/.test(first.invoice.invoiceNumber));
    equal(first.invoice.items[0].productName, 'TEST ONLY - Snapshot Apples');
    equal(first.invoice.items[0].unitPrice, '2.500000');
    equal(first.invoice.items[0].quantity, '1.125');
    equal(first.invoice.items[0].lineTotal, '2.81');
    equal(first.invoice.cashierName, 'test-cashier');
    equal(first.invoice.businessPhone, '555-0100');
    const repeatedRead = await repository.findInvoiceById(first.invoice.id);
    ok(repeatedRead);
    equal(repeatedRead.invoiceNumber, first.invoice.invoiceNumber);
    equal(repeatedRead.payments[0].amount, first.invoice.payments[0].amount);
    const recordedSale = await testPool!.query<{
      change_quantity: string;
      reason: string;
      invoice_id: string;
    }>(
      `SELECT change_quantity, reason, invoice_id
       FROM inventory_movements
       WHERE invoice_id = $1`,
      [first.invoice.id],
    );
    deepStrictEqual(recordedSale.rows, [
      {
        change_quantity: '-1.125',
        reason: 'sale',
        invoice_id: first.invoice.id,
      },
    ]);
    const invoiceAudit = await testPool!.query<{ action: string }>(
      `SELECT action FROM audit_logs
       WHERE entity_type = 'invoice' AND entity_id = $1`,
      [first.invoice.id],
    );
    equal(invoiceAudit.rows[0]?.action, 'invoice.created');
    await testPool!.end();
    testPool = new Pool({
      host: process.env.DB_HOST,
      port: Number(process.env.DB_PORT ?? '5432'),
      database: process.env.DB_NAME,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      options: `-c search_path=${schema}`,
    });
    repository = new PostgresBillingRepository(testPool);
    const afterPoolRestart = await repository.findInvoiceById(first.invoice.id);
    ok(afterPoolRestart);
    equal(afterPoolRestart.invoiceNumber, first.invoice.invoiceNumber);
    equal(afterPoolRestart.grandTotal, first.invoice.grandTotal);
    const persistedStock = await testPool.query<{ stock_quantity: string }>(
      'SELECT stock_quantity FROM products WHERE id = $1',
      [productId],
    );
    equal(persistedStock.rows[0].stock_quantity, '98.875');
    const beforeReprint = await testPool!.query(
      `SELECT
         (SELECT COUNT(*) FROM invoices) AS invoice_count,
         (SELECT COUNT(*) FROM invoice_payments) AS payment_count,
         (SELECT stock_quantity FROM products WHERE id = $1) AS stock_quantity`,
      [productId],
    );
    const reprinted = await repository.findInvoiceById(first.invoice.id);
    ok(reprinted);
    equal(reprinted.invoiceNumber, first.invoice.invoiceNumber);
    const afterReprint = await testPool!.query(
      `SELECT
         (SELECT COUNT(*) FROM invoices) AS invoice_count,
         (SELECT COUNT(*) FROM invoice_payments) AS payment_count,
         (SELECT stock_quantity FROM products WHERE id = $1) AS stock_quantity`,
      [productId],
    );
    deepStrictEqual(afterReprint.rows, beforeReprint.rows);

    await testPool!.query(
      "UPDATE products SET name = 'Renamed Apples', selling_price = 8.00 WHERE id = $1",
      [productId],
    );
    const replay = await repository.createInvoice(
      '1',
      invoiceRequest(firstKey, '1.125'),
    );
    equal(replay.replayed, true);
    equal(replay.invoice.invoiceNumber, first.invoice.invoiceNumber);
    equal(replay.invoice.items[0].productName, 'TEST ONLY - Snapshot Apples');
    equal(replay.invoice.items[0].unitPrice, '2.500000');
    await rejects(
      repository.createInvoice('1', invoiceRequest(firstKey, '1.000')),
    );
    const concurrentRetries = await Promise.all([
      repository.createInvoice('1', invoiceRequest(firstKey, '1.125')),
      repository.createInvoice('1', invoiceRequest(firstKey, '1.125')),
    ]);
    ok(concurrentRetries.every((result) => result.replayed));
    const listed = await repository.listInvoices(50);
    equal(listed.length, 1);
    equal(listed[0].items.length, 1);
    equal(listed[0].payments.length, 1);

    await testPool!.query(
      "UPDATE products SET selling_price = 2.50 WHERE id = $1",
      [productId],
    );
    const secondKey = randomUUID();
    const thirdKey = randomUUID();
    const [second, third] = await Promise.all([
      repository.createInvoice('1', invoiceRequest(secondKey, '1.000')),
      repository.createInvoice('1', invoiceRequest(thirdKey, '1.000')),
    ]);
    ok(second.invoice.invoiceNumber !== third.invoice.invoiceNumber);
    deepStrictEqual(
      [second.invoice, third.invoice]
        .map((invoice) => Number(invoice.invoiceNumber.split('-').at(-1)))
        .sort((a, b) => a - b),
      [2, 3],
    );

    it(
      'calculates proportional sale totals from the configured product quantity',
      { skip: !isConfigured },
      async () => {
        ok(repository);
        const request: CreateInvoiceRequest = {
          idempotencyKey: randomUUID(),
          items: [
            {
              productId: configuredProductId,
              quantity: '250.000',
              unitPrice: '8.00',
            },
          ],
          saleStateCode: '00',
          discountAmount: '0.00',
          gstAmount: '0.00',
          payments: [{ method: 'cash', amount: '20.00' }],
        };
        const { invoice } = await repository.createInvoice('1', request);
        equal(invoice.subtotal, '20.00');
        equal(invoice.items[0].quantity, '250.000');
        equal(invoice.items[0].unit, 'g');
        equal(invoice.items[0].unitPrice, '0.080000');
        equal(invoice.items[0].lineTotal, '20.00');
      },
    );

    const stock = await testPool!.query<{ stock_quantity: string }>(
      'SELECT stock_quantity FROM products WHERE id = $1',
      [productId],
    );
    equal(stock.rows[0].stock_quantity, '96.875');

    const piece = await testPool!.query<{ id: string }>(
      "SELECT id FROM products WHERE sku = 'BILLING-TEST-PIECE'",
    );
    const fractionalPiece = await repository.createInvoice('1', {
      idempotencyKey: randomUUID(),
      saleStateCode: '00',
      discountAmount: '0.00',
      gstAmount: '0.00',
      payments: [{ method: 'cash', amount: '1.25' }],
      items: [{ productId: piece.rows[0].id, quantity: '0.500' }],
    });
    equal(fractionalPiece.invoice.items[0].quantity, '0.500');
    const invoiceCount = await testPool!.query<{ count: string }>(
      'SELECT COUNT(*) AS count FROM invoices',
    );
    await rejects(
      repository.createInvoice('1', {
        ...invoiceRequest(randomUUID(), '2.000'),
        payments: [{ method: 'cash', amount: '1.00' }],
      }),
    );
    const afterFailure = await testPool!.query<{ count: string }>(
      'SELECT COUNT(*) AS count FROM invoices',
    );
    equal(afterFailure.rows[0].count, invoiceCount.rows[0].count);

    await testPool!.query(`
      CREATE FUNCTION reject_test_invoice_item() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'injected invoice item failure';
      END;
      $$ LANGUAGE plpgsql
    `);
    await testPool!.query(`
      CREATE TRIGGER reject_test_invoice_item
      BEFORE INSERT ON invoice_items
      FOR EACH ROW EXECUTE FUNCTION reject_test_invoice_item()
    `);
    await rejects(
      repository.createInvoice('1', invoiceRequest(randomUUID(), '0.500')),
    );
    const rolledBackStock = await testPool!.query<{ stock_quantity: string }>(
      'SELECT stock_quantity FROM products WHERE id = $1',
      [productId],
    );
    equal(rolledBackStock.rows[0].stock_quantity, '96.875');
    await testPool!.query('DROP TRIGGER reject_test_invoice_item ON invoice_items');
    await testPool!.query('DROP FUNCTION reject_test_invoice_item()');
  },
);

it(
  'snapshots GST settings, calculates split/state tax, stores payments once, and rolls failures back',
  { skip: !isConfigured },
  async () => {
    ok(repository);
    const piece = await testPool!.query<{ id: string }>(
      "SELECT id FROM products WHERE sku = 'BILLING-TEST-PIECE'",
    );
    const pieceId = piece.rows[0].id;
    await testPool!.query('UPDATE products SET gst_rate = 18.0 WHERE id = $1', [pieceId]);
    await repository.updateGstSettings({
      gstEnabled: true,
      gstRate: '7.50',
      priceMode: 'exclusive',
      stateCode: '33',
      businessName: 'Test Shop',
      businessAddress: 'Test address',
      businessPhone: '',
      gstin: '',
    });
    const request: CreateInvoiceRequest = {
      idempotencyKey: randomUUID(),
      saleStateCode: '33',
      discountAmount: '0.00',
      gstAmount: '0.00',
      items: [{ productId: pieceId, quantity: '1' }],
      payments: [
        { method: 'cash', amount: '1.00' },
        { method: 'upi', amount: '1.69' },
      ],
    };
    const intra = await repository.createInvoice('1', request);
    equal(intra.invoice.subtotal, '2.50');
    equal(intra.invoice.taxableAmount, '2.50');
    equal(intra.invoice.grandTotal, '2.69');
    equal(intra.invoice.cgstAmount, '0.10');
    equal(intra.invoice.sgstAmount, '0.09');
    equal(intra.invoice.payments.length, 2);
    const replay = await repository.createInvoice('1', request);
    equal(replay.replayed, true);
    equal(replay.invoice.payments.length, 2);

    await repository.updateGstSettings({
      gstEnabled: true,
      gstRate: '7.50',
      priceMode: 'inclusive',
      stateCode: '33',
      businessName: 'Test Shop',
      businessAddress: 'Test address',
      businessPhone: '',
      gstin: '',
    });
    const interstate = await repository.createInvoice('1', {
      idempotencyKey: randomUUID(),
      saleStateCode: '29',
      discountAmount: '0.00',
      gstAmount: '0.00',
      items: [{ productId: pieceId, quantity: '1' }],
      payments: [{ method: 'card', amount: '2.50' }],
    });
    equal(interstate.invoice.igstAmount, '0.17');
    equal(interstate.invoice.cgstAmount, '0.00');
    equal(interstate.invoice.sgstAmount, '0.00');
    equal(interstate.invoice.priceMode, 'inclusive');
    equal(interstate.invoice.shopStateCode, '33');
    equal(interstate.invoice.saleStateCode, '29');
    equal(interstate.invoice.items[0].gstRate, '7.50');

    await rejects(
      repository.createInvoice('1', {
        idempotencyKey: randomUUID(),
        saleStateCode: '33',
        discountAmount: '0.00',
        gstAmount: '0.00',
        items: [{ productId: pieceId, quantity: '1' }],
        payments: [{ method: 'cash', amount: '2.51' }],
      }),
    );
    const count = await testPool!.query<{ count: string }>(
      'SELECT COUNT(*) AS count FROM invoices',
    );
    equal(count.rows[0].count, '7');
  },
);

it(
  'applies a discount before Settings GST and saves the resulting snapshots',
  { skip: !isConfigured },
  async () => {
    ok(repository);
    await repository.updateGstSettings({
      gstEnabled: true,
      gstRate: '6.50',
      priceMode: 'exclusive',
      stateCode: '33',
      businessName: 'Test Shop',
      businessAddress: 'Test address',
      businessPhone: '',
      gstin: '',
    });
    const sale = await repository.createInvoice('1', {
      idempotencyKey: randomUUID(),
      saleStateCode: '33',
      discountAmount: '0.50',
      gstAmount: '0.00',
      items: [{ productId, quantity: '1.000' }],
      payments: [{ method: 'cash', amount: '2.13' }],
    });
    equal(sale.invoice.subtotal, '2.50');
    equal(sale.invoice.discountAmount, '0.50');
    equal(sale.invoice.taxableAmount, '2.00');
    equal(sale.invoice.totalTax, '0.13');
    equal(sale.invoice.grandTotal, '2.13');
    equal(sale.invoice.items[0].taxableAmount, '2.00');
    await rejects(
      repository.createInvoice('1', {
        idempotencyKey: randomUUID(),
        saleStateCode: '33',
        discountAmount: '2.51',
        gstAmount: '0.00',
        items: [{ productId, quantity: '1.000' }],
        payments: [{ method: 'cash', amount: '0.01' }],
      }),
    );
  },
);

it(
  'extracts Settings GST from discounted inclusive prices without adding it twice',
  { skip: !isConfigured },
  async () => {
    ok(repository);
    await repository.updateGstSettings({
      gstEnabled: true,
      gstRate: '5.00',
      priceMode: 'inclusive',
      stateCode: '33',
      businessName: 'Test Shop',
      businessAddress: 'Test address',
      businessPhone: '',
      gstin: '',
    });
    const sale = await repository.createInvoice('1', {
      idempotencyKey: randomUUID(),
      saleStateCode: '33',
      discountAmount: '0.50',
      gstAmount: '0.00',
      items: [{ productId, quantity: '1.000' }],
      payments: [{ method: 'cash', amount: '2.00' }],
    });
    equal(sale.invoice.subtotal, '2.50');
    equal(sale.invoice.discountAmount, '0.50');
    equal(sale.invoice.taxableAmount, '1.90');
    equal(sale.invoice.totalTax, '0.10');
    equal(sale.invoice.grandTotal, '2.00');
    equal(sale.invoice.items[0].taxableAmount, '1.90');
    equal(sale.invoice.items[0].lineTotal, '2.50');
  },
);

it(
  'keeps opening stock separate, receives dated batches, deducts FIFO stock, and restores voided sales',
  { skip: !isConfigured },
  async () => {
    ok(repository);
    const stockRepository = createPostgresStockRepository(() => testPool!);
    const opening = await stockRepository.setOpeningStock(
      fifoProductId,
      '100.000',
      '45.00',
      '1',
    );
    ok(opening);
    equal(opening.openingQuantity, '100.000');
    equal(opening.openingRemainingQuantity, '100.000');
    equal(opening.totalQuantity, '100.000');

    const received = await stockRepository.receivePurchase(
      fifoProductId,
      '100.000',
      '50.00',
      '2024-01-15',
      '1',
    );
    ok(received);
    equal(received.openingQuantity, '100.000');
    equal(received.purchases.length, 1);
    equal(received.purchases[0].quantity, '100.000');
    equal(received.purchases[0].remainingQuantity, '100.000');
    equal(received.totalQuantity, '200.000');

    const sale = await repository.createInvoice('1', {
      idempotencyKey: randomUUID(),
      saleStateCode: '33',
      discountAmount: '0.00',
      gstAmount: '0.00',
      items: [{ productId: fifoProductId, quantity: '150.000' }],
      payments: [{ method: 'cash', amount: '18000.00' }],
    });
    const afterSale = await stockRepository.list();
    const oil = afterSale.find((product) => product.productId === fifoProductId);
    ok(oil);
    equal(oil.openingRemainingQuantity, '0.000');
    equal(oil.purchases[0].remainingQuantity, '50.000');
    equal(oil.totalQuantity, '50.000');
    const saleMovements = await testPool!.query<{
      quantity: string;
      batch_type: string;
    }>(
      `SELECT movement.change_quantity::text AS quantity, batch.batch_type
       FROM inventory_movements movement
       JOIN stock_batches batch ON batch.id = movement.stock_batch_id
       WHERE movement.invoice_id = $1
       ORDER BY batch.batch_type`,
      [sale.invoice.id],
    );
    deepStrictEqual(saleMovements.rows, [
      { quantity: '-100.000', batch_type: 'opening' },
      { quantity: '-50.000', batch_type: 'purchase' },
    ]);

    await rejects(
      repository.createInvoice('1', {
        idempotencyKey: randomUUID(),
        saleStateCode: '33',
        discountAmount: '0.00',
        gstAmount: '0.00',
        items: [{ productId: fifoProductId, quantity: '51.000' }],
        payments: [{ method: 'cash', amount: '6120.00' }],
      }),
    );
    equal(
      (await stockRepository.list()).find(
        (product) => product.productId === fifoProductId,
      )?.totalQuantity,
      '50.000',
    );
    equal(await repository.voidInvoice(sale.invoice.id, '1'), true);
    const afterVoid = (await stockRepository.list()).find(
      (product) => product.productId === fifoProductId,
    );
    ok(afterVoid);
    equal(afterVoid.openingRemainingQuantity, '100.000');
    equal(afterVoid.purchases[0].remainingQuantity, '100.000');
    equal(afterVoid.totalQuantity, '200.000');
  },
);

it(
  'rejects sales beyond available stock without changing inventory',
  { skip: !isConfigured },
  async () => {
    ok(repository);
    await testPool!.query(
      'UPDATE shop_settings SET gst_enabled = FALSE, stock_tracking_enabled = TRUE WHERE id = 1',
    );
    const overstockRequest: CreateInvoiceRequest = {
      idempotencyKey: randomUUID(),
      saleStateCode: '33',
      discountAmount: '0.00',
      gstAmount: '0.00',
      items: [{ productId, quantity: '99.500' }],
      payments: [{ method: 'cash', amount: '248.75' }],
    };
    const idempotencyKey = randomUUID();
    await rejects(repository.createInvoice('1', {
      ...overstockRequest,
      idempotencyKey,
    }));

    const stock = await testPool!.query<{ stock_quantity: string }>(
      'SELECT stock_quantity FROM products WHERE id = $1',
      [productId],
    );
    equal(stock.rows[0].stock_quantity, '94.875');
  },
);

it(
  'allows a product without a code to be billed while preserving its legacy stock value',
  { skip: !isConfigured },
  async () => {
    ok(repository);
    await repository.updateGstSettings({
      gstEnabled: false,
      gstRate: '0.00',
      priceMode: 'exclusive',
      stateCode: '33',
      businessName: 'Test Shop',
      businessAddress: 'Test address',
      businessPhone: '',
      gstin: '',
    });
    await testPool!.query(
      await readFile(
        path.resolve(
          __dirname,
          '../migrations/007_optional_product_codes_stock_settings.sql',
        ),
        'utf8',
      ),
    );
    const sale = await repository.createInvoice('1', {
      idempotencyKey: randomUUID(),
      saleStateCode: '33',
      discountAmount: '0.00',
      gstAmount: '0.00',
      items: [{ productId: optionalCodeProductId, quantity: '2.000' }],
      payments: [{ method: 'cash', amount: '5.00' }],
    });
    equal(sale.invoice.gstEnabled, false);
    equal(sale.invoice.totalTax, '0.00');
    equal(sale.invoice.items[0].sku, '');
    const persisted = await testPool!.query<{
      stock_quantity: string;
      sku_snapshot: string;
    }>(
      `SELECT product.stock_quantity, item.sku_snapshot
       FROM products product
       JOIN invoice_items item ON item.product_id = product.id
       WHERE product.id = $1 AND item.invoice_id = $2`,
      [optionalCodeProductId, sale.invoice.id],
    );
    equal(persisted.rows[0].stock_quantity, '8.000');
    equal(persisted.rows[0].sku_snapshot, '');
  },
);

it(
  'voids an invoice transactionally while retaining its items, payments, and audit record',
  { skip: !isConfigured },
  async () => {
    ok(repository);
    const saved = await repository.createInvoice('1', {
      idempotencyKey: randomUUID(),
      saleStateCode: '33',
      discountAmount: '0.00',
      gstAmount: '0.00',
      items: [{ productId, quantity: '1.000' }],
      payments: [{ method: 'cash', amount: '2.50' }],
    });

    equal(await repository.voidInvoice(saved.invoice.id, '1'), true);
    equal(await repository.voidInvoice(saved.invoice.id, '1'), false);
    const retained = await repository.findInvoiceById(saved.invoice.id);
    ok(retained);
    equal(retained.invoiceNumber, saved.invoice.invoiceNumber);
    equal(retained.items.length, 1);
    equal(retained.payments.length, 1);
    const visibleInvoices = await repository.listInvoices(50);
    equal(
      visibleInvoices.some((invoice) => invoice.id === saved.invoice.id),
      false,
    );
    const audit = await testPool!.query<{ action: string; entity_id: string }>(
      `SELECT action, entity_id FROM audit_logs
       WHERE action = 'invoice.voided' AND entity_id = $1`,
      [saved.invoice.id],
    );
    deepStrictEqual(audit.rows, [
      { action: 'invoice.voided', entity_id: saved.invoice.id },
    ]);
  },
);

it(
  'allows fractional quantities for packet products',
  { skip: !isConfigured },
  async () => {
    ok(repository);
    const packet = await testPool!.query<{ id: string }>(
      `INSERT INTO products (
         name, sku, category, unit, purchase_price, selling_price,
         stock_quantity, low_stock_threshold, gst_rate
       ) VALUES ('TEST ONLY - Fractional packet', 'BILLING-TEST-PACKET',
                 'Test', 'packet', 1.00, 2.50, 5.000, 0.000, 0)
       RETURNING id`,
    );
    await testPool!.query(
      `INSERT INTO stock_batches (
         product_id, batch_type, received_quantity, remaining_quantity,
         purchase_quantity, purchase_unit, purchase_price, purchased_at
       )
       SELECT id, 'opening', stock_quantity, stock_quantity, stock_quantity,
              unit, purchase_price, created_at
       FROM products WHERE id = $1`,
      [packet.rows[0].id],
    );
    const sale = await repository.createInvoice('1', {
      idempotencyKey: randomUUID(),
      saleStateCode: '33',
      discountAmount: '0.00',
      gstAmount: '0.00',
      items: [{ productId: packet.rows[0].id, quantity: '2.500' }],
      payments: [{ method: 'cash', amount: '6.25' }],
    });
    equal(sale.invoice.items[0].quantity, '2.500');
  },
);
