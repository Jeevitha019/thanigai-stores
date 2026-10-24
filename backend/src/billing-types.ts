export interface RequestedInvoiceItem {
  productId: string;
  quantity: string;
  unitPrice?: string;
}

export type PaymentMethod = 'cash' | 'upi' | 'card';
export type PriceMode = 'inclusive' | 'exclusive';

export interface PaymentInput {
  method: PaymentMethod;
  amount: string;
}

export interface CreateInvoiceRequest {
  idempotencyKey: string;
  items: RequestedInvoiceItem[];
  saleStateCode: string;
  discountAmount: string;
  gstAmount: string;
  payments: PaymentInput[];
}

export interface GstSettings {
  gstEnabled: boolean;
  gstRate: string;
  priceMode: PriceMode;
  stateCode: string;
  businessName: string;
  businessAddress: string;
  businessPhone: string;
  gstin: string;
  updatedAt: string;
}

export interface InvoiceItem {
  id: string;
  productId: string;
  productName: string;
  sku: string;
  unit: string;
  unitPrice: string;
  quantity: string;
  lineTotal: string;
  gstRate: string;
  taxableAmount: string;
  cgstAmount: string;
  sgstAmount: string;
  igstAmount: string;
}

export interface Invoice {
  id: string;
  invoiceNumber: string;
  createdBy: string;
  cashierName: string;
  subtotal: string;
  discountAmount: string;
  grandTotal: string;
  gstEnabled: boolean;
  priceMode: PriceMode;
  shopStateCode: string;
  saleStateCode: string;
  businessName: string;
  businessAddress: string;
  businessPhone: string;
  gstin: string;
  taxableAmount: string;
  cgstAmount: string;
  sgstAmount: string;
  igstAmount: string;
  totalTax: string;
  createdAt: string;
  items: InvoiceItem[];
  payments: PaymentInput[];
}

export interface BillingRepository {
  getGstSettings(): Promise<GstSettings>;
  updateGstSettings(
    settings: Omit<GstSettings, 'updatedAt'>,
    actorId?: string,
  ): Promise<GstSettings>;
  createInvoice(
    createdBy: string,
    request: CreateInvoiceRequest,
  ): Promise<{ invoice: Invoice; replayed: boolean }>;
  findInvoiceById(id: string): Promise<Invoice | null>;
  listInvoices(limit: number): Promise<Invoice[]>;
  voidInvoice(id: string, actorId: string): Promise<boolean>;
}
