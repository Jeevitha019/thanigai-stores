import bcrypt from 'bcryptjs';
import request from 'supertest';
import { randomUUID } from 'node:crypto';
import { before, describe, it } from 'node:test';
import { equal, ok, throws } from 'node:assert/strict';
import { createApp } from './app';
import { HttpError } from './auth';
import { BillingRepository, CreateInvoiceRequest, Invoice } from './billing-types';
import {
  calculateItemTax,
  centsToMoney,
  lineTotalCents,
  validateGstSettings,
  validateInvoiceRequest,
} from './billing-validation';
import { PublicUser, StoredUser, UserRole } from './types';

const secret = 'test-only-billing-jwt-secret-with-more-than-thirty-two-bytes';

class BillingTestAuthRepository {
  private readonly users = new Map<string, StoredUser>();

  async findByUsername(username: string): Promise<StoredUser | null> {
    return this.users.get(username.toLowerCase()) ?? null;
  }

  async findById(id: string): Promise<PublicUser | null> {
    for (const user of this.users.values()) {
      if (user.id === id) return { id, username: user.username, role: user.role };
    }
    return null;
  }

  async createCashier(): Promise<PublicUser> {
    throw new Error('Not used in billing tests.');
  }

  async add(username: string, id: string, role: UserRole, password: string) {
    this.users.set(username.toLowerCase(), {
      id,
      username,
      role,
      passwordHash: await bcrypt.hash(password, 4),
    });
  }
}

class FakeBillingRepository implements BillingRepository {
  readonly saved = new Map<string, Invoice>();
  readonly fingerprints = new Map<string, string>();
  shouldFail = false;
  stock = 12;
  settings = {
    gstEnabled: false,
    gstRate: '0.00',
    priceMode: 'exclusive' as const,
    stateCode: '33',
    businessName: 'Thanigai Stores',
    businessAddress: '',
    businessPhone: '',
    gstin: '',
    updatedAt: new Date().toISOString(),
  };

  async getGstSettings() {
    return this.settings;
  }

  async updateGstSettings(value: Omit<typeof this.settings, 'updatedAt'>) {
    this.settings = { ...value, updatedAt: new Date().toISOString() };
    return this.settings;
  }

  async createInvoice(createdBy: string, value: CreateInvoiceRequest) {
    const fingerprint = JSON.stringify(
      {
        items: [...value.items].sort((left, right) =>
          left.productId.localeCompare(right.productId),
        ),
        saleStateCode: value.saleStateCode,
        payments: [...value.payments].sort((left, right) =>
          left.method.localeCompare(right.method),
        ),
      },
    );
    const prior = this.saved.get(value.idempotencyKey);
    if (prior) {
      if (this.fingerprints.get(value.idempotencyKey) !== fingerprint) {
        throw new HttpError(
          409,
          'This idempotency key was already used for a different cart.',
        );
      }
      return { invoice: prior, replayed: true };
    }
    if (this.shouldFail) throw new Error('Injected database failure.');
    const totalCents = value.items.reduce(
      (sum, item) =>
        sum + lineTotalCents(item.unitPrice ?? '2.50', item.quantity),
      0n,
    );
    const paidCents = value.payments.reduce(
      (sum, payment) => sum + BigInt(payment.amount.replace('.', '')),
      0n,
    );
    if (paidCents !== totalCents) {
      throw new HttpError(400, 'Payment total must equal the invoice total.');
    }
    const invoice: Invoice = {
      id: String(this.saved.size + 1),
      invoiceNumber: `INV-2026-${String(this.saved.size + 1).padStart(8, '0')}`,
      createdBy,
      cashierName: createdBy === '1' ? 'owner' : 'till',
      subtotal: centsToMoney(totalCents),
      discountAmount: value.discountAmount,
      grandTotal: centsToMoney(totalCents),
      gstEnabled: false,
      priceMode: 'exclusive',
      shopStateCode: '33',
      saleStateCode: value.saleStateCode,
      businessName: this.settings.businessName,
      businessAddress: this.settings.businessAddress,
      businessPhone: this.settings.businessPhone,
      gstin: this.settings.gstin,
      taxableAmount: centsToMoney(totalCents),
      cgstAmount: '0.00',
      sgstAmount: '0.00',
      igstAmount: '0.00',
      totalTax: '0.00',
      createdAt: new Date().toISOString(),
      payments: value.payments,
      items: value.items.map((item) => ({
        id: '1',
        productId: item.productId,
        productName: 'Test Apple',
        sku: 'APPLE-1',
        unit: 'kg',
        unitPrice: item.unitPrice ?? '2.50',
        quantity: item.quantity,
        lineTotal: centsToMoney(
          lineTotalCents(item.unitPrice ?? '2.50', item.quantity),
        ),
        gstRate: '5.00',
        taxableAmount: centsToMoney(
          lineTotalCents(item.unitPrice ?? '2.50', item.quantity),
        ),
        cgstAmount: '0.00',
        sgstAmount: '0.00',
        igstAmount: '0.00',
      })),
    };
    this.saved.set(value.idempotencyKey, invoice);
    this.fingerprints.set(value.idempotencyKey, fingerprint);
    return { invoice, replayed: false };
  }

  async findInvoiceById(id: string) {
    return [...this.saved.values()].find((invoice) => invoice.id === id) ?? null;
  }

  async listInvoices(limit: number) {
    return [...this.saved.values()]
      .filter((invoice) => !this.voided.has(invoice.id))
      .slice(-limit)
      .reverse();
  }

  readonly voided = new Set<string>();

  async voidInvoice(id: string) {
    if (!(await this.findInvoiceById(id)) || this.voided.has(id)) return false;
    this.voided.add(id);
    return true;
  }
}

const validBody = {
  idempotencyKey: '550e8400-e29b-41d4-a716-446655440000',
  saleStateCode: '33',
  discountAmount: '0.00',
  gstAmount: '0.00',
  payments: [{ method: 'cash', amount: '2.81' }],
  items: [{ productId: '10', quantity: '1.125' }],
};

describe('billing API', () => {
  const auth = new BillingTestAuthRepository();
  const billing = new FakeBillingRepository();
  const app = createApp({
    jwtSecret: secret,
    repository: auth,
    billingRepository: billing,
  });
  let adminToken = '';
  let cashierToken = '';

  before(async () => {
    await auth.add('owner', '1', 'admin', 'Admin-password-123');
    await auth.add('till', '2', 'cashier', 'Cashier-password-123');
    adminToken = (
      await request(app)
        .post('/auth/login')
        .send({ username: 'owner', password: 'Admin-password-123' })
    ).body.token;
    cashierToken = (
      await request(app)
        .post('/auth/login')
        .send({ username: 'till', password: 'Cashier-password-123' })
    ).body.token;
  });

  it('allows Admin and Cashier invoice creation, but requires authentication', async () => {
    await request(app).post('/invoices').send(validBody).expect(401);
    const response = await request(app)
      .post('/invoices')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send(validBody)
      .expect(201);
    equal(response.body.invoice.subtotal, '2.81');
    equal(response.body.invoice.grandTotal, '2.81');
    equal(response.body.invoice.items[0].productName, 'Test Apple');
    equal(response.body.invoice.cashierName, 'till');
    const adminBill = await request(app)
      .post('/invoices')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        ...validBody,
        idempotencyKey: '550e8400-e29b-41d4-a716-446655440001',
      })
      .expect(201);
    equal(adminBill.body.invoice.createdBy, '1');
  });

  it('saves the amount entered for a product instead of its catalog price', async () => {
    const response = await request(app)
      .post('/invoices')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send({
        ...validBody,
        idempotencyKey: '550e8400-e29b-41d4-a716-446655440005',
        items: [{ productId: '10', quantity: '1', unitPrice: '8.75' }],
        payments: [{ method: 'cash', amount: '8.75' }],
      })
      .expect(201);
    equal(response.body.invoice.items[0].unitPrice, '8.75');
    equal(response.body.invoice.items[0].lineTotal, '8.75');
    equal(response.body.invoice.grandTotal, '8.75');
  });

  it('allows authenticated staff to retrieve and reprint saved invoices without checkout', async () => {
    const beforeCount = billing.saved.size;
    const beforeStock = billing.stock;
    await request(app).get('/invoices').expect(401);
    const list = await request(app)
      .get('/invoices?limit=20')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(200);
    equal(list.body.invoices.length, beforeCount);
    const id = list.body.invoices[0].id;
    const first = await request(app)
      .get(`/invoices/${id}`)
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(200);
    const reprint = await request(app)
      .get(`/invoices/${id}`)
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(200);
    equal(reprint.body.invoice.invoiceNumber, first.body.invoice.invoiceNumber);
    equal(billing.saved.size, beforeCount);
    equal(billing.stock, beforeStock);
    await request(app)
      .delete(`/admin/invoices/${id}`)
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(403);
    await request(app)
      .delete(`/admin/invoices/${id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(204);
    const savedAfterVoid = await request(app)
      .get(`/invoices/${id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    equal(savedAfterVoid.body.invoice.invoiceNumber, first.body.invoice.invoiceNumber);
    equal(billing.saved.size, beforeCount);
    const listAfterVoid = await request(app)
      .get('/invoices?limit=20')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    equal(
      listAfterVoid.body.invoices.some((invoice: Invoice) => invoice.id === id),
      false,
    );
    await request(app)
      .delete(`/admin/invoices/${id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(404);
    await request(app)
      .get('/invoices/not-an-id')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(400);
    await request(app)
      .get('/invoices?limit=101')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(400);
    await request(app)
      .get('/invoices/999999')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(404);
  });

  it('allows only Admin to update GST settings and lets signed-in staff read them', async () => {
    await request(app).get('/settings/gst').expect(401);
    await request(app)
      .put('/admin/settings/gst')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send({ gstEnabled: true, gstRate: '5.00', stockTrackingEnabled: false, priceMode: 'inclusive', stateCode: '33' })
      .expect(403);
    const updated = await request(app)
      .put('/admin/settings/gst')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ gstEnabled: true, gstRate: '5.00', stockTrackingEnabled: true, priceMode: 'inclusive', stateCode: '33', businessPhone: '555-0100' })
      .expect(200);
    equal(updated.body.settings.gstEnabled, true);
    equal(updated.body.settings.gstRate, '5.00');
    equal(updated.body.settings.stockTrackingEnabled, undefined);
    const read = await request(app)
      .get('/settings/gst')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(200);
    equal(read.body.settings.priceMode, 'inclusive');
    equal(read.body.settings.businessPhone, '555-0100');
    await request(app)
      .put('/admin/settings/gst')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ gstEnabled: 'yes', gstRate: '5.00', stockTrackingEnabled: false, priceMode: 'weird', stateCode: 'X' })
      .expect(400);
  });

  it('rejects short or excessive payments and invalid methods', async () => {
    for (const payments of [
      [{ method: 'cash', amount: '2.80' }],
      [{ method: 'cash', amount: '2.82' }],
      [{ method: 'bitcoin', amount: '2.81' }],
      [
        { method: 'cash', amount: '1.00' },
        { method: 'cash', amount: '1.81' },
      ],
    ]) {
      await request(app)
        .post('/invoices')
        .set('Authorization', `Bearer ${cashierToken}`)
        .send({ ...validBody, idempotencyKey: randomUUID(), payments })
        .expect(400);
    }
  });

  it('replays the same invoice for a retried idempotency key', async () => {
    const body = {
      ...validBody,
      idempotencyKey: '550e8400-e29b-41d4-a716-446655440002',
    };
    const first = await request(app)
      .post('/invoices')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send(body)
      .expect(201);
    const retry = await request(app)
      .post('/invoices')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send(body)
      .expect(200);
    equal(retry.body.replayed, true);
    equal(retry.body.invoice.invoiceNumber, first.body.invoice.invoiceNumber);
    await request(app)
      .post('/invoices')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send({ ...body, items: [{ productId: '10', quantity: '2.125' }] })
      .expect(409);
    equal(billing.saved.size, 4);
  });

  it('rejects empty, duplicate, invalid, and excessive-precision quantities', async () => {
    for (const body of [
      { ...validBody, items: [] },
      {
        ...validBody,
        items: [
          { productId: '10', quantity: '1' },
          { productId: '10', quantity: '2' },
        ],
      },
      { ...validBody, items: [{ productId: '10', quantity: '0' }] },
      { ...validBody, items: [{ productId: '10', quantity: '-1' }] },
      { ...validBody, items: [{ productId: '10', quantity: '1.0001' }] },
      {
        ...validBody,
        items: [{ productId: '10', quantity: '1', unitPrice: '-1' }],
      },
      { ...validBody, idempotencyKey: 'invalid-key' },
    ]) {
      await request(app)
        .post('/invoices')
        .set('Authorization', `Bearer ${adminToken}`)
        .send(body)
        .expect(400);
    }
  });

  it('does not block large quantities regardless of legacy stock settings', async () => {
    await request(app)
      .post('/invoices')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send({
        ...validBody,
        idempotencyKey: '550e8400-e29b-41d4-a716-446655440003',
        items: [{ productId: '10', quantity: '99' }],
        payments: [{ method: 'cash', amount: '247.50' }],
      })
      .expect(201);

    billing.shouldFail = true;
    const failed = await request(app)
      .post('/invoices')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send({
        ...validBody,
        idempotencyKey: '550e8400-e29b-41d4-a716-446655440004',
      })
      .expect(500);
    equal(failed.body.status, 'error');
    billing.shouldFail = false;
    equal(failed.body.status, 'error');
  });

  it('accepts fractional quantities for packet and piece products', () => {
    for (const quantity of ['0.125', '1.500', '250.000']) {
      const parsed = validateInvoiceRequest({
        ...validBody,
        items: [{ productId: '10', quantity }],
      });
      equal(parsed.items[0].quantity, quantity);
    }
  });
});

describe('decimal-safe billing calculations', () => {
  it('requires a configured shop state before enabling GST', () => {
    throws(
      () =>
        validateGstSettings({
          gstEnabled: true,
          gstRate: '5.00',
          priceMode: 'exclusive',
          stateCode: '00',
        }),
      /Set the shop state code/,
    );
  });

  it('validates the Settings GST rate and rejects manual invoice tax', () => {
    throws(
      () =>
        validateGstSettings({
          gstEnabled: true,
          gstRate: '100.01',
          priceMode: 'exclusive',
          stateCode: '33',
        }),
      /GST rate must be between 0 and 100 percent/,
    );
    throws(
      () => validateInvoiceRequest({ ...validBody, gstAmount: '0.01' }),
      /GST is calculated from the saved Settings rate/,
    );
  });

  it('rounds each item to cents, then sums exact integer cents', () => {
    const first = lineTotalCents('0.10', '0.250');
    const second = lineTotalCents('2.35', '1.125');
    equal(centsToMoney(first), '0.03');
    equal(centsToMoney(second), '2.64');
    equal(centsToMoney(first + second), '2.67');
  });

  it('calculates exclusive/inclusive tax and splits intra/interstate GST exactly', () => {
    const disabled = calculateItemTax(10000n, '5.00', false, false, false);
    equal(disabled.taxableCents, 10000n);
    equal(disabled.taxCents, 0n);
    equal(disabled.lineTotalCents, 10000n);

    const exclusive = calculateItemTax(10000n, '5.00', true, false, false);
    equal(centsToMoney(exclusive.taxableCents), '100.00');
    equal(centsToMoney(exclusive.cgstCents), '2.50');
    equal(centsToMoney(exclusive.sgstCents), '2.50');
    equal(centsToMoney(exclusive.lineTotalCents), '105.00');

    const inclusive = calculateItemTax(10500n, '5.00', true, true, false);
    equal(centsToMoney(inclusive.taxableCents), '100.00');
    equal(centsToMoney(inclusive.taxCents), '5.00');

    const interstate = calculateItemTax(10000n, '18.00', true, false, true);
    equal(centsToMoney(interstate.igstCents), '18.00');
    equal(centsToMoney(interstate.cgstCents + interstate.sgstCents), '0.00');
    const rounding = calculateItemTax(1n, '5.00', true, false, false);
    equal(rounding.cgstCents + rounding.sgstCents, rounding.taxCents);
  });
});
