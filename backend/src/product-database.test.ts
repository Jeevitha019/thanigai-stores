import 'dotenv/config';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { after, before, it } from 'node:test';
import { deepStrictEqual, equal, ok, rejects } from 'node:assert/strict';
import { getDatabasePool } from './database';
import { ProductInput } from './product-types';
import { postgresProductRepository } from './postgres-product-repository';

const hasDatabaseConfig = Boolean(
  process.env.DB_HOST &&
    process.env.DB_NAME &&
    process.env.DB_USER &&
    process.env.DB_PASSWORD,
);
const sku = `TEST-${randomUUID()}`;
let createdId: string | undefined;
let optionalCodeId: string | undefined;

const input: ProductInput = {
  name: 'TEST ONLY - Database CRUD',
  sku,
  category: 'Test',
  unit: 'piece',
  purchasePrice: '1.25',
  sellingPrice: '2.50',
  sellingQuantity: '1.000',
  gstRate: '5.00',
};

before(async () => {
  if (hasDatabaseConfig) {
    for (const file of [
      '006_reports_inventory_audit.sql',
      '007_optional_product_codes_stock_settings.sql',
      '013_product_selling_quantities.sql',
      '014_stock_batches.sql',
    ]) {
      const migration = await readFile(
        path.resolve(__dirname, `../migrations/${file}`),
        'utf8',
      );
      await getDatabasePool().query(migration);
    }
    await getDatabasePool().query('SELECT 1 FROM products LIMIT 0');
  }
});

after(async () => {
  if (createdId) {
    await getDatabasePool().query(
      "DELETE FROM audit_logs WHERE entity_type = 'product' AND entity_id = $1",
      [createdId],
    );
    await getDatabasePool().query(
      'DELETE FROM inventory_movements WHERE product_id = $1',
      [createdId],
    );
    await getDatabasePool().query('DELETE FROM products WHERE id = $1', [
      createdId,
    ]);
  }
  if (optionalCodeId) {
    await getDatabasePool().query(
      "DELETE FROM audit_logs WHERE entity_type = 'product' AND entity_id = $1",
      [optionalCodeId],
    );
    await getDatabasePool().query(
      'DELETE FROM inventory_movements WHERE product_id = $1',
      [optionalCodeId],
    );
    await getDatabasePool().query('DELETE FROM products WHERE id = $1', [
      optionalCodeId,
    ]);
  }
  if (hasDatabaseConfig) {
    await getDatabasePool().end();
  }
});

it(
  'performs product CRUD, search, duplicate handling, and soft delete in PostgreSQL',
  { skip: !hasDatabaseConfig },
  async () => {
    const created = await postgresProductRepository.create(input);
    createdId = created.id;
    equal(created.sku, sku);
    equal(created.purchasePrice, '1.25');
    equal(created.sellingQuantity, '1.000');
    ok(created.createdAt);

    const found = await postgresProductRepository.findById(created.id);
    deepStrictEqual(found, created);
    await getDatabasePool().query(
      'UPDATE products SET stock_quantity = 3.000, low_stock_threshold = 1.000 WHERE id = $1',
      [created.id],
    );

    const searched = await postgresProductRepository.list(sku.toLowerCase());
    equal(searched.length, 1);
    equal(searched[0].id, created.id);
    await rejects(
      postgresProductRepository.create(input),
      (error: unknown) =>
        typeof error === 'object' &&
        error !== null &&
        'code' in error &&
        error.code === '23505',
    );

    const updated = await postgresProductRepository.update(created.id, {
      ...input,
      name: 'TEST ONLY - Updated Database CRUD',
      sellingPrice: '3.75',
    });
    ok(updated);
    equal(updated.name, 'TEST ONLY - Updated Database CRUD');
    equal(updated.sellingPrice, '3.75');
    const legacyFields = await getDatabasePool().query<{
      stock_quantity: string;
      low_stock_threshold: string;
    }>(
      'SELECT stock_quantity, low_stock_threshold FROM products WHERE id = $1',
      [created.id],
    );
    deepStrictEqual(legacyFields.rows[0], {
      stock_quantity: '3.000',
      low_stock_threshold: '1.000',
    });
    const withoutCode = await postgresProductRepository.create({
      ...input,
      name: 'TEST ONLY - Product without code',
      sku: null,
    });
    optionalCodeId = withoutCode.id;
    equal(withoutCode.sku, null);
    const priceUpdated = await postgresProductRepository.update(
      withoutCode.id,
      { ...input, name: withoutCode.name, sku: null, sellingPrice: '4.25' },
    );
    equal(priceUpdated?.sellingPrice, '4.25');
    equal(await postgresProductRepository.softDelete(created.id), true);
    equal(await postgresProductRepository.findById(created.id), null);
    equal((await postgresProductRepository.list(sku)).length, 0);
    equal(await postgresProductRepository.softDelete(created.id), false);
    const archiveAudit = await getDatabasePool().query<{ action: string }>(
      `SELECT action FROM audit_logs
       WHERE entity_type = 'product' AND entity_id = $1
       ORDER BY id DESC LIMIT 1`,
      [created.id],
    );
    equal(archiveAudit.rows[0]?.action, 'product.archived');
  },
);
