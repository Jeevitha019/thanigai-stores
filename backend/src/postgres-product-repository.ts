import { PoolClient } from 'pg';
import { insertAuditEvent } from './audit';
import { getDatabasePool } from './database';
import { Product, ProductInput, ProductRepository, ProductUnit } from './product-types';

interface ProductRow {
  id: string;
  name: string;
  sku: string | null;
  category: string;
  unit: ProductUnit;
  purchase_price: string;
  selling_price: string;
  gst_rate: string;
  created_at: Date;
  updated_at: Date;
}

const columns = `
  id, name, sku, category, unit,
  purchase_price, selling_price, gst_rate, created_at, updated_at
`;

function toProduct(row: ProductRow): Product {
  return {
    id: row.id,
    name: row.name,
    sku: row.sku,
    category: row.category,
    unit: row.unit,
    purchasePrice: row.purchase_price,
    sellingPrice: row.selling_price,
    gstRate: row.gst_rate,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}

export const postgresProductRepository: ProductRepository = {
  async list(search) {
    const result = await getDatabasePool().query<ProductRow>(
      `SELECT ${columns}
       FROM products
       WHERE is_active = TRUE
         AND ($1 = '' OR name ILIKE '%' || $1 || '%'
              OR sku ILIKE '%' || $1 || '%'
              OR category ILIKE '%' || $1 || '%')
       ORDER BY LOWER(name), id`,
      [search],
    );
    return result.rows.map(toProduct);
  },

  async findById(id) {
    const result = await getDatabasePool().query<ProductRow>(
      `SELECT ${columns} FROM products WHERE id = $1 AND is_active = TRUE`,
      [id],
    );
    return result.rows[0] ? toProduct(result.rows[0]) : null;
  },

  async create(input: ProductInput, actorId?: string) {
    return inTransaction(async (client) => {
      const result = await client.query<ProductRow>(
        `INSERT INTO products (
           name, sku, category, unit, purchase_price, selling_price,
           stock_quantity, low_stock_threshold, gst_rate
         )
         VALUES ($1, $2, $3, $4, $5, $6, 0, 0, $7)
         RETURNING ${columns}`,
        [
          input.name,
          input.sku,
          input.category,
          input.unit,
          input.purchasePrice,
          input.sellingPrice,
          input.gstRate,
        ],
      );
      const row = result.rows[0];
      if (!row) throw new Error('Product could not be created.');
      await insertAuditEvent(client, {
        actorId: actorId ?? null,
        action: 'product.created',
        entityType: 'product',
        entityId: row.id,
        details: { sku: row.sku },
      });
      return toProduct(row);
    });
  },

  async update(id, input, actorId) {
    return inTransaction(async (client) => {
      const result = await client.query<ProductRow>(
        `UPDATE products SET
           name = $2,
           sku = $3,
           category = $4,
           unit = $5,
           purchase_price = $6,
           selling_price = $7,
           gst_rate = $8,
           updated_at = NOW()
         WHERE id = $1 AND is_active = TRUE
         RETURNING ${columns}`,
        [
          id,
          input.name,
          input.sku,
          input.category,
          input.unit,
          input.purchasePrice,
          input.sellingPrice,
          input.gstRate,
        ],
      );
      const row = result.rows[0];
      if (!row) return null;
      await insertAuditEvent(client, {
        actorId: actorId ?? null,
        action: 'product.updated',
        entityType: 'product',
        entityId: row.id,
        details: { sku: row.sku },
      });
      return toProduct(row);
    });
  },

  async softDelete(id, actorId) {
    return inTransaction(async (client) => {
      const result = await client.query<{ id: string; sku: string | null }>(
        `UPDATE products SET
           is_active = FALSE,
           deleted_at = NOW(),
           updated_at = NOW()
         WHERE id = $1 AND is_active = TRUE
         RETURNING id, sku`,
        [id],
      );
      const product = result.rows[0];
      if (!product) return false;
      await insertAuditEvent(client, {
        actorId: actorId ?? null,
        action: 'product.archived',
        entityType: 'product',
        entityId: product.id,
        details: { sku: product.sku },
      });
      return true;
    });
  },
};

async function inTransaction<T>(
  operation: (client: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await getDatabasePool().connect();
  try {
    await client.query('BEGIN');
    const result = await operation(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
