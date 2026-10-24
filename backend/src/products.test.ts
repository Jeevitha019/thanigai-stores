import bcrypt from 'bcryptjs';
import request from 'supertest';
import { before, describe, it } from 'node:test';
import { equal, ok, throws } from 'node:assert/strict';
import { createApp } from './app';
import { PublicUser, StoredUser, UserRole } from './types';
import { Product, ProductInput, ProductRepository } from './product-types';
import { validateProductInput } from './product-validation';

const testSecret = 'test-only-product-jwt-secret-with-more-than-thirty-two-bytes';
const adminPassword = 'Admin-password-123';
const cashierPassword = 'Cashier-password-123';

class FakeAuthRepository {
  private readonly users = new Map<string, StoredUser>();

  async findByUsername(username: string): Promise<StoredUser | null> {
    return this.users.get(username.toLowerCase()) ?? null;
  }

  async findById(id: string): Promise<PublicUser | null> {
    for (const user of this.users.values()) {
      if (user.id === id) {
        return { id, username: user.username, role: user.role };
      }
    }
    return null;
  }

  async createCashier(): Promise<PublicUser> {
    throw new Error('Not used by product tests.');
  }

  async addUser(username: string, role: UserRole, password: string) {
    this.users.set(username.toLowerCase(), {
      id: role === 'admin' ? '1' : '2',
      username,
      role,
      passwordHash: await bcrypt.hash(password, 4),
    });
  }
}

class FakeProductRepository implements ProductRepository {
  private readonly products = new Map<string, Product & { isActive: boolean }>();
  private nextId = 1;

  async list(search: string): Promise<Product[]> {
    const query = search.toLowerCase();
    return [...this.products.values()]
      .filter(
        (product) =>
          product.isActive &&
          (!query ||
            product.name.toLowerCase().includes(query) ||
            product.sku?.toLowerCase().includes(query) ||
            product.category.toLowerCase().includes(query)),
      )
      .map(({ isActive: _isActive, ...product }) => product);
  }

  async findById(id: string): Promise<Product | null> {
    const product = this.products.get(id);
    if (!product?.isActive) return null;
    const { isActive: _isActive, ...result } = product;
    return result;
  }

  async create(input: ProductInput): Promise<Product> {
    if (
      [...this.products.values()].some(
        (product) =>
          input.sku !== null &&
          product.sku !== null &&
          product.sku.toLowerCase() === input.sku.toLowerCase(),
      )
    ) {
      throw Object.assign(new Error('Duplicate SKU'), { code: '23505' });
    }
    const id = String(this.nextId++);
    const now = new Date().toISOString();
    const product: Product & { isActive: boolean } = {
      ...input,
      id,
      isActive: true,
      createdAt: now,
      updatedAt: now,
    };
    this.products.set(id, product);
    const { isActive: _isActive, ...result } = product;
    return result;
  }

  async update(id: string, input: ProductInput): Promise<Product | null> {
    const existing = this.products.get(id);
    if (!existing?.isActive) return null;
    if (
      [...this.products.values()].some(
        (product) =>
          product.id !== id &&
          input.sku !== null &&
          product.sku !== null &&
          product.sku.toLowerCase() === input.sku.toLowerCase(),
      )
    ) {
      throw Object.assign(new Error('Duplicate SKU'), { code: '23505' });
    }
    const updated = {
      ...existing,
      ...input,
      updatedAt: new Date().toISOString(),
    };
    this.products.set(id, updated);
    const { isActive: _isActive, ...result } = updated;
    return result;
  }

  async softDelete(id: string): Promise<boolean> {
    const product = this.products.get(id);
    if (!product?.isActive) return false;
    this.products.set(id, { ...product, isActive: false });
    return true;
  }
}

const validProduct = {
  name: 'Basmati Rice',
  sku: 'RICE-001',
  category: 'Rice',
  unit: 'kg',
  purchasePrice: '80.00',
  sellingPrice: '100.00',
  gstRate: '5.00',
};

describe('product API', () => {
  const authRepository = new FakeAuthRepository();
  const productRepository = new FakeProductRepository();
  const app = createApp({
    jwtSecret: testSecret,
    repository: authRepository,
    productRepository,
  });
  let adminToken = '';
  let cashierToken = '';

  before(async () => {
    await authRepository.addUser('owner', 'admin', adminPassword);
    await authRepository.addUser('till', 'cashier', cashierPassword);
    const admin = await request(app)
      .post('/auth/login')
      .send({ username: 'owner', password: adminPassword });
    const cashier = await request(app)
      .post('/auth/login')
      .send({ username: 'till', password: cashierPassword });
    adminToken = admin.body.token;
    cashierToken = cashier.body.token;
  });

  it('requires authentication for product listing and allows cashier search', async () => {
    await request(app).get('/products').expect(401);
    const created = await request(app)
      .post('/products')
      .set('Authorization', `Bearer ${adminToken}`)
      .send(validProduct)
      .expect(201);

    const response = await request(app)
      .get('/products?search=rice')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(200);
    equal(response.body.products.length, 1);
    equal(response.body.products[0].id, created.body.product.id);
    equal(response.body.products[0].purchasePrice, undefined);
    const cashierDetails = await request(app)
      .get(`/products/${created.body.product.id}`)
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(200);
    equal(cashierDetails.body.product.purchasePrice, undefined);
    const adminDetails = await request(app)
      .get(`/products/${created.body.product.id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    equal(adminDetails.body.product.purchasePrice, '80.00');
  });

  it('allows Admin create and edit with uniqueness checks', async () => {
    const created = await request(app)
      .post('/products')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ ...validProduct, sku: 'RICE-002' })
      .expect(201);
    equal(created.body.product.unit, 'kg');

    const updated = await request(app)
      .put(`/products/${created.body.product.id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        ...validProduct,
        sku: 'RICE-002',
        name: 'Premium Basmati Rice',
        sellingPrice: '110.00',
      })
      .expect(200);
    equal(updated.body.product.name, 'Premium Basmati Rice');
    equal(updated.body.product.sellingPrice, '110.00');

    await request(app)
      .post('/products')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ ...validProduct, sku: 'rice-002' })
      .expect(409);
  });

  it('creates and edits products without stock fields', async () => {
    const created = await request(app)
      .post('/products')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ ...validProduct, sku: 'NO-STOCK-1', unit: 'packet' })
      .expect(201);
    equal(created.body.product.unit, 'packet');

    const updated = await request(app)
      .put(`/products/${created.body.product.id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        ...validProduct,
        sku: 'NO-STOCK-1',
        unit: 'litre',
        name: 'Cooking Oil',
        sellingPrice: '120.00',
      })
      .expect(200);
    equal(updated.body.product.unit, 'litre');
    equal(updated.body.product.sellingPrice, '120.00');
    equal(updated.body.product.stockQuantity, undefined);
    equal(updated.body.product.lowStockThreshold, undefined);
  });

  it('creates products without an optional product code and updates the price', async () => {
    const created = await request(app)
      .post('/products')
      .set('Authorization', 'Bearer ' + adminToken)
      .send({ ...validProduct, sku: '' })
      .expect(201);
    equal(created.body.product.sku, null);

    const updated = await request(app)
      .put(`/products/${created.body.product.id}`)
      .set('Authorization', 'Bearer ' + adminToken)
      .send({
        ...validProduct,
        sku: null,
        sellingPrice: '125.50',
      })
      .expect(200);
    equal(updated.body.product.sku, null);
    equal(updated.body.product.sellingPrice, '125.50');
  });

  it('accepts manually entered GST percentages from 0 through 100', () => {
    for (const gstRate of ['0', '5', '7.5', '12', '18', '28', '100']) {
      equal(
        validateProductInput({ ...validProduct, gstRate }).gstRate,
        Number(gstRate).toFixed(2),
      );
    }
    for (const gstRate of ['-1', '100.01', 'abc', '1.234']) {
      throws(() => validateProductInput({ ...validProduct, gstRate }));
    }
  });

  it('rejects invalid fields and invalid product identifiers', async () => {
    await request(app)
      .post('/products')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ ...validProduct, sellingPrice: '0' })
      .expect(400);
    await request(app)
      .post('/products')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ ...validProduct, unit: 'box' })
      .expect(400);
    await request(app)
      .get('/products/not-an-id')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(400);
    await request(app)
      .get(`/products?search=${'x'.repeat(101)}`)
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(400);
  });

  it('denies product changes to cashiers and unauthenticated users', async () => {
    await request(app).post('/products').send(validProduct).expect(401);
    await request(app)
      .post('/products')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send(validProduct)
      .expect(403);
    await request(app)
      .put('/products/1')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send(validProduct)
      .expect(403);
    await request(app)
      .delete('/products/1')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(403);
  });

  it('soft-deletes products so they disappear from search and details', async () => {
    const created = await request(app)
      .post('/products')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ ...validProduct, sku: 'DELETE-001' })
      .expect(201);
    const id = created.body.product.id;

    await request(app)
      .delete(`/products/${id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(204);
    await request(app)
      .get(`/products/${id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(404);
    const response = await request(app)
      .get('/products?search=DELETE-001')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    equal(response.body.products.length, 0);
    await request(app)
      .delete(`/products/${id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(404);
  });
});

it('validates missing and excessive precision values', async () => {
  const authRepository = new FakeAuthRepository();
  await authRepository.addUser('owner', 'admin', adminPassword);
  const login = await request(
    createApp({
      jwtSecret: testSecret,
      repository: authRepository,
      productRepository: new FakeProductRepository(),
    }),
  )
    .post('/auth/login')
    .send({ username: 'owner', password: adminPassword });
  const app = createApp({
    jwtSecret: testSecret,
    repository: authRepository,
    productRepository: new FakeProductRepository(),
  });
  await request(app)
    .post('/products')
    .set('Authorization', `Bearer ${login.body.token}`)
    .send({ ...validProduct, name: '' })
    .expect(400);
  await request(app)
    .post('/products')
    .set('Authorization', `Bearer ${login.body.token}`)
    .send({ ...validProduct, purchasePrice: '1.999' })
    .expect(400);
});
