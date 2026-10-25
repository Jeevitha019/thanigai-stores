import { createHash } from 'node:crypto';
import { Pool, PoolClient } from 'pg';
import { insertAuditEvent } from './audit';
import { HttpError } from './auth';
import {
  BillingRepository,
  CreateInvoiceRequest,
  GstSettings,
  Invoice,
  InvoiceItem,
  PriceMode,
} from './billing-types';
import { getDatabasePool } from './database';
import {
  calculateItemTax,
  centsToMoney,
  configuredLineTotalCents,
  microsToUnitPrice,
  milliToQuantity,
  priceToCents,
  quantityToMilli,
  unitPriceMicros,
} from './billing-validation';

interface InvoiceRow {
  id: string;
  invoice_number: string;
  created_by: string;
  cashier_name_snapshot: string;
  subtotal: string;
  discount_amount: string;
  grand_total: string;
  gst_enabled_snapshot: boolean;
  price_mode_snapshot: PriceMode;
  shop_state_code_snapshot: string;
  sale_state_code_snapshot: string;
  business_name_snapshot: string;
  business_address_snapshot: string;
  business_phone_snapshot: string;
  gstin_snapshot: string;
  taxable_amount: string;
  cgst_amount: string;
  sgst_amount: string;
  igst_amount: string;
  total_tax: string;
  created_at: Date;
}

interface InvoiceItemRow {
  id: string;
  invoice_id: string;
  product_id: string;
  product_name_snapshot: string;
  sku_snapshot: string;
  unit_snapshot: string;
  unit_price: string;
  quantity: string;
  line_total: string;
  gst_rate_snapshot: string;
  taxable_amount: string;
  cgst_amount: string;
  sgst_amount: string;
  igst_amount: string;
}

interface LockedProductRow {
  id: string;
  name: string;
  sku: string | null;
  unit: string;
  selling_price: string;
  selling_quantity: string;
  is_active: boolean;
}

interface StockAllocation {
  batchId: string;
  quantity: string;
}

interface GstSettingsRow {
  gst_enabled: boolean;
  gst_rate: string;
  price_mode: PriceMode;
  state_code: string;
  business_name: string;
  business_address: string;
  business_phone: string;
  gstin: string;
  updated_at: Date;
}

async function loadInvoice(client: PoolClient, id: string): Promise<Invoice> {
  const result = await client.query<InvoiceRow>(
    `SELECT id, invoice_number, created_by, cashier_name_snapshot, subtotal,
            discount_amount, grand_total,
            gst_enabled_snapshot, price_mode_snapshot, shop_state_code_snapshot,
            sale_state_code_snapshot, business_name_snapshot,
            business_address_snapshot, business_phone_snapshot, gstin_snapshot, taxable_amount, cgst_amount, sgst_amount,
            igst_amount, total_tax, created_at
     FROM invoices WHERE id = $1`,
    [id],
  );
  const row = result.rows[0];
  if (!row) throw new Error('The saved invoice could not be loaded.');

  const items = await client.query<InvoiceItemRow>(
    `SELECT id, product_id, product_name_snapshot, sku_snapshot, unit_snapshot,
            unit_price, quantity, line_total, gst_rate_snapshot, taxable_amount,
            cgst_amount, sgst_amount, igst_amount
     FROM invoice_items WHERE invoice_id = $1 ORDER BY id`,
    [id],
  );
  const payments = await client.query<{ method: 'cash' | 'upi' | 'card'; amount: string }>(
    'SELECT method, amount FROM invoice_payments WHERE invoice_id = $1 ORDER BY id',
    [id],
  );

  return toInvoice(row, items.rows, payments.rows);
}

function toInvoice(
  row: InvoiceRow,
  items: InvoiceItemRow[],
  payments: Array<{ method: 'cash' | 'upi' | 'card'; amount: string }>,
): Invoice {
  return {
    id: row.id,
    invoiceNumber: row.invoice_number,
    createdBy: row.created_by,
    cashierName: row.cashier_name_snapshot,
    subtotal: row.subtotal,
    discountAmount: row.discount_amount,
    grandTotal: row.grand_total,
    gstEnabled: row.gst_enabled_snapshot,
    priceMode: row.price_mode_snapshot,
    shopStateCode: row.shop_state_code_snapshot.trim(),
    saleStateCode: row.sale_state_code_snapshot.trim(),
    businessName: row.business_name_snapshot,
    businessAddress: row.business_address_snapshot,
    businessPhone: row.business_phone_snapshot,
    gstin: row.gstin_snapshot,
    taxableAmount: row.taxable_amount,
    cgstAmount: row.cgst_amount,
    sgstAmount: row.sgst_amount,
    igstAmount: row.igst_amount,
    totalTax: row.total_tax,
    createdAt: row.created_at.toISOString(),
    items: items.map(
      (item): InvoiceItem => ({
        id: item.id,
        productId: item.product_id,
        productName: item.product_name_snapshot,
        sku: item.sku_snapshot,
        unit: item.unit_snapshot,
        unitPrice: item.unit_price,
        quantity: item.quantity,
        lineTotal: item.line_total,
        gstRate: item.gst_rate_snapshot,
        taxableAmount: item.taxable_amount,
        cgstAmount: item.cgst_amount,
        sgstAmount: item.sgst_amount,
        igstAmount: item.igst_amount,
      }),
    ),
    payments,
  };
}

function mapSettings(row: GstSettingsRow): GstSettings {
  return {
    gstEnabled: row.gst_enabled,
    gstRate: row.gst_rate,
    priceMode: row.price_mode,
    stateCode: row.state_code.trim(),
    businessName: row.business_name,
    businessAddress: row.business_address,
    businessPhone: row.business_phone,
    gstin: row.gstin,
    updatedAt: row.updated_at.toISOString(),
  };
}

function distributeCents(total: bigint, weights: bigint[]): bigint[] {
  const weightTotal = weights.reduce((sum, weight) => sum + weight, 0n);
  if (weightTotal === 0n) return weights.map(() => 0n);
  let remaining = total;
  return weights.map((weight, index) => {
    const share =
      index === weights.length - 1
        ? remaining
        : (total * weight) / weightTotal;
    remaining -= share;
    return share;
  });
}

export class PostgresBillingRepository implements BillingRepository {
  constructor(private readonly configuredPool?: Pool) {}

  private pool(): Pool {
    return this.configuredPool ?? getDatabasePool();
  }

  async getGstSettings(): Promise<GstSettings> {
    const result = await this.pool().query<GstSettingsRow>(
      `SELECT gst_enabled, gst_rate, price_mode, state_code,
              business_name, business_address, business_phone, gstin, updated_at
       FROM shop_settings WHERE id = 1`,
    );
    const row = result.rows[0];
    if (!row) throw new Error('Shop GST settings have not been initialized.');
    return mapSettings(row);
  }

  async updateGstSettings(
    settings: Omit<GstSettings, 'updatedAt'>,
    actorId?: string,
  ): Promise<GstSettings> {
    const client = await this.pool().connect();
    try {
      await client.query('BEGIN');
      const result = await client.query<GstSettingsRow>(
        `INSERT INTO shop_settings (
           id, gst_enabled, gst_rate, price_mode, state_code,
           business_name, business_address, business_phone, gstin
         )
         VALUES (1, $1, $2, $3, $4, $5, $6, $7, $8)
         ON CONFLICT (id) DO UPDATE
           SET gst_enabled = EXCLUDED.gst_enabled,
               gst_rate = EXCLUDED.gst_rate,
               price_mode = EXCLUDED.price_mode,
               state_code = EXCLUDED.state_code,
               business_name = EXCLUDED.business_name,
               business_address = EXCLUDED.business_address,
               business_phone = EXCLUDED.business_phone,
               gstin = EXCLUDED.gstin,
               updated_at = NOW()
         RETURNING gst_enabled, gst_rate, price_mode, state_code,
                   business_name, business_address, business_phone, gstin, updated_at`,
        [
          settings.gstEnabled,
          settings.gstRate,
          settings.priceMode,
          settings.stateCode,
          settings.businessName,
          settings.businessAddress,
          settings.businessPhone,
          settings.gstin,
        ],
      );
      const row = result.rows[0];
      if (!row) throw new Error('Shop GST settings could not be saved.');
      await insertAuditEvent(client, {
        actorId: actorId ?? null,
        action: 'settings.gst.updated',
        entityType: 'shop_settings',
        entityId: '1',
        details: {
          gstEnabled: settings.gstEnabled,
          gstRate: settings.gstRate,
          priceMode: settings.priceMode,
          stateCode: settings.stateCode,
          businessName: settings.businessName,
          businessAddress: settings.businessAddress,
          gstin: settings.gstin,
        },
      });
      await client.query('COMMIT');
      return mapSettings(row);
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async findInvoiceById(id: string): Promise<Invoice | null> {
    const client = await this.pool().connect();
    try {
      const result = await client.query<{ id: string }>(
        'SELECT id FROM invoices WHERE id = $1',
        [id],
      );
      const invoiceId = result.rows[0]?.id;
      return invoiceId ? await loadInvoice(client, invoiceId) : null;
    } finally {
      client.release();
    }
  }

  async listInvoices(limit: number): Promise<Invoice[]> {
    const client = await this.pool().connect();
    try {
      await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      const result = await client.query<InvoiceRow>(
        `SELECT id, invoice_number, created_by, cashier_name_snapshot,
                subtotal, discount_amount, grand_total, gst_enabled_snapshot,
                price_mode_snapshot, shop_state_code_snapshot,
                sale_state_code_snapshot, business_name_snapshot,
                business_address_snapshot, business_phone_snapshot, gstin_snapshot, taxable_amount, cgst_amount,
                sgst_amount, igst_amount, total_tax, created_at
         FROM invoices
         WHERE voided_at IS NULL
         ORDER BY created_at DESC, id DESC LIMIT $1`,
        [limit],
      );
      const ids = result.rows.map((row) => row.id);
      if (ids.length === 0) {
        await client.query('COMMIT');
        return [];
      }

      const [items, payments] = await Promise.all([
        client.query<InvoiceItemRow>(
          `SELECT id, invoice_id, product_id, product_name_snapshot,
                  sku_snapshot, unit_snapshot, unit_price, quantity, line_total,
                  gst_rate_snapshot, taxable_amount, cgst_amount, sgst_amount,
                  igst_amount
           FROM invoice_items
           WHERE invoice_id = ANY($1::bigint[])
           ORDER BY invoice_id, id`,
          [ids],
        ),
        client.query<{
          invoice_id: string;
          method: 'cash' | 'upi' | 'card';
          amount: string;
        }>(
          `SELECT invoice_id, method, amount
           FROM invoice_payments
           WHERE invoice_id = ANY($1::bigint[])
           ORDER BY invoice_id, id`,
          [ids],
        ),
      ]);
      const itemsByInvoice = new Map<string, InvoiceItemRow[]>();
      for (const item of items.rows) {
        const grouped = itemsByInvoice.get(item.invoice_id) ?? [];
        grouped.push(item);
        itemsByInvoice.set(item.invoice_id, grouped);
      }

      const paymentsByInvoice = new Map<
        string,
        Array<{ method: 'cash' | 'upi' | 'card'; amount: string }>
      >();
      for (const payment of payments.rows) {
        const grouped = paymentsByInvoice.get(payment.invoice_id) ?? [];
        grouped.push({ method: payment.method, amount: payment.amount });
        paymentsByInvoice.set(payment.invoice_id, grouped);
      }
      const invoices = result.rows.map((invoice) =>
        toInvoice(
          invoice,
          itemsByInvoice.get(invoice.id) ?? [],
          paymentsByInvoice.get(invoice.id) ?? [],
        ),
      );
      await client.query('COMMIT');
      return invoices;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async voidInvoice(id: string, actorId: string): Promise<boolean> {
    const client = await this.pool().connect();
    try {
      await client.query('BEGIN');
      const result = await client.query<{
        id: string;
        invoice_number: string;
        voided_at: Date | null;
      }>(
        'SELECT id, invoice_number, voided_at FROM invoices WHERE id = $1 FOR UPDATE',
        [id],
      );
      const invoice = result.rows[0];
      if (!invoice || invoice.voided_at) {
        await client.query('ROLLBACK');
        return false;
      }

      const soldBatches = await client.query<{
        product_id: string;
        stock_batch_id: string;
        change_quantity: string;
      }>(
        `SELECT product_id, stock_batch_id, ABS(change_quantity)::text AS change_quantity
         FROM inventory_movements
         WHERE invoice_id = $1 AND reason = 'sale' AND stock_batch_id IS NOT NULL
         ORDER BY stock_batch_id
         FOR UPDATE`,
        [id],
      );
      for (const movement of soldBatches.rows) {
        const restoredQuantity = milliToQuantity(
          quantityToMilli(movement.change_quantity),
        );
        await client.query(
          `UPDATE stock_batches
           SET remaining_quantity = remaining_quantity + $2, updated_at = NOW()
           WHERE id = $1`,
          [movement.stock_batch_id, restoredQuantity],
        );
        await client.query(
          'UPDATE products SET stock_quantity = stock_quantity + $2, updated_at = NOW() WHERE id = $1',
          [movement.product_id, restoredQuantity],
        );
        await client.query(
          `INSERT INTO inventory_movements (
             product_id, stock_batch_id, change_quantity, reason, created_by
           ) VALUES ($1, $2, $3, 'adjustment', $4)`,
          [
            movement.product_id,
            movement.stock_batch_id,
            restoredQuantity,
            actorId,
          ],
        );
      }
      await client.query(
        `UPDATE invoices
         SET voided_at = NOW(), voided_by = $2, void_reason = $3
         WHERE id = $1`,
        [id, actorId, 'Voided by an Admin from invoice history.'],
      );
      await insertAuditEvent(client, {
        actorId,
        action: 'invoice.voided',
        entityType: 'invoice',
        entityId: invoice.id,
        details: {
          invoiceNumber: invoice.invoice_number,
          restoredStockBatches: soldBatches.rowCount ?? 0,
        },
      });
      await client.query('COMMIT');
      return true;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async createInvoice(
    createdBy: string,
    request: CreateInvoiceRequest,
  ): Promise<{ invoice: Invoice; replayed: boolean }> {
    const client = await this.pool().connect();
    const requestHash = createHash('sha256')
      .update(
        JSON.stringify({
          items: [...request.items].sort((left, right) =>
            left.productId.localeCompare(right.productId),
          ),
          saleStateCode: request.saleStateCode,
          discountAmount: request.discountAmount,
          gstAmount: request.gstAmount,
          payments: [...request.payments].sort((left, right) =>
            left.method.localeCompare(right.method),
          ),
        }),
      )
      .digest('hex');

    try {
      await client.query('BEGIN');
      await client.query(
        'SELECT pg_advisory_xact_lock(hashtextextended($1, 74291011))',
        [request.idempotencyKey],
      );
      const existing = await client.query<{
        id: string;
        created_by: string;
        request_hash: string;
        has_payments: boolean;
      }>(
        `SELECT i.id, i.created_by, i.request_hash,
           EXISTS (
             SELECT 1 FROM invoice_payments p WHERE p.invoice_id = i.id
           ) AS has_payments
         FROM invoices i WHERE i.idempotency_key = $1`,
        [request.idempotencyKey],
      );
      if (existing.rows[0]) {
        if (existing.rows[0].created_by !== createdBy) {
          throw new HttpError(409, 'This idempotency key has already been used by another account.');
        }
        if (
          existing.rows[0].has_payments &&
          existing.rows[0].request_hash !== requestHash
        ) {
          throw new HttpError(409, 'This idempotency key was already used for a different bill.');
        }
        const invoice = await loadInvoice(client, existing.rows[0].id);
        await client.query('COMMIT');
        return { invoice, replayed: true };
      }

      const settingsResult = await client.query<GstSettingsRow>(
        `SELECT gst_enabled, gst_rate, price_mode, state_code,
                business_name, business_address, business_phone, gstin, updated_at
         FROM shop_settings WHERE id = 1 FOR SHARE`,
      );
      const settingsRow = settingsResult.rows[0];
      if (!settingsRow) throw new Error('Shop GST settings have not been initialized.');
      const settings = mapSettings(settingsRow);
      if (settings.gstEnabled && settings.stateCode === '00') {
        throw new HttpError(409, 'The shop state code must be configured before GST checkout.');
      }
      const cashierResult = await client.query<{ username: string }>(
        'SELECT username FROM app_users WHERE id = $1',
        [createdBy],
      );
      const cashierName = cashierResult.rows[0]?.username;
      if (!cashierName) throw new HttpError(401, 'The cashier account is no longer available.');
      const interstate = request.saleStateCode !== settings.stateCode;
      const ids = request.items.map((item) => item.productId);
      const products = await client.query<LockedProductRow>(
        `SELECT id, name, sku, unit, selling_price, selling_quantity, is_active
         FROM products WHERE id = ANY($1::bigint[]) ORDER BY id FOR UPDATE`,
        [ids],
      );
      const productById = new Map(products.rows.map((product) => [product.id, product]));

      const snapshots = request.items.map((item) => {
        const product = productById.get(item.productId);
        if (!product || !product.is_active) {
          throw new HttpError(409, 'A product in the cart is no longer available.');
        }
        const configuredPrice = item.unitPrice ?? product.selling_price;
        const unitPriceCents = priceToCents(configuredPrice);
        if (unitPriceCents <= 0n) {
          throw new HttpError(409, `${product.name} has an invalid amount.`);
        }
        const sellingQuantityMilli = quantityToMilli(product.selling_quantity);
        if (sellingQuantityMilli <= 0n) {
          throw new Error(`Product ${product.id} has an invalid selling quantity.`);
        }
        const subtotalCents = configuredLineTotalCents(
          centsToMoney(unitPriceCents),
          item.quantity,
          product.selling_quantity,
        );
        const unitPrice = microsToUnitPrice(
          unitPriceMicros(configuredPrice, product.selling_quantity),
        );
        const tax = calculateItemTax(
          subtotalCents,
          settings.gstRate,
          settings.gstEnabled,
          settings.priceMode === 'inclusive',
          interstate,
        );
        if (tax.lineTotalCents > 99999999999999n) {
          throw new HttpError(400, `Line total for ${product.name} is too large.`);
        }
        return {
          product,
          quantity: item.quantity,
          unitPrice,
          subtotalCents,
          tax,
        };
      });

      const allocationsByProduct = new Map<string, StockAllocation[]>();
      for (const item of snapshots) {
        const requiredMilli = quantityToMilli(item.quantity);
        const availableBatches = await client.query<{
          id: string;
          remaining_quantity: string;
        }>(
          `SELECT id, remaining_quantity::text
           FROM stock_batches
           WHERE product_id = $1 AND remaining_quantity > 0
           ORDER BY CASE WHEN batch_type = 'opening' THEN 0 ELSE 1 END,
                    purchased_at, id
           FOR UPDATE`,
          [item.product.id],
        );
        let neededMilli = requiredMilli;
        const allocations: StockAllocation[] = [];
        for (const batch of availableBatches.rows) {
          if (neededMilli === 0n) break;
          const batchMilli = quantityToMilli(batch.remaining_quantity);
          const allocatedMilli = batchMilli < neededMilli ? batchMilli : neededMilli;
          allocations.push({
            batchId: batch.id,
            quantity: milliToQuantity(allocatedMilli),
          });
          neededMilli -= allocatedMilli;
        }
        if (neededMilli > 0n) {
          const availableMilli = requiredMilli - neededMilli;
          throw new HttpError(
            409,
            `Insufficient stock for ${item.product.name}. Available: ${milliToQuantity(availableMilli)} ${item.product.unit}; requested: ${item.quantity} ${item.product.unit}.`,
          );
        }
        allocationsByProduct.set(item.product.id, allocations);
      }

      const subtotalCents = snapshots.reduce((sum, item) => sum + item.subtotalCents, 0n);
      const discountCents = priceToCents(request.discountAmount);
      if (discountCents > subtotalCents) {
        throw new HttpError(400, 'Discount cannot exceed the subtotal.');
      }
      const amountAfterDiscountCents = subtotalCents - discountCents;
      const gstRateHundredths = settings.gstEnabled
        ? priceToCents(settings.gstRate)
        : 0n;
      const inclusive = settings.priceMode === 'inclusive';
      const gstCents =
        gstRateHundredths === 0n
          ? 0n
          : inclusive
            ? amountAfterDiscountCents -
              (amountAfterDiscountCents * 10000n +
                (10000n + gstRateHundredths) / 2n) /
                (10000n + gstRateHundredths)
            : (amountAfterDiscountCents * gstRateHundredths + 5000n) /
              10000n;
      const taxableCents = inclusive
        ? amountAfterDiscountCents - gstCents
        : amountAfterDiscountCents;
      const discountShares = distributeCents(
        discountCents,
        snapshots.map((item) => item.subtotalCents),
      );
      const gstShares = distributeCents(
        gstCents,
        snapshots.map((item) => item.subtotalCents),
      );
      for (let index = 0; index < snapshots.length; index += 1) {
        const item = snapshots[index]!;
        const itemGst = gstShares[index]!;
        const itemAfterDiscount = item.subtotalCents - discountShares[index]!;
        const itemTaxable = inclusive ? itemAfterDiscount - itemGst : itemAfterDiscount;
        item.tax.taxableCents = itemTaxable;
        item.tax.taxCents = itemGst;
        item.tax.cgstCents = interstate ? 0n : (itemGst + 1n) / 2n;
        item.tax.sgstCents = interstate ? 0n : itemGst - item.tax.cgstCents;
        item.tax.igstCents = interstate ? itemGst : 0n;
        item.tax.lineTotalCents = inclusive
          ? itemAfterDiscount
          : itemTaxable + itemGst;
      }
      const cgstCents = interstate ? 0n : (gstCents + 1n) / 2n;
      const sgstCents = interstate ? 0n : gstCents - cgstCents;
      const igstCents = interstate ? gstCents : 0n;
      const totalTaxCents = gstCents;
      const grandTotalCents = inclusive
        ? amountAfterDiscountCents
        : taxableCents + gstCents;
      if (grandTotalCents > 99999999999999n) {
        throw new HttpError(400, 'Invoice total is too large.');
      }
      const paymentTotalCents = request.payments.reduce(
        (sum, payment) => sum + priceToCents(payment.amount),
        0n,
      );
      if (paymentTotalCents !== grandTotalCents) {
        throw new HttpError(
          400,
          `Payment total must equal the invoice total of ${centsToMoney(grandTotalCents)}.`,
        );
      }

      const invoiceResult = await client.query<InvoiceRow>(
        `INSERT INTO invoices (
           invoice_number, idempotency_key, created_by, cashier_name_snapshot,
           subtotal, discount_amount, grand_total,
           request_hash, gst_enabled_snapshot, price_mode_snapshot,
           shop_state_code_snapshot, sale_state_code_snapshot, taxable_amount,
           business_name_snapshot, business_address_snapshot, business_phone_snapshot, gstin_snapshot,
           cgst_amount, sgst_amount, igst_amount, total_tax
         )
         VALUES (
           'INV-' || to_char(CURRENT_DATE, 'YYYY') || '-' ||
             LPAD(nextval('invoice_number_seq')::text, 8, '0'),
           $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
           $15, $16, $17, $18, $19, $20
         )
         RETURNING id, invoice_number, created_by, cashier_name_snapshot,
           subtotal, discount_amount, grand_total,
           gst_enabled_snapshot, price_mode_snapshot, shop_state_code_snapshot,
           sale_state_code_snapshot, business_name_snapshot,
           business_address_snapshot, business_phone_snapshot, gstin_snapshot, taxable_amount, cgst_amount, sgst_amount,
           igst_amount, total_tax, created_at`,
        [
          request.idempotencyKey,
          createdBy,
          cashierName,
          centsToMoney(subtotalCents),
          centsToMoney(discountCents),
          centsToMoney(grandTotalCents),
          requestHash,
          settings.gstEnabled,
          settings.priceMode,
          settings.stateCode,
          request.saleStateCode,
          centsToMoney(taxableCents),
          settings.businessName,
          settings.businessAddress,
          settings.businessPhone,
          settings.gstin,
          centsToMoney(cgstCents),
          centsToMoney(sgstCents),
          centsToMoney(igstCents),
          centsToMoney(totalTaxCents),
        ],
      );
      const invoiceRow = invoiceResult.rows[0];
      if (!invoiceRow) throw new Error('Invoice could not be saved.');

      for (const item of snapshots) {
        await client.query(
          `INSERT INTO invoice_items (
             invoice_id, product_id, product_name_snapshot, sku_snapshot, unit_snapshot,
             unit_price, quantity, line_total, gst_rate_snapshot, taxable_amount,
             cgst_amount, sgst_amount, igst_amount
           ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
          [
            invoiceRow.id,
            item.product.id,
            item.product.name,
            item.product.sku ?? '',
            item.product.unit,
            item.unitPrice,
            item.quantity,
            centsToMoney(item.subtotalCents),
            settings.gstRate,
            centsToMoney(item.tax.taxableCents),
            centsToMoney(item.tax.cgstCents),
            centsToMoney(item.tax.sgstCents),
            centsToMoney(item.tax.igstCents),
          ],
        );
      }

      for (const item of snapshots) {
        for (const allocation of allocationsByProduct.get(item.product.id) ?? []) {
          await client.query(
            `UPDATE stock_batches
             SET remaining_quantity = remaining_quantity - $2, updated_at = NOW()
             WHERE id = $1`,
            [allocation.batchId, allocation.quantity],
          );
          await client.query(
            `INSERT INTO inventory_movements (
               product_id, stock_batch_id, change_quantity, reason, invoice_id, created_by
             ) VALUES ($1, $2, -$3::numeric, 'sale', $4, $5)`,
            [
              item.product.id,
              allocation.batchId,
              allocation.quantity,
              invoiceRow.id,
              createdBy,
            ],
          );
        }
        await client.query(
          'UPDATE products SET stock_quantity = stock_quantity - $2, updated_at = NOW() WHERE id = $1',
          [item.product.id, item.quantity],
        );
      }

      for (const payment of request.payments) {
        await client.query(
          'INSERT INTO invoice_payments (invoice_id, method, amount) VALUES ($1, $2, $3)',
          [invoiceRow.id, payment.method, payment.amount],
        );
      }

      await insertAuditEvent(client, {
        actorId: createdBy,
        action: 'invoice.created',
        entityType: 'invoice',
        entityId: invoiceRow.id,
        details: {
          invoiceNumber: invoiceRow.invoice_number,
          grandTotal: invoiceRow.grand_total,
        },
      });
      await client.query('COMMIT');
      return { invoice: await loadInvoice(client, invoiceRow.id), replayed: false };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }
}

export const postgresBillingRepository = new PostgresBillingRepository();
