import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import request from 'supertest';
import { before, describe, it } from 'node:test';
import { deepStrictEqual, equal, match, ok } from 'node:assert/strict';
import { createApp } from './app';
import { PublicUser, StoredUser, UserRole } from './types';
import { ReportRepository } from './report-types';

const testSecret = 'test-only-jwt-secret-with-more-than-thirty-two-bytes';

class FakeAuthRepository {
  readonly users = new Map<string, StoredUser>();
  nextId = 1;

  async findByUsername(username: string): Promise<StoredUser | null> {
    return this.users.get(username.toLowerCase()) ?? null;
  }

  async findById(id: string): Promise<PublicUser | null> {
    for (const user of this.users.values()) {
      if (user.id === id) {
        return { id: user.id, username: user.username, role: user.role };
      }
    }
    return null;
  }

  async hasAdmin(): Promise<boolean> {
    return [...this.users.values()].some((user) => user.role === 'admin');
  }

  async createInitialAdmin(
    username: string,
    passwordHash: string,
  ): Promise<PublicUser> {
    if (await this.hasAdmin()) {
      throw Object.assign(new Error('An admin account already exists.'), {
        code: 'ADMIN_EXISTS',
      });
    }
    if (this.users.has(username.toLowerCase())) {
      throw Object.assign(new Error('duplicate username'), { code: '23505' });
    }
    const user: StoredUser = {
      id: String(this.nextId++),
      username,
      role: 'admin',
      passwordHash,
    };
    this.users.set(username.toLowerCase(), user);
    return { id: user.id, username, role: 'admin' };
  }

  async createCashier(
    username: string,
    passwordHash: string,
  ): Promise<PublicUser> {
    const key = username.toLowerCase();
    if (this.users.has(key)) {
      throw Object.assign(new Error('duplicate username'), { code: '23505' });
    }

    const user: StoredUser = {
      id: String(this.nextId++),
      username,
      role: 'cashier',
      passwordHash,
    };
    this.users.set(key, user);
    return { id: user.id, username: user.username, role: user.role };
  }

  async changePassword(id: string, passwordHash: string): Promise<void> {
    for (const [key, user] of this.users) {
      if (user.id === id) {
        this.users.set(key, { ...user, passwordHash });
        return;
      }
    }
    throw new Error('Account not found.');
  }

  async addUser(
    username: string,
    role: UserRole,
    password: string,
  ): Promise<void> {
    this.users.set(username.toLowerCase(), {
      id: String(this.nextId++),
      username,
      role,
      passwordHash: await bcrypt.hash(password, 4),
    });
  }
}

describe('authentication API', () => {
  const repository = new FakeAuthRepository();
  const reportRepository: ReportRepository = {
    async dashboard(date) {
      return {
        date,
        totalSales: '0.00',
        invoiceCount: 0,
        stockProductCount: 0,
        paymentSummary: [],
      };
    },
    async sales(startDate, endDate) {
      return {
        startDate,
        endDate,
        totalSales: '0.00',
        invoiceCount: 0,
        paymentSummary: [],
        invoices: [],
      };
    },
    async auditLog() {
      return [];
    },
  };
  const app = createApp({
    jwtSecret: testSecret,
    repository,
    reportRepository,
    loginLimit: 100,
  });
  let adminToken = '';
  let cashierToken = '';

  before(async () => {
    await repository.addUser('owner', 'admin', 'Admin-password-123');
    await repository.addUser('till', 'cashier', 'Cashier-password-123');
    await repository.addUser('x', 'cashier', 'Legacy-password-123');
  });

  it('authenticates a user and returns no password hash', async () => {
    const response = await request(app)
      .post('/auth/login')
      .send({ username: 'OWNER', password: 'Admin-password-123' })
      .expect(200);

    equal(response.body.user.username, 'owner');
    equal(response.body.user.role, 'admin');
    ok(response.body.token);
    equal(response.body.passwordHash, undefined);
    adminToken = response.body.token;
  });

  it('rejects missing, unknown, and incorrect credentials', async () => {
    await request(app).post('/auth/login').send({}).expect(400);
    const unknown = await request(app)
      .post('/auth/login')
      .send({ username: 'nobody', password: 'Wrong-password-123' })
      .expect(401);
    const incorrect = await request(app)
      .post('/auth/login')
      .send({ username: 'owner', password: 'Wrong-password-123' })
      .expect(401);

    equal(unknown.body.message, incorrect.body.message);
  });

  it('validates a selected role against the stored account role', async () => {
    const response = await request(app)
      .post('/auth/login')
      .send({
        username: 'owner',
        password: 'Admin-password-123',
        role: 'cashier',
      })
      .expect(401);
    equal(response.body.message, 'Invalid username or password.');

    const cashier = await request(app)
      .post('/auth/login')
      .send({
        username: 'till',
        password: 'Cashier-password-123',
        role: 'cashier',
      })
      .expect(200);
    equal(cashier.body.user.role, 'cashier');
    await request(app)
      .post('/auth/login')
      .send({
        username: 'owner',
        password: 'Admin-password-123',
        role: 'owner',
      })
      .expect(400);
  });

  it('enforces admin and cashier role boundaries', async () => {
    const cashierLogin = await request(app)
      .post('/auth/login')
      .send({ username: 'till', password: 'Cashier-password-123' })
      .expect(200);
    cashierToken = cashierLogin.body.token;

    await request(app).get('/admin/dashboard').expect(401);
    await request(app)
      .get('/admin/dashboard')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(403);
    await request(app)
      .get('/cashier/dashboard')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(403);
    const adminHome = await request(app)
      .get('/admin/dashboard')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    equal(adminHome.body.dashboard.totalSales, '0.00');
    const cashierHome = await request(app)
      .get('/cashier/dashboard')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(200);
    equal(cashierHome.body.role, 'cashier');
  });

  it('provisions cashier accounts only for an admin and stores a hash', async () => {
    await request(app)
      .post('/admin/cashiers')
      .send({ username: 'new-till', password: '1234' })
      .expect(401);
    await request(app)
      .post('/admin/cashiers')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send({ username: 'new-till', password: '1234' })
      .expect(403);

    const response = await request(app)
      .post('/admin/cashiers')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ username: 'new-till', password: '1234' })
      .expect(201);
    equal(response.body.user.role, 'cashier');

    const stored = await repository.findByUsername('new-till');
    ok(stored);
    ok(stored.passwordHash.startsWith('$2'));
    equal(stored.passwordHash.includes('1234'), false);
    equal(await bcrypt.compare('1234', stored.passwordHash), true);
    await request(app)
      .post('/admin/cashiers')
      .set('Authorization', 'Bearer ' + adminToken)
      .send({ username: 'ab', password: '1234' })
      .expect(201);
    await request(app)
      .post('/admin/cashiers')
      .set('Authorization', 'Bearer ' + adminToken)
      .send({ username: 'a', password: '1234' })
      .expect(400);
    await request(app)
      .post('/admin/cashiers')
      .set('Authorization', 'Bearer ' + adminToken)
      .send({ username: '', password: '1234' })
      .expect(400);
    await request(app)
      .post('/admin/cashiers')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ username: 'short-till', password: '123' })
      .expect(400);
    await request(app)
      .post('/admin/cashiers')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ username: 'NEW-TILL', password: '1234' })
      .expect(409);
  });

  it('continues to authenticate an existing one-character username', async () => {
    const response = await request(app)
      .post('/auth/login')
      .send({ username: 'x', password: 'Legacy-password-123' })
      .expect(200);
    equal(response.body.user.username, 'x');
  });

  it('lets an Admin reset either role password only through the Admin API', async () => {
    await request(app)
      .post('/admin/users/password')
      .send({ username: 'till', newPassword: '1234' })
      .expect(401);
    await request(app)
      .post('/admin/users/password')
      .set('Authorization', `Bearer ${cashierToken}`)
      .send({ username: 'till', newPassword: '1234' })
      .expect(403);

    for (const username of ['owner', 'till']) {
      const reset = await request(app)
        .post('/admin/users/password')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ username, newPassword: '1234' })
        .expect(200);
      equal(reset.body.user.username, username);
      const stored = await repository.findByUsername(username);
      ok(stored);
      equal(await bcrypt.compare('1234', stored.passwordHash), true);
      await request(app)
        .post('/auth/login')
        .send({ username, password: '1234' })
        .expect(200);
    }

    await request(app)
      .post('/admin/users/password')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ username: 'unknown-user', newPassword: '1234' })
      .expect(404);
    await request(app)
      .post('/admin/users/password')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ username: 'till', newPassword: '123' })
      .expect(400);
  });

  it('allows either signed-in role to change only their password securely', async () => {
    await request(app)
      .post('/auth/password')
      .send({ currentPassword: 'Admin-password-123', newPassword: 'new-admin-pass' })
      .expect(401);
    await request(app)
      .post('/auth/password')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ currentPassword: 'wrong-password', newPassword: 'new-admin-pass' })
      .expect(401);

    for (const [token, username] of [
      [adminToken, 'owner'],
      [cashierToken, 'till'],
    ]) {
      const stored = await repository.findByUsername(username);
      ok(stored);
      const currentPassword = await bcrypt.compare('1234', stored.passwordHash)
        ? '1234'
        : username === 'owner'
        ? 'Admin-password-123'
        : 'Cashier-password-123';
      const response = await request(app)
        .post('/auth/password')
        .set('Authorization', `Bearer ${token}`)
        .send({ currentPassword, newPassword: `new-${username}-pass` })
        .expect(200);
      equal(response.body.message, 'Password changed successfully.');

      const updated = await repository.findByUsername(username);
      ok(updated);
      equal(await bcrypt.compare(`new-${username}-pass`, updated.passwordHash), true);
      await request(app)
        .post('/auth/login')
        .send({ username, password: `new-${username}-pass` })
        .expect(200);
      await request(app)
        .post('/auth/login')
        .send({ username, password: currentPassword })
        .expect(401);

      const restartedApp = createApp({
        jwtSecret: testSecret,
        repository,
        reportRepository,
        loginLimit: 100,
      });
      await request(restartedApp)
        .post('/auth/login')
        .send({ username, password: currentPassword })
        .expect(401);
      await request(restartedApp)
        .post('/auth/login')
        .send({ username, password: `new-${username}-pass` })
        .expect(200);
    }
  });

  it('rejects expired and invalid tokens', async () => {
    const expired = jwt.sign(
      { username: 'owner', role: 'admin' },
      testSecret,
      { subject: '1', expiresIn: -1 },
    );
    for (const token of ['not-a-jwt', expired]) {
      const response = await request(app)
        .get('/auth/me')
        .set('Authorization', `Bearer ${token}`)
        .expect(401);
      match(response.body.message, /Authentication required/);
    }
  });

  it('returns the database-backed user for a valid session', async () => {
    const response = await request(app)
      .get('/auth/me')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    deepStrictEqual(response.body.user, {
      id: '1',
      username: 'owner',
      role: 'admin',
    });
  });
});

it('limits repeated login requests', async () => {
  const limitedApp = createApp({
    jwtSecret: testSecret,
    repository: new FakeAuthRepository(),
    loginLimit: 1,
  });

  describe('first-run admin setup API', () => {
    it('creates exactly one hashed initial admin and then locks setup', async () => {
      const setupRepository = new FakeAuthRepository();
      const setupApp = createApp({
        jwtSecret: testSecret,
        initialSetupToken: 'test-only-initial-setup-token-32-bytes',
        repository: setupRepository,
        reportRepository: {
          async dashboard(date) {
            return {
              date,
              totalSales: '0.00',
              invoiceCount: 0,
              stockProductCount: 0,
              paymentSummary: [],
            };
          },
          async sales(startDate, endDate) {
            return {
              startDate,
              endDate,
              totalSales: '0.00',
              invoiceCount: 0,
              paymentSummary: [],
              invoices: [],
            };
          },
          async auditLog() {
            return [];
          },
        },
      });

      equal((await request(setupApp).get('/setup/status').expect(200)).body.setupRequired, true);
      await request(setupApp)
        .post('/setup/admin')
        .send({ username: 'first-owner', password: 'Milk' })
        .expect(403);
      await request(setupApp)
        .post('/setup/admin')
        .set('X-Initial-Setup-Token', 'test-only-initial-setup-token-32-bytes')
        .send({ username: 'first-owner', password: 'Milk', sampleProducts: [] })
        .expect(201);
      const stored = await setupRepository.findByUsername('first-owner');
      ok(stored);
      ok(stored.passwordHash.startsWith('$2'));
      equal(stored.passwordHash.includes('Milk'), false);
      equal(await bcrypt.compare('Milk', stored.passwordHash), true);
      equal((await request(setupApp).get('/setup/status').expect(200)).body.setupRequired, false);
      await request(setupApp)
        .post('/setup/admin')
        .set('X-Initial-Setup-Token', 'test-only-initial-setup-token-32-bytes')
        .send({
          username: 'second-owner',
          password: 'Another-strong-password',
          sampleProducts: [],
        })
        .expect(409);
    });

    it('validates setup credentials without storing an account', async () => {
      const setupRepository = new FakeAuthRepository();
      const setupApp = createApp({
        jwtSecret: testSecret,
        initialSetupToken: 'test-only-initial-setup-token-32-bytes',
        repository: setupRepository,
      });

      await request(setupApp)
        .post('/setup/admin')
        .set('X-Initial-Setup-Token', 'test-only-initial-setup-token-32-bytes')
        .send({ username: 'owner', password: 'abc', sampleProducts: [] })
        .expect(400);
      equal(await setupRepository.hasAdmin(), false);
    });

    it('does not seed bundled sample products during initial Admin setup', async () => {
      const setupRepository = new FakeAuthRepository();
      const setupApp = createApp({
        jwtSecret: testSecret,
        initialSetupToken: 'test-only-initial-setup-token-32-bytes',
        repository: setupRepository,
      });
      const headers = {
        'X-Initial-Setup-Token': 'test-only-initial-setup-token-32-bytes',
      };
      await request(setupApp)
        .post('/setup/admin')
        .set(headers)
        .send({
          username: 'first-owner',
          password: 'Milk',
          sampleProducts: [{ invalid: 'ignored legacy payload' }],
        })
        .expect(201);
      equal(await setupRepository.hasAdmin(), true);

      await request(setupApp)
        .post('/setup/admin')
        .set(headers)
        .send({
          username: 'second-owner',
          password: 'Another-strong-password',
        })
        .expect(409);
      equal(await setupRepository.hasAdmin(), true);
    });
  });

  await request(limitedApp)
    .post('/auth/login')
    .send({ username: 'nobody', password: 'Wrong-password-123' })
    .expect(401);
  await request(limitedApp)
    .post('/auth/login')
    .send({ username: 'nobody', password: 'Wrong-password-123' })
    .expect(429);
});
