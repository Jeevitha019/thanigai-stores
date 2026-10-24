import 'dotenv/config';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { after, before, it } from 'node:test';
import { deepStrictEqual, equal, ok } from 'node:assert/strict';
import { Pool } from 'pg';
import { getDatabasePool } from './database';
import { PostgresReportRepository } from './postgres-report-repository';

const isConfigured = Boolean(
  process.env.DB_HOST &&
    process.env.DB_NAME &&
    process.env.DB_USER &&
    process.env.DB_PASSWORD,
);
const schema = `reports_test_${randomUUID().replace(/-/g, '')}`;
let testPool: Pool | undefined;
let reports: PostgresReportRepository | undefined;
let schemaCreated = false;
let targetProductId = '';

before(async () => {
  if (!isConfigured) return;
  await getDatabasePool().query(`CREATE SCHEMA "${schema}"`);
  schemaCreated = true;
  testPool = new Pool({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT ?? '5432'),
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    options: `-c search_path=${schema}`,
  });
  reports = new PostgresReportRepository(testPool);
  await testPool.query(`
    CREATE TABLE app_users (
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      username TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL
    )
  `);
  const user = await testPool.query<{ id: string }>(
    `INSERT INTO app_users (username, password_hash, role)
     VALUES ('report-test-cashier', 'hash', 'cashier') RETURNING id`,
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
  ]) {
    await testPool.query(
      await readFile(
        path.resolve(__dirname, '../migrations', migration),
        'utf8',
      ),
    );
  }
  await testPool.query(
    'UPDATE shop_settings SET stock_tracking_enabled = TRUE WHERE id = 1',
  );

  const products = await testPool.query<{ id: string }>(
    `INSERT INTO products (
       name, sku, category, unit, purchase_price, selling_price,
       stock_quantity, low_stock_threshold, gst_rate
     )
     VALUES
       ('Low report rice', 'REPORT-RICE-LOW', 'Grains', 'kg', 10, 20, 1, 2, 0),
       ('Available report dhal', 'REPORT-DHAL-OK', 'Grains', 'kg', 5, 10, 8, 2, 0)
     RETURNING id`,
  );
  targetProductId = products.rows[0].id;
  const invoiceValues = [
    {
      date: '2026-10-19 12:00:00+00',
      number: 'REPORT-2026-01',
      total: '100.00',
    },
    {
      date: '2026-10-19 15:00:00+00',
      number: 'REPORT-2026-02',
      total: '300.00',
    },
    {
      date: '2026-10-20 12:00:00+00',
      number: 'REPORT-2026-03',
      total: '50.00',
    },
  ];
  const ids: string[] = [];
  for (const invoice of invoiceValues) {
    const saved = await testPool.query<{ id: string }>(
      `INSERT INTO invoices (
         invoice_number, idempotency_key, request_hash, created_by,
         cashier_name_snapshot, subtotal, grand_total, created_at
       )
       VALUES ($1, $2, repeat('a', 64), $3, 'report-test-cashier', $4, $4, $5)
       RETURNING id`,
      [
        invoice.number,
        randomUUID(),
        user.rows[0].id,
        invoice.total,
        invoice.date,
      ],
    );
    ids.push(saved.rows[0].id);
    await testPool.query(
      `INSERT INTO invoice_items (
         invoice_id, product_id, product_name_snapshot, sku_snapshot,
         unit_snapshot, unit_price, quantity, line_total
       )
       VALUES ($1, $2, 'Low report rice', 'REPORT-RICE-LOW', 'kg', $3, 1, $3)`,
      [saved.rows[0].id, targetProductId, invoice.total],
    );
  }
  await testPool.query(
    `INSERT INTO invoice_payments (invoice_id, method, amount, created_at)
     VALUES
       ($1, 'cash', 100, '2026-10-19 12:01:00+00'),
       ($2, 'upi', 100, '2026-10-19 15:01:00+00'),
       ($2, 'card', 200, '2026-10-19 15:02:00+00'),
       ($3, 'card', 50, '2026-10-20 12:01:00+00')`,
    ids,
  );
  await testPool.query(
    `INSERT INTO invoices (
       invoice_number, idempotency_key, request_hash, created_by,
       cashier_name_snapshot, subtotal, grand_total, created_at
     )
     VALUES (
       'REPORT-UNPAID-2026-10-19',
       $1,
       repeat('b', 64),
       $2,
       'report-test-cashier',
       999,
       999,
       '2026-10-19 18:00:00+00'
     )`,
    [randomUUID(), user.rows[0].id],
  );
  await testPool.query(
    `INSERT INTO inventory_movements (product_id, change_quantity, reason, created_by)
     VALUES ($1, -1, 'adjustment', $2)`,
    [targetProductId, user.rows[0].id],
  );
  await testPool.query(
    `INSERT INTO audit_logs (actor_id, action, entity_type, entity_id)
     VALUES ($1, 'test.event', 'report_test', 'fixture')`,
    [user.rows[0].id],
  );
});

after(async () => {
  await testPool?.end();
  if (schemaCreated) {
    await getDatabasePool().query(`DROP SCHEMA "${schema}" CASCADE`);
  }
});

it(
  'returns date-filtered exact sales totals, split method classification, and saved invoice details',
  { skip: !isConfigured },
  async () => {
    ok(reports);
    const sales = await reports.sales('2026-10-19', '2026-10-19');
    equal(sales.invoiceCount, 2);
    equal(sales.totalSales, '400.00');
    deepStrictEqual(
      sales.paymentSummary.map((row) => [row.method, row.invoiceCount, row.amount]),
      [
        ['cash', 1, '100.00'],
        ['upi', 0, '0.00'],
        ['card', 0, '0.00'],
        ['split', 1, '300.00'],
        ['unrecorded', 0, '0.00'],
      ],
    );
    equal(sales.invoices[0].invoiceNumber, 'REPORT-2026-02');
    equal(sales.invoices[0].paidAt, '2026-10-19T15:01:00.000Z');
    equal(sales.invoices[0].gstEnabled, false);
    equal(sales.invoices[0].items[0].productName, 'Low report rice');
    equal(sales.invoices[0].items[0].unit, 'kg');
    equal(sales.invoices[0].items[0].unitPrice, '300.00');
    equal(sales.invoices[0].discountAmount, '0.00');
    equal(typeof sales.invoices[0].paymentMethods[0].amount, 'string');
    equal(sales.invoices[0].paymentMethods[0].amount, '100.00');

    const dashboard = await reports.dashboard('2026-10-19');
    equal(dashboard.totalSales, '1399.00');
    equal(dashboard.invoiceCount, 3);
    equal(
      dashboard.paymentSummary.find((row) => row.method === 'unrecorded')
        ?.invoiceCount,
      1,
    );
    equal((await reports.auditLog(10))[0].action, 'test.event');
  },
);

it(
  'excludes voided invoices from sales and dashboard totals while retaining the invoice and payment',
  { skip: !isConfigured },
  async () => {
    ok(reports);
    const paidInvoice = await testPool!.query<{ id: string }>(
      'SELECT id FROM invoices WHERE invoice_number = $1',
      ['REPORT-2026-01'],
    );
    const invoiceId = paidInvoice.rows[0].id;
    await testPool!.query(
      `UPDATE invoices
       SET voided_at = NOW(), voided_by = 1, void_reason = 'Test void'
       WHERE id = $1`,
      [invoiceId],
    );

    const sales = await reports.sales('2026-10-19', '2026-10-19');
    equal(sales.invoiceCount, 1);
    equal(sales.totalSales, '300.00');
    equal(sales.invoices[0].invoiceNumber, 'REPORT-2026-02');
    equal(
      sales.paymentSummary.find((row) => row.method === 'cash')?.amount,
      '0.00',
    );
    const dashboard = await reports.dashboard('2026-10-19');
    equal(dashboard.invoiceCount, 2);
    equal(dashboard.totalSales, '1299.00');

    const retained = await testPool!.query(
      `SELECT
         (SELECT COUNT(*) FROM invoices WHERE id = $1) AS invoice_count,
         (SELECT COUNT(*) FROM invoice_payments WHERE invoice_id = $1) AS payment_count`,
      [invoiceId],
    );
    deepStrictEqual(retained.rows, [{ invoice_count: '1', payment_count: '1' }]);
  },
);
