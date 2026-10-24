import 'dotenv/config';
import bcrypt from 'bcryptjs';
import { randomUUID } from 'node:crypto';
import { after, before, it } from 'node:test';
import { equal, ok } from 'node:assert/strict';
import { Pool } from 'pg';
import request from 'supertest';
import { createApp } from './app';
import { getDatabasePool } from './database';
import { createPostgresAuthRepository } from './postgres-auth-repository';
import { ProductInput } from './product-types';

const testSecret = 'test-only-postgres-auth-secret-with-more-than-thirty-two-bytes';
const hasDatabaseConfig = Boolean(
  process.env.DB_HOST &&
    process.env.DB_NAME &&
    process.env.DB_USER &&
    process.env.DB_PASSWORD,
);
const schema = `auth_test_${randomUUID().replace(/-/g, '')}`;
let testPool: Pool | undefined;
let schemaCreated = false;

const sampleProduct: ProductInput = {
  name: 'Ponni Rice',
  sku: 'TS-PONNI-RICE',
  category: 'Rice & Grains',
  unit: 'kg',
  purchasePrice: '54.00',
  sellingPrice: '60.00',
  gstRate: '0.00',
};

before(async () => {
  if (!hasDatabaseConfig) return;

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
  await testPool.query(`
    CREATE TABLE app_users (
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      username VARCHAR(64) NOT NULL,
      password_hash TEXT NOT NULL,
      role VARCHAR(16) NOT NULL
    )
  `);
  await testPool.query(`
    CREATE TABLE products (
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      name VARCHAR(160) NOT NULL,
      sku VARCHAR(64),
      category VARCHAR(80) NOT NULL,
      unit VARCHAR(16) NOT NULL,
      purchase_price NUMERIC(12, 2) NOT NULL,
      selling_price NUMERIC(12, 2) NOT NULL,
      stock_quantity NUMERIC(12, 3) NOT NULL,
      low_stock_threshold NUMERIC(12, 3) NOT NULL,
      gst_rate NUMERIC(5, 2) NOT NULL
    )
  `);
  await testPool.query(
    'CREATE UNIQUE INDEX products_sku_lower_unique ON products (LOWER(sku))',
  );
  await testPool.query(`
    CREATE TABLE audit_logs (
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      actor_id BIGINT,
      action TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT,
      details JSONB NOT NULL DEFAULT '{}'::jsonb
    )
  `);
});

after(async () => {
  if (testPool) await testPool.end();
  if (schemaCreated) {
    await getDatabasePool().query(`DROP SCHEMA "${schema}" CASCADE`);
    await getDatabasePool().end();
  }
});

it(
  'commits initial Admin, one-time products, existing edits, and password updates in PostgreSQL',
  { skip: !hasDatabaseConfig },
  async () => {
    ok(testPool);
    const repository = createPostgresAuthRepository(() => testPool!);
    const createInitialAdmin = repository.createInitialAdmin;
    if (!createInitialAdmin) {
      throw new Error('PostgreSQL authentication operations are unavailable.');
    }
    await testPool.query(
      `INSERT INTO products (
         name, sku, category, unit, purchase_price, selling_price,
         stock_quantity, low_stock_threshold, gst_rate
       )
       VALUES ('Edited existing product', 'TS-EXISTING', 'Rice & Grains',
               'kg', 50.00, 99.00, 0, 0, 0)`,
    );

    const initialPasswordHash = await bcrypt.hash('old-password', 4);
    const admin = await createInitialAdmin.call(
      repository,
      'owner',
      initialPasswordHash,
      [
        sampleProduct,
        sampleProduct,
        {
          ...sampleProduct,
          name: 'Different name with existing code',
          sku: 'TS-EXISTING',
        },
      ],
    );
    equal(admin.username, 'owner');

    const products = await testPool.query<{
      name: string;
      sku: string | null;
      selling_price: string;
    }>(
      'SELECT name, sku, selling_price FROM products ORDER BY id',
    );
    equal(products.rowCount, 2);
    equal(products.rows[0].selling_price, '99.00');
    equal(products.rows[1].sku, sampleProduct.sku);
    equal(products.rows[1].selling_price, '60.00');

    const app = createApp({
      jwtSecret: testSecret,
      repository,
      loginLimit: 100,
    });
    const originalLogin = await request(app)
      .post('/auth/login')
      .send({ username: 'owner', password: 'old-password' })
      .expect(200);
    await request(app)
      .post('/auth/password')
      .set('Authorization', `Bearer ${originalLogin.body.token}`)
      .send({ currentPassword: 'old-password', newPassword: 'new-password' })
      .expect(200);

    const restartedApp = createApp({
      jwtSecret: testSecret,
      repository,
      loginLimit: 100,
    });
    await request(restartedApp)
      .post('/auth/login')
      .send({ username: 'owner', password: 'old-password' })
      .expect(401);
    await request(restartedApp)
      .post('/auth/login')
      .send({ username: 'owner', password: 'new-password' })
      .expect(200);

    const storedUser = await testPool.query<{ password_hash: string }>(
      'SELECT password_hash FROM app_users WHERE id = $1',
      [admin.id],
    );
    equal(storedUser.rowCount, 1);
    equal(await bcrypt.compare('new-password', storedUser.rows[0].password_hash), true);
    equal(await bcrypt.compare('old-password', storedUser.rows[0].password_hash), false);

    const auditEvents = await testPool.query<{ action: string }>(
      'SELECT action FROM audit_logs ORDER BY id',
    );
    equal(
      auditEvents.rows.map(({ action }) => action).join(','),
      'auth.initial_admin_created,product.created,auth.login,auth.password.changed,auth.login',
    );
  },
);
