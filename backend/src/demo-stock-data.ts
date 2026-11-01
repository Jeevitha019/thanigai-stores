import 'dotenv/config';
import { Pool } from 'pg';
import { insertAuditEvent } from './audit';
import { ProductUnit } from './product-types';

interface DemoProduct {
  name: string;
  category: string;
  unit: ProductUnit;
  purchasePrice: string;
  sellingPrice: string;
  sellingQuantity: string;
  openingQuantity: string;
  newQuantity: string;
  gstRate: string;
}

const demoProducts: DemoProduct[] = [
  { name: 'Ponni Raw Rice', category: 'Rice varieties', unit: 'kg', purchasePrice: '48.00', sellingPrice: '56.00', sellingQuantity: '1.000', openingQuantity: '120.000', newQuantity: '80.000', gstRate: '0.00' },
  { name: 'Ponni Boiled Rice', category: 'Rice varieties', unit: 'kg', purchasePrice: '50.00', sellingPrice: '59.00', sellingQuantity: '1.000', openingQuantity: '100.000', newQuantity: '75.000', gstRate: '0.00' },
  { name: 'Sona Masoori Rice', category: 'Rice varieties', unit: 'kg', purchasePrice: '54.00', sellingPrice: '63.00', sellingQuantity: '1.000', openingQuantity: '85.000', newQuantity: '60.000', gstRate: '0.00' },
  { name: 'Basmati Rice', category: 'Rice varieties', unit: 'kg', purchasePrice: '92.00', sellingPrice: '110.00', sellingQuantity: '1.000', openingQuantity: '45.000', newQuantity: '30.000', gstRate: '0.00' },
  { name: 'Idli Rice', category: 'Rice varieties', unit: 'kg', purchasePrice: '46.00', sellingPrice: '55.00', sellingQuantity: '1.000', openingQuantity: '75.000', newQuantity: '50.000', gstRate: '0.00' },
  { name: 'Toor Dal', category: 'Dals and pulses', unit: 'kg', purchasePrice: '112.00', sellingPrice: '132.00', sellingQuantity: '1.000', openingQuantity: '55.000', newQuantity: '35.000', gstRate: '0.00' },
  { name: 'Urad Dal', category: 'Dals and pulses', unit: 'kg', purchasePrice: '104.00', sellingPrice: '124.00', sellingQuantity: '1.000', openingQuantity: '42.000', newQuantity: '28.000', gstRate: '0.00' },
  { name: 'Moong Dal', category: 'Dals and pulses', unit: 'kg', purchasePrice: '96.00', sellingPrice: '115.00', sellingQuantity: '1.000', openingQuantity: '38.000', newQuantity: '25.000', gstRate: '0.00' },
  { name: 'Chana Dal', category: 'Dals and pulses', unit: 'kg', purchasePrice: '78.00', sellingPrice: '94.00', sellingQuantity: '1.000', openingQuantity: '48.000', newQuantity: '32.000', gstRate: '0.00' },
  { name: 'Whole Green Gram', category: 'Dals and pulses', unit: 'kg', purchasePrice: '88.00', sellingPrice: '105.00', sellingQuantity: '1.000', openingQuantity: '32.000', newQuantity: '20.000', gstRate: '0.00' },
  { name: 'White Chickpeas', category: 'Dals and pulses', unit: 'kg', purchasePrice: '94.00', sellingPrice: '112.00', sellingQuantity: '1.000', openingQuantity: '28.000', newQuantity: '18.000', gstRate: '0.00' },
  { name: 'Whole Black Gram', category: 'Dals and pulses', unit: 'kg', purchasePrice: '90.00', sellingPrice: '108.00', sellingQuantity: '1.000', openingQuantity: '30.000', newQuantity: '20.000', gstRate: '0.00' },
  { name: 'Whole Wheat', category: 'Flours and grains', unit: 'kg', purchasePrice: '34.00', sellingPrice: '42.00', sellingQuantity: '1.000', openingQuantity: '60.000', newQuantity: '40.000', gstRate: '0.00' },
  { name: 'Wheat Flour', category: 'Flours and grains', unit: 'kg', purchasePrice: '38.00', sellingPrice: '48.00', sellingQuantity: '1.000', openingQuantity: '55.000', newQuantity: '35.000', gstRate: '0.00' },
  { name: 'Besan Flour', category: 'Flours and grains', unit: 'kg', purchasePrice: '72.00', sellingPrice: '88.00', sellingQuantity: '1.000', openingQuantity: '100.000', newQuantity: '100.000', gstRate: '0.00' },
  { name: 'Maida', category: 'Flours and grains', unit: 'kg', purchasePrice: '32.00', sellingPrice: '40.00', sellingQuantity: '1.000', openingQuantity: '42.000', newQuantity: '28.000', gstRate: '0.00' },
  { name: 'Ragi Flour', category: 'Flours and grains', unit: 'kg', purchasePrice: '46.00', sellingPrice: '58.00', sellingQuantity: '1.000', openingQuantity: '36.000', newQuantity: '24.000', gstRate: '0.00' },
  { name: 'Poha', category: 'Flours and grains', unit: 'kg', purchasePrice: '42.00', sellingPrice: '52.00', sellingQuantity: '1.000', openingQuantity: '34.000', newQuantity: '22.000', gstRate: '0.00' },
  { name: 'Groundnut Oil', category: 'Cooking oils', unit: 'litre', purchasePrice: '168.00', sellingPrice: '195.00', sellingQuantity: '1.000', openingQuantity: '40.000', newQuantity: '30.000', gstRate: '5.00' },
  { name: 'Sunflower Oil', category: 'Cooking oils', unit: 'litre', purchasePrice: '132.00', sellingPrice: '155.00', sellingQuantity: '1.000', openingQuantity: '55.000', newQuantity: '40.000', gstRate: '5.00' },
  { name: 'Coconut Oil', category: 'Cooking oils', unit: 'ml', purchasePrice: '92.00', sellingPrice: '108.00', sellingQuantity: '500.000', openingQuantity: '18000.000', newQuantity: '12000.000', gstRate: '5.00' },
  { name: 'Rice Bran Oil', category: 'Cooking oils', unit: 'litre', purchasePrice: '142.00', sellingPrice: '168.00', sellingQuantity: '1.000', openingQuantity: '32.000', newQuantity: '24.000', gstRate: '5.00' },
  { name: 'Mustard Oil', category: 'Cooking oils', unit: 'ml', purchasePrice: '78.00', sellingPrice: '92.00', sellingQuantity: '500.000', openingQuantity: '9000.000', newQuantity: '6000.000', gstRate: '5.00' },
  { name: 'Turmeric Powder', category: 'Spices and masala powders', unit: 'g', purchasePrice: '7.00', sellingPrice: '9.00', sellingQuantity: '100.000', openingQuantity: '8000.000', newQuantity: '5000.000', gstRate: '5.00' },
  { name: 'Chilli Powder', category: 'Spices and masala powders', unit: 'g', purchasePrice: '15.00', sellingPrice: '19.00', sellingQuantity: '100.000', openingQuantity: '9000.000', newQuantity: '6000.000', gstRate: '5.00' },
  { name: 'Coriander Powder', category: 'Spices and masala powders', unit: 'g', purchasePrice: '9.00', sellingPrice: '12.00', sellingQuantity: '100.000', openingQuantity: '7000.000', newQuantity: '4000.000', gstRate: '5.00' },
  { name: 'Cumin Seeds', category: 'Spices and masala powders', unit: 'g', purchasePrice: '28.00', sellingPrice: '34.00', sellingQuantity: '100.000', openingQuantity: '3000.000', newQuantity: '2000.000', gstRate: '5.00' },
  { name: 'Black Pepper', category: 'Spices and masala powders', unit: 'g', purchasePrice: '48.00', sellingPrice: '58.00', sellingQuantity: '100.000', openingQuantity: '2400.000', newQuantity: '1600.000', gstRate: '5.00' },
  { name: 'Garam Masala', category: 'Spices and masala powders', unit: 'packet', purchasePrice: '28.00', sellingPrice: '35.00', sellingQuantity: '1.000', openingQuantity: '36.000', newQuantity: '24.000', gstRate: '5.00' },
  { name: 'Sambar Powder', category: 'Spices and masala powders', unit: 'packet', purchasePrice: '32.00', sellingPrice: '40.00', sellingQuantity: '1.000', openingQuantity: '30.000', newQuantity: '20.000', gstRate: '5.00' },
  { name: 'White Sugar', category: 'Essentials', unit: 'kg', purchasePrice: '42.00', sellingPrice: '50.00', sellingQuantity: '1.000', openingQuantity: '90.000', newQuantity: '60.000', gstRate: '0.00' },
  { name: 'Iodised Salt', category: 'Essentials', unit: 'kg', purchasePrice: '16.00', sellingPrice: '20.00', sellingQuantity: '1.000', openingQuantity: '55.000', newQuantity: '40.000', gstRate: '0.00' },
  { name: 'Country Jaggery', category: 'Essentials', unit: 'kg', purchasePrice: '58.00', sellingPrice: '72.00', sellingQuantity: '1.000', openingQuantity: '35.000', newQuantity: '25.000', gstRate: '0.00' },
  { name: 'Tamarind', category: 'Essentials', unit: 'kg', purchasePrice: '110.00', sellingPrice: '135.00', sellingQuantity: '1.000', openingQuantity: '22.000', newQuantity: '16.000', gstRate: '0.00' },
  { name: 'Pappad', category: 'Essentials', unit: 'packet', purchasePrice: '22.00', sellingPrice: '28.00', sellingQuantity: '1.000', openingQuantity: '40.000', newQuantity: '28.000', gstRate: '5.00' },
  { name: 'Mustard Seeds', category: 'Essentials', unit: 'g', purchasePrice: '6.00', sellingPrice: '8.00', sellingQuantity: '100.000', openingQuantity: '5000.000', newQuantity: '3000.000', gstRate: '5.00' },
  { name: 'Marie Biscuits', category: 'Biscuits and packaged snacks', unit: 'packet', purchasePrice: '9.00', sellingPrice: '12.00', sellingQuantity: '1.000', openingQuantity: '72.000', newQuantity: '48.000', gstRate: '18.00' },
  { name: 'Cream Biscuits', category: 'Biscuits and packaged snacks', unit: 'packet', purchasePrice: '14.00', sellingPrice: '18.00', sellingQuantity: '1.000', openingQuantity: '60.000', newQuantity: '40.000', gstRate: '18.00' },
  { name: 'Salted Potato Chips', category: 'Biscuits and packaged snacks', unit: 'packet', purchasePrice: '10.00', sellingPrice: '13.00', sellingQuantity: '1.000', openingQuantity: '54.000', newQuantity: '36.000', gstRate: '18.00' },
  { name: 'Roasted Peanuts', category: 'Biscuits and packaged snacks', unit: 'packet', purchasePrice: '18.00', sellingPrice: '24.00', sellingQuantity: '1.000', openingQuantity: '40.000', newQuantity: '28.000', gstRate: '12.00' },
  { name: 'Rusk Toast', category: 'Biscuits and packaged snacks', unit: 'packet', purchasePrice: '24.00', sellingPrice: '30.00', sellingQuantity: '1.000', openingQuantity: '32.000', newQuantity: '22.000', gstRate: '18.00' },
  { name: 'Assam Tea', category: 'Tea and coffee', unit: 'g', purchasePrice: '24.00', sellingPrice: '30.00', sellingQuantity: '100.000', openingQuantity: '4500.000', newQuantity: '3000.000', gstRate: '5.00' },
  { name: 'Dust Tea', category: 'Tea and coffee', unit: 'packet', purchasePrice: '112.00', sellingPrice: '135.00', sellingQuantity: '1.000', openingQuantity: '28.000', newQuantity: '20.000', gstRate: '5.00' },
  { name: 'Instant Coffee', category: 'Tea and coffee', unit: 'g', purchasePrice: '46.00', sellingPrice: '58.00', sellingQuantity: '100.000', openingQuantity: '1800.000', newQuantity: '1200.000', gstRate: '5.00' },
  { name: 'Filter Coffee Powder', category: 'Tea and coffee', unit: 'g', purchasePrice: '32.00', sellingPrice: '40.00', sellingQuantity: '100.000', openingQuantity: '2600.000', newQuantity: '1800.000', gstRate: '5.00' },
  { name: 'Laundry Detergent Powder', category: 'Cleaning products', unit: 'kg', purchasePrice: '78.00', sellingPrice: '95.00', sellingQuantity: '1.000', openingQuantity: '26.000', newQuantity: '18.000', gstRate: '18.00' },
  { name: 'Dishwash Bar', category: 'Cleaning products', unit: 'piece', purchasePrice: '16.00', sellingPrice: '20.00', sellingQuantity: '1.000', openingQuantity: '50.000', newQuantity: '36.000', gstRate: '18.00' },
  { name: 'Floor Cleaner', category: 'Cleaning products', unit: 'ml', purchasePrice: '48.00', sellingPrice: '60.00', sellingQuantity: '500.000', openingQuantity: '7000.000', newQuantity: '5000.000', gstRate: '18.00' },
  { name: 'Toilet Cleaner', category: 'Cleaning products', unit: 'ml', purchasePrice: '52.00', sellingPrice: '65.00', sellingQuantity: '500.000', openingQuantity: '6000.000', newQuantity: '4000.000', gstRate: '18.00' },
  { name: 'Laundry Soap', category: 'Cleaning products', unit: 'piece', purchasePrice: '18.00', sellingPrice: '22.00', sellingQuantity: '1.000', openingQuantity: '48.000', newQuantity: '32.000', gstRate: '18.00' },
  { name: 'Bathing Soap', category: 'Personal care', unit: 'piece', purchasePrice: '24.00', sellingPrice: '30.00', sellingQuantity: '1.000', openingQuantity: '60.000', newQuantity: '40.000', gstRate: '18.00' },
  { name: 'Herbal Shampoo', category: 'Personal care', unit: 'ml', purchasePrice: '85.00', sellingPrice: '105.00', sellingQuantity: '500.000', openingQuantity: '8000.000', newQuantity: '6000.000', gstRate: '18.00' },
  { name: 'Toothpaste', category: 'Personal care', unit: 'piece', purchasePrice: '48.00', sellingPrice: '60.00', sellingQuantity: '1.000', openingQuantity: '45.000', newQuantity: '30.000', gstRate: '18.00' },
  { name: 'Toothbrush', category: 'Personal care', unit: 'piece', purchasePrice: '20.00', sellingPrice: '25.00', sellingQuantity: '1.000', openingQuantity: '42.000', newQuantity: '28.000', gstRate: '18.00' },
  { name: 'Hair Oil', category: 'Personal care', unit: 'ml', purchasePrice: '72.00', sellingPrice: '90.00', sellingQuantity: '200.000', openingQuantity: '5000.000', newQuantity: '3500.000', gstRate: '18.00' },
];

export interface DemoStockSeedResult {
  productsAdded: number;
  batchesAdded: number;
}

export async function seedDemoStockData(
  pool: Pool,
  actorId: string,
): Promise<DemoStockSeedResult> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock($1)', [63817403]);
    let productsAdded = 0;

    for (const [index, product] of demoProducts.entries()) {
      const sku = `DEMO-TS-${String(index + 1).padStart(3, '0')}`;
      const existing = await client.query(
        `SELECT 1 FROM products
         WHERE LOWER(sku) = LOWER($1)
            OR (LOWER(name) = LOWER($2) AND LOWER(category) = LOWER($3))
         LIMIT 1`,
        [sku, product.name, product.category],
      );
      if (existing.rowCount) continue;

      const inserted = await client.query<{ id: string }>(
        `INSERT INTO products (
           name, sku, category, unit, purchase_price, selling_price,
           selling_quantity, opening_stock_quantity, stock_quantity,
           low_stock_threshold, gst_rate
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 0, $10)
         RETURNING id`,
        [
          product.name,
          sku,
          product.category,
          product.unit,
          product.purchasePrice,
          product.sellingPrice,
          product.sellingQuantity,
          product.openingQuantity,
          (Number(product.openingQuantity) + Number(product.newQuantity)).toFixed(3),
          product.gstRate,
        ],
      );
      const productId = inserted.rows[0]?.id;
      if (!productId) throw new Error(`Demo product ${sku} was not inserted.`);

      const opening = await client.query<{ id: string }>(
        `INSERT INTO stock_batches (
           product_id, batch_type, received_quantity, remaining_quantity,
           purchase_quantity, purchase_unit, purchase_price, purchased_at,
           created_by
         ) VALUES ($1, 'opening', $2, $2, $2, $3, $4, NOW() - INTERVAL '90 days', $5)
         RETURNING id`,
        [
          productId,
          product.openingQuantity,
          product.unit,
          product.purchasePrice,
          actorId,
        ],
      );
      const purchaseDate = `2026-10-${String((index % 24) + 1).padStart(2, '0')}`;
      const purchase = await client.query<{ id: string }>(
        `INSERT INTO stock_batches (
           product_id, batch_type, received_quantity, remaining_quantity,
           purchase_quantity, purchase_unit, purchase_price, purchased_at,
           created_by
         ) VALUES ($1, 'purchase', $2, $2, $2, $3, $4, $5::date, $6)
         RETURNING id`,
        [
          productId,
          product.newQuantity,
          product.unit,
          product.purchasePrice,
          purchaseDate,
          actorId,
        ],
      );
      const openingBatchId = opening.rows[0]?.id;
      const purchaseBatchId = purchase.rows[0]?.id;
      if (!openingBatchId || !purchaseBatchId) {
        throw new Error(`Demo stock batches for ${sku} were not inserted.`);
      }
      await client.query(
        `INSERT INTO inventory_movements (
           product_id, stock_batch_id, change_quantity, reason, created_by
         ) VALUES
           ($1, $2, $3, 'opening_balance', $4),
           ($1, $5, $6, 'new_purchase', $4)`,
        [
          productId,
          openingBatchId,
          product.openingQuantity,
          actorId,
          purchaseBatchId,
          product.newQuantity,
        ],
      );
      productsAdded += 1;
    }

    if (productsAdded > 0) {
      await insertAuditEvent(client, {
        actorId,
        action: 'demo.stock.seeded',
        entityType: 'catalogue',
        details: { productsAdded, batchesAdded: productsAdded * 2 },
      });
    }
    await client.query('COMMIT');
    return { productsAdded, batchesAdded: productsAdded * 2 };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

async function main(): Promise<void> {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('Demo stock data cannot be seeded in production mode.');
  }
  if (process.env.ENABLE_DEMO_DATA !== 'YES') {
    throw new Error(
      'Set ENABLE_DEMO_DATA=YES explicitly to seed this database with demo stock data.',
    );
  }
  const { getDatabasePool } = await import('./database');
  const pool = getDatabasePool();
  try {
    const admin = await pool.query<{ id: string }>(
      "SELECT id FROM app_users WHERE role = 'admin' ORDER BY id LIMIT 1",
    );
    const actorId = admin.rows[0]?.id;
    if (!actorId) throw new Error('Create an Admin account before seeding demo data.');
    const result = await seedDemoStockData(pool, actorId);
    console.log(
      `Demo stock setup complete: ${result.productsAdded} product(s), ${result.batchesAdded} stock batch(es) added.`,
    );
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  main().catch((error: unknown) => {
    console.error(
      'Demo stock setup failed:',
      error instanceof Error ? error.message : 'Unknown error',
    );
    process.exitCode = 1;
  });
}
