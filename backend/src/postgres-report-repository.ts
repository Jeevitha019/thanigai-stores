import { getDatabasePool } from './database';
import { Pool } from 'pg';
import {
  AuditEvent,
  DashboardReport,
  PaymentSummary,
  ReportPaymentMethod,
  ReportRepository,
  SalesReport,
} from './report-types';

const paymentMethods: ReportPaymentMethod[] = [
  'cash',
  'upi',
  'card',
  'split',
  'unrecorded',
];

interface SummaryRow {
  method: ReportPaymentMethod;
  invoice_count: string;
  amount: string;
}

function mapPaymentSummary(rows: SummaryRow[]): PaymentSummary[] {
  const summaries = new Map(
    rows.map((row) => [
      row.method,
      {
        method: row.method,
        invoiceCount: Number(row.invoice_count),
        amount: row.amount,
      },
    ]),
  );
  return paymentMethods.map(
    (method) =>
      summaries.get(method) ?? { method, invoiceCount: 0, amount: '0.00' },
  );
}

function moneyToCents(amount: string): bigint {
  const [whole, fraction = ''] = amount.split('.');
  return BigInt(whole) * 100n + BigInt(fraction.padEnd(2, '0').slice(0, 2));
}

function centsToMoney(cents: bigint): string {
  return `${cents / 100n}.${(cents % 100n).toString().padStart(2, '0')}`;
}

async function paymentSummary(
  pool: Pool,
  startDate: string,
  endDate: string,
  paidOnly = false,
): Promise<PaymentSummary[]> {
  const paidOrderFilter = paidOnly
    ? `AND EXISTS (
         SELECT 1 FROM invoice_payments paid
         WHERE paid.invoice_id = i.id
       )`
    : '';
  const result = await pool.query<SummaryRow>(
    `WITH invoice_methods AS (
       SELECT i.id, i.grand_total,
              COUNT(p.id)::integer AS payment_count,
              MIN(p.method) AS only_method
       FROM invoices i
       LEFT JOIN invoice_payments p ON p.invoice_id = i.id
       WHERE i.created_at >= $1::date
         AND i.created_at < ($2::date + INTERVAL '1 day')
         AND i.voided_at IS NULL
         ${paidOrderFilter}
       GROUP BY i.id, i.grand_total
     )
     SELECT CASE
              WHEN payment_count = 0 THEN 'unrecorded'
              WHEN payment_count > 1 THEN 'split'
              ELSE only_method
            END AS method,
            COUNT(*)::text AS invoice_count,
            COALESCE(SUM(grand_total), 0)::text AS amount
     FROM invoice_methods
     GROUP BY method`,
    [startDate, endDate],
  );
  return mapPaymentSummary(result.rows);
}

export class PostgresReportRepository implements ReportRepository {
  constructor(private readonly configuredPool?: Pool) {}

  private pool(): Pool {
    return this.configuredPool ?? getDatabasePool();
  }

  async dashboard(date: string): Promise<DashboardReport> {
    const pool = this.pool();
    const result = await pool.query<{
      invoice_count: string;
      total_sales: string;
      stock_product_count: string;
    }>(
      `SELECT COUNT(*)::text AS invoice_count,
              COALESCE(SUM(grand_total), 0)::text AS total_sales,
              (
                SELECT COUNT(DISTINCT id)::text
                FROM products
                WHERE is_active = TRUE AND stock_quantity > 0
              ) AS stock_product_count
       FROM invoices
       WHERE created_at >= $1::date
         AND created_at < ($1::date + INTERVAL '1 day')
         AND voided_at IS NULL`,
      [date],
    );
    const summary = result.rows[0];
    if (!summary) throw new Error('Dashboard totals could not be loaded.');
    return {
      date,
      invoiceCount: Number(summary.invoice_count),
      totalSales: summary.total_sales,
      stockProductCount: Number(summary.stock_product_count),
      paymentSummary: await paymentSummary(pool, date, date),
    };
  }

  async sales(startDate: string, endDate: string): Promise<SalesReport> {
    const pool = this.pool();
    const result = await pool.query<{
      id: string;
      invoice_number: string;
      cashier_name_snapshot: string;
      created_at: Date;
      paid_at: Date;
      gst_enabled_snapshot: boolean;
      subtotal: string;
      discount_amount: string;
      total_tax: string;
      grand_total: string;
      payment_methods: Array<{ method: string; amount: string }>;
      items: SalesReport['invoices'][number]['items'];
    }>(
      `SELECT i.id, i.invoice_number, i.cashier_name_snapshot, i.created_at,
             i.gst_enabled_snapshot, i.subtotal, i.discount_amount,
             i.total_tax, i.grand_total,
             (SELECT MIN(p.created_at) FROM invoice_payments p
              WHERE p.invoice_id = i.id) AS paid_at,
              COALESCE((
                SELECT jsonb_agg(
                  jsonb_build_object('method', p.method, 'amount', p.amount::text)
                  ORDER BY p.id
                )
                FROM invoice_payments p WHERE p.invoice_id = i.id
              ), '[]'::jsonb) AS payment_methods,
              COALESCE((
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'productName', ii.product_name_snapshot,
                    'sku', ii.sku_snapshot,
                    'unit', ii.unit_snapshot,
                    'quantity', ii.quantity::text,
                    'unitPrice', ii.unit_price::text,
                    'lineTotal', ii.line_total::text
                  )
                  ORDER BY ii.id
                )
                FROM invoice_items ii WHERE ii.invoice_id = i.id
              ), '[]'::jsonb) AS items
       FROM invoices i
       WHERE i.created_at >= $1::date
         AND i.created_at < ($2::date + INTERVAL '1 day')
         AND i.voided_at IS NULL
         AND EXISTS (
           SELECT 1 FROM invoice_payments paid
           WHERE paid.invoice_id = i.id
         )
       ORDER BY i.created_at DESC, i.id DESC`,
      [startDate, endDate],
    );
    const totalCents = result.rows.reduce(
      (sum, row) => sum + moneyToCents(row.grand_total),
      0n,
    );
    return {
      startDate,
      endDate,
      invoiceCount: result.rows.length,
      totalSales: centsToMoney(totalCents),
      paymentSummary: await paymentSummary(pool, startDate, endDate, true),
      invoices: result.rows.map((row) => ({
        id: row.id,
        invoiceNumber: row.invoice_number,
        cashierName: row.cashier_name_snapshot,
        createdAt: row.created_at.toISOString(),
        paidAt: row.paid_at.toISOString(),
        gstEnabled: row.gst_enabled_snapshot,
        subtotal: row.subtotal,
        discountAmount: row.discount_amount,
        totalTax: row.total_tax,
        grandTotal: row.grand_total,
        paymentMethods: row.payment_methods,
        items: row.items,
      })),
    };
  }

  async auditLog(limit: number): Promise<AuditEvent[]> {
    const result = await this.pool().query<{
      id: string;
      actor_username: string | null;
      action: string;
      entity_type: string;
      entity_id: string | null;
      details: Record<string, unknown>;
      created_at: Date;
    }>(
      `SELECT audit.id, actor.username AS actor_username, audit.action,
              audit.entity_type, audit.entity_id, audit.details, audit.created_at
       FROM audit_logs audit
       LEFT JOIN app_users actor ON actor.id = audit.actor_id
       ORDER BY audit.created_at DESC, audit.id DESC
       LIMIT $1`,
      [limit],
    );
    return result.rows.map((row) => ({
      id: row.id,
      actorUsername: row.actor_username,
      action: row.action,
      entityType: row.entity_type,
      entityId: row.entity_id,
      details: row.details,
      createdAt: row.created_at.toISOString(),
    }));
  }
}

export const postgresReportRepository = new PostgresReportRepository();
