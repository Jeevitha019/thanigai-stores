import { Pool, PoolClient } from 'pg';
import { insertAuditEvent } from './audit';
import { HttpError } from './auth';
import { getDatabasePool } from './database';
import { StockProduct, StockRepository } from './stock-types';

interface StockRow {
  product_id: string;
  name: string;
  sku: string | null;
  unit: string;
  opening_quantity: string;
  opening_remaining_quantity: string;
  opening_purchase_price: string;
  total_quantity: string;
}

interface BatchRow {
  id: string;
  batch_type: 'opening' | 'purchase';
  received_quantity: string;
  remaining_quantity: string;
  purchase_price: string;
  purchase_date: string;
}

async function getStock(
  client: PoolClient,
  productId?: string,
): Promise<StockProduct[]> {
  const result = await client.query<StockRow>(
    `SELECT product.id AS product_id, product.name, product.sku, product.unit,
            product.opening_stock_quantity::text AS opening_quantity,
            COALESCE(opening.remaining_quantity, 0)::text AS opening_remaining_quantity,
            COALESCE(opening.purchase_price, product.purchase_price)::text AS opening_purchase_price,
            product.stock_quantity::text AS total_quantity
     FROM products product
     LEFT JOIN stock_batches opening
       ON opening.product_id = product.id AND opening.batch_type = 'opening'
     WHERE product.is_active = TRUE AND ($1::bigint IS NULL OR product.id = $1)
     ORDER BY LOWER(product.name), product.id`,
    [productId ?? null],
  );
  const products: StockProduct[] = [];
  for (const row of result.rows) {
    const purchases = await client.query<BatchRow>(
      `SELECT id, batch_type, received_quantity::text,
              remaining_quantity::text, purchase_price::text,
              purchased_at::date::text AS purchase_date
       FROM stock_batches
       WHERE product_id = $1 AND batch_type = 'purchase'
       ORDER BY purchased_at, id`,
      [row.product_id],
    );
    products.push({
      productId: row.product_id,
      name: row.name,
      sku: row.sku,
      unit: row.unit,
      openingQuantity: row.opening_quantity,
      openingRemainingQuantity: row.opening_remaining_quantity,
      openingPurchasePrice: row.opening_purchase_price,
      totalQuantity: row.total_quantity,
      purchases: purchases.rows.map((batch) => ({
        id: batch.id,
        type: batch.batch_type,
        quantity: batch.received_quantity,
        remainingQuantity: batch.remaining_quantity,
        purchasePrice: batch.purchase_price,
        purchaseDate: batch.purchase_date,
      })),
    });
  }
  return products;
}

export function createPostgresStockRepository(
  getPool: () => Pool = getDatabasePool,
): StockRepository {
  return {
    async list() {
      const client = await getPool().connect();
      try {
        return await getStock(client);
      } finally {
        client.release();
      }
    },

    async setOpeningStock(productId, quantity, purchasePrice, actorId) {
      return inTransaction(getPool, async (client) => {
      const product = await client.query<{
        id: string;
        unit: string;
        opening_stock_quantity: string;
        stock_quantity: string;
        purchase_price: string;
        created_at: Date;
      }>(
        `SELECT id, unit, opening_stock_quantity::text, stock_quantity::text,
                purchase_price::text, created_at
         FROM products WHERE id = $1 AND is_active = TRUE FOR UPDATE`,
        [productId],
      );
      const row = product.rows[0];
      if (!row) return null;

      const existing = await client.query<{
        id: string;
        received_quantity: string;
        remaining_quantity: string;
      }>(
        `SELECT id, received_quantity::text, remaining_quantity::text
         FROM stock_batches WHERE product_id = $1 AND batch_type = 'opening'
         FOR UPDATE`,
        [productId],
      );
      const batch = existing.rows[0];
      const previousReceived = BigInt(
        decimalToMilli(batch?.received_quantity ?? '0'),
      );
      const previousRemaining = BigInt(
        decimalToMilli(batch?.remaining_quantity ?? '0'),
      );
      const nextReceived = BigInt(decimalToMilli(quantity));
      const sold = previousReceived - previousRemaining;
      if (nextReceived < sold) {
        throw new HttpError(
          409,
          'Opening stock cannot be set below the quantity already sold from it.',
        );
      }
      const nextRemaining = nextReceived - sold;
      const delta = nextRemaining - previousRemaining;

      if (batch) {
        await client.query(
          `UPDATE stock_batches
           SET received_quantity = $2, remaining_quantity = $3,
               purchase_quantity = $2, purchase_unit = $5,
               purchase_price = $4, updated_at = NOW()
           WHERE id = $1`,
          [
            batch.id,
            quantity,
            milliToDecimal(nextRemaining),
            purchasePrice,
            row.unit,
          ],
        );
      } else {
        const inserted = await client.query<{ id: string }>(
          `INSERT INTO stock_batches (
             product_id, batch_type, received_quantity, remaining_quantity,
             purchase_quantity, purchase_unit, purchase_price, purchased_at,
             created_by
           ) VALUES ($1, 'opening', $2, $3, $2, $4, $5, $6, $7)
           RETURNING id`,
          [
            productId,
            quantity,
            milliToDecimal(nextRemaining),
            row.unit,
            purchasePrice,
            row.created_at,
            actorId,
          ],
        );
        const batchId = inserted.rows[0]?.id;
        if (!batchId) throw new Error('Opening stock batch could not be saved.');
        if (delta !== 0n) {
          await client.query(
            `INSERT INTO inventory_movements (
               product_id, stock_batch_id, change_quantity, reason, created_by
             ) VALUES ($1, $2, $3, 'adjustment', $4)`,
            [productId, batchId, milliToDecimal(delta), actorId],
          );
        }
      }
      await client.query(
        `UPDATE products
         SET opening_stock_quantity = $2,
             stock_quantity = stock_quantity + $3,
             purchase_price = $4, updated_at = NOW()
         WHERE id = $1`,
        [productId, quantity, milliToDecimal(delta), purchasePrice],
      );
      if (batch && delta !== 0n) {
        await client.query(
          `INSERT INTO inventory_movements (
             product_id, stock_batch_id, change_quantity, reason, created_by
           ) VALUES ($1, $2, $3, 'adjustment', $4)`,
          [productId, batch.id, milliToDecimal(delta), actorId],
        );
      }
      await insertAuditEvent(client, {
        actorId,
        action: 'stock.opening.updated',
        entityType: 'product',
        entityId: productId,
        details: { quantity, purchasePrice },
      });
      return (await getStock(client, productId))[0] ?? null;
      });
    },

    async receivePurchase(productId, quantity, purchasePrice, purchaseDate, actorId) {
      return inTransaction(getPool, async (client) => {
      const product = await client.query<{ id: string; unit: string }>(
        'SELECT id, unit FROM products WHERE id = $1 AND is_active = TRUE FOR UPDATE',
        [productId],
      );
      if (!product.rows[0]) return null;
      const batch = await client.query<{ id: string }>(
        `INSERT INTO stock_batches (
           product_id, batch_type, received_quantity, remaining_quantity,
           purchase_quantity, purchase_unit, purchase_price, purchased_at,
           created_by
         ) VALUES ($1, 'purchase', $2, $2, $2, $3, $4, $5::date, $6)
         RETURNING id`,
        [
          productId,
          quantity,
          product.rows[0].unit,
          purchasePrice,
          purchaseDate,
          actorId,
        ],
      );
      const batchId = batch.rows[0]?.id;
      if (!batchId) throw new Error('Stock purchase could not be saved.');
      await client.query(
        `UPDATE products
         SET stock_quantity = stock_quantity + $2,
             purchase_price = $3, updated_at = NOW()
         WHERE id = $1`,
        [productId, quantity, purchasePrice],
      );
      await client.query(
        `INSERT INTO inventory_movements (
           product_id, stock_batch_id, change_quantity, reason, created_by
         ) VALUES ($1, $2, $3, 'new_purchase', $4)`,
        [productId, batchId, quantity, actorId],
      );
      await insertAuditEvent(client, {
        actorId,
        action: 'stock.purchase.received',
        entityType: 'product',
        entityId: productId,
        details: { quantity, purchasePrice, purchaseDate },
      });
      return (await getStock(client, productId))[0] ?? null;
      });
    },
  };
}

export const postgresStockRepository = createPostgresStockRepository();

function decimalToMilli(value: string): string {
  const [integer, fraction = ''] = value.split('.');
  return (BigInt(integer) * 1000n + BigInt(fraction.padEnd(3, '0'))).toString();
}

function milliToDecimal(value: bigint): string {
  return `${value / 1000n}.${(value % 1000n).toString().padStart(3, '0')}`;
}

async function inTransaction<T>(
  getPool: () => Pool,
  operation: (client: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await getPool().connect();
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
