export type ReportPaymentMethod = 'cash' | 'upi' | 'card' | 'split' | 'unrecorded';

export interface PaymentSummary {
  method: ReportPaymentMethod;
  invoiceCount: number;
  amount: string;
}

export interface DashboardReport {
  date: string;
  totalSales: string;
  invoiceCount: number;
  paymentSummary: PaymentSummary[];
}

export interface SalesReport {
  startDate: string;
  endDate: string;
  totalSales: string;
  invoiceCount: number;
  paymentSummary: PaymentSummary[];
  invoices: Array<{
    id: string;
    invoiceNumber: string;
    cashierName: string;
    createdAt: string;
    paidAt: string;
    gstEnabled: boolean;
    subtotal: string;
    discountAmount: string;
    totalTax: string;
    grandTotal: string;
    paymentMethods: Array<{ method: string; amount: string }>;
    items: Array<{
      productName: string;
      sku: string;
      unit: string;
      quantity: string;
      unitPrice: string;
      lineTotal: string;
    }>;
  }>;
}

export interface AuditEvent {
  id: string;
  actorUsername: string | null;
  action: string;
  entityType: string;
  entityId: string | null;
  details: Record<string, unknown>;
  createdAt: string;
}

export interface ReportRepository {
  dashboard(date: string): Promise<DashboardReport>;
  sales(startDate: string, endDate: string): Promise<SalesReport>;
  auditLog(limit: number): Promise<AuditEvent[]>;
}
