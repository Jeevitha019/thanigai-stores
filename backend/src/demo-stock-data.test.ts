import 'dotenv/config';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { after, before, it } from 'node:test';
import { deepStrictEqual, equal, ok } from 'node:assert/strict';
import { Pool } from 'pg';
import { getDatabasePool } from './database';
import { seedDemoStockData } from './demo-stock-data';
import { PostgresReportRepository } from './postgres-report-repository';

const isConfigured = Boolean(
  process.env.DB_HOST &&
    process.env.DB_NAME &&
    process.env.DB_USER &&
    process.env.DB_PASSWORD,
);
const schema = `demo_stock_test_${randomUUID().replace(/-/g, '')}`;
let testPool: Pool | undefined;
let schemaCreated = false;

before(async () => {
  if (!isConfigured) return;

  const adminPool = getDatabasePool();
  await adminPool.query(`CREATE SCHEMA "${schema}"`);
  schemaCreated = true;
  testPool = new Pool({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT ?? '5432'),
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    options: `-c search_path=${schema}`,
  });
  await testPool.query(`
    CREATE TABLE app_users (
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      username TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL
    )
  `);
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
  ]) {
    await testPool.query(
      await readFile(
        path.resolve(__dirname, '../migrations', migration),
        'utf8',
      ),
    );
  }
  await testPool.query(
    `INSERT INTO app_users (username, password_hash, role)
     VALUES ('demo-stock-test-admin', 'test-hash', 'admin')`,
  );
});

after(async () => {
  await testPool?.end();
  if (schemaCreated) {
    await getDatabasePool().query(`DROP SCHEMA "${schema}" CASCADE`);
  }
});

it(
  'persists demo products and separate opening/new stock batches idempotently',
  { skip: !isConfigured },
  async () => {
    ok(testPool);
    const admin = await testPool.query<{ id: string }>(
      "SELECT id FROM app_users WHERE role = 'admin' LIMIT 1",
    );
    const actorId = admin.rows[0]?.id;
    ok(actorId);

    const firstRun = await seedDemoStockData(testPool, actorId);
    equal(firstRun.productsAdded, 55);
    equal(firstRun.batchesAdded, 110);
    const secondRun = await seedDemoStockData(testPool, actorId);
    deepStrictEqual(secondRun, { productsAdded: 0, batchesAdded: 0 });

    const persisted = await testPool.query<{
      product_count: string;
      batch_count: string;
      opening_batch_count: string;
      purchase_batch_count: string;
      product_stock_total: string;
      batch_stock_total: string;
    }>(
      `SELECT
         COUNT(DISTINCT product.id)::text AS product_count,
         COUNT(batch.id)::text AS batch_count,
         COUNT(batch.id) FILTER (WHERE batch.batch_type = 'opening')::text
           AS opening_batch_count,
         COUNT(batch.id) FILTER (WHERE batch.batch_type = 'purchase')::text
           AS purchase_batch_count,
         (
           SELECT SUM(stock_quantity)::text FROM products
           WHERE sku LIKE 'DEMO-TS-%'
         ) AS product_stock_total,
         (
           SELECT SUM(batch.remaining_quantity)::text
           FROM stock_batches batch
           JOIN products product ON product.id = batch.product_id
           WHERE product.sku LIKE 'DEMO-TS-%'
         ) AS batch_stock_total
       FROM products product
       JOIN stock_batches batch ON batch.product_id = product.id
       WHERE product.sku LIKE 'DEMO-TS-%'`,
    );
    equal(persisted.rows[0].product_count, '55');
    equal(persisted.rows[0].batch_count, '110');
    equal(persisted.rows[0].opening_batch_count, '55');
    equal(persisted.rows[0].purchase_batch_count, '55');

    const mismatched = await testPool.query(
      `SELECT product.id
       FROM products product
       JOIN stock_batches batch ON batch.product_id = product.id
       WHERE product.sku LIKE 'DEMO-TS-%'
       GROUP BY product.id, product.stock_quantity
       HAVING product.stock_quantity <> SUM(batch.remaining_quantity)`,
    );
    equal(mismatched.rowCount, 0);

    const besan = await testPool.query<{
      opening_quantity: string;
      purchase_quantity: string;
      total_quantity: string;
      purchase_price: string;
      selling_price: string;
      unit: string;
    }>(
      `SELECT
         MAX(batch.received_quantity) FILTER (
           WHERE batch.batch_type = 'opening'
         )::text AS opening_quantity,
         MAX(batch.received_quantity) FILTER (
           WHERE batch.batch_type = 'purchase'
         )::text AS purchase_quantity,
         product.stock_quantity::text AS total_quantity,
         product.purchase_price::text AS purchase_price,
         product.selling_price::text AS selling_price,
         product.unit
       FROM products product
       JOIN stock_batches batch ON batch.product_id = product.id
       WHERE product.name = 'Besan Flour'
       GROUP BY product.id`,
    );
    equal(besan.rows[0].opening_quantity, '100.000');
    equal(besan.rows[0].purchase_quantity, '100.000');
    equal(besan.rows[0].total_quantity, '200.000');
    equal(besan.rows[0].purchase_price, '72.00');
    equal(besan.rows[0].selling_price, '88.00');
    equal(besan.rows[0].unit, 'kg');

    const units = await testPool.query<{ unit: string }>(
      `SELECT DISTINCT unit FROM products
       WHERE sku LIKE 'DEMO-TS-%' ORDER BY unit`,
    );
    deepStrictEqual(
      units.rows.map(({ unit }) => unit),
      ['g', 'kg', 'litre', 'ml', 'packet', 'piece'],
    );

    const dashboard = await new PostgresReportRepository(testPool).dashboard(
      '2026-10-25',
    );
    equal(dashboard.stockProductCount, 55);
    equal(
      Number(persisted.rows[0].product_stock_total),
      Number(persisted.rows[0].batch_stock_total),
    );
  },
);
