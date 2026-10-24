import bcrypt from 'bcryptjs';
import request from 'supertest';
import { before, describe, it } from 'node:test';
import { equal, deepStrictEqual } from 'node:assert/strict';
import { createApp } from './app';
import { BackupOperations, BackupFile } from './backup';
import {
  AuditEvent,
  DashboardReport,
  ReportRepository,
  SalesReport,
} from './report-types';
import { AuthRepository, PublicUser, StoredUser, UserRole } from './types';

const secret = 'test-only-reports-jwt-secret-with-more-than-thirty-two-bytes';

class TestAuthRepository implements AuthRepository {
  private readonly users = new Map<string, StoredUser>();

  async add(username: string, id: string, role: UserRole, password: string) {
    this.users.set(username, {
      id,
      username,
      role,
      passwordHash: await bcrypt.hash(password, 4),
    });
  }

  async findByUsername(username: string) {
    return this.users.get(username) ?? null;
  }

  async findById(id: string): Promise<PublicUser | null> {
    const found = [...this.users.values()].find((user) => user.id === id);
    return found
      ? { id: found.id, username: found.username, role: found.role }
      : null;
  }

  async createCashier(): Promise<PublicUser> {
    throw new Error('Not used in reports tests.');
  }
}

class TestReportRepository implements ReportRepository {
  dashboardDate = '';
  salesRange: [string, string] | undefined;
  auditLimit = 0;

  async dashboard(date: string): Promise<DashboardReport> {
    this.dashboardDate = date;
    return {
      date,
      totalSales: '150.00',
      invoiceCount: 3,
      paymentSummary: [
        { method: 'cash', invoiceCount: 1, amount: '50.00' },
        { method: 'upi', invoiceCount: 0, amount: '0.00' },
        { method: 'card', invoiceCount: 0, amount: '0.00' },
        { method: 'split', invoiceCount: 2, amount: '100.00' },
        { method: 'unrecorded', invoiceCount: 0, amount: '0.00' },
      ],
    };
  }

  async sales(startDate: string, endDate: string): Promise<SalesReport> {
    this.salesRange = [startDate, endDate];
    return {
      startDate,
      endDate,
      totalSales: '50.00',
      invoiceCount: 1,
      paymentSummary: [
        { method: 'cash', invoiceCount: 1, amount: '50.00' },
        { method: 'upi', invoiceCount: 0, amount: '0.00' },
        { method: 'card', invoiceCount: 0, amount: '0.00' },
        { method: 'split', invoiceCount: 0, amount: '0.00' },
        { method: 'unrecorded', invoiceCount: 0, amount: '0.00' },
      ],
      invoices: [],
    };
  }

  async auditLog(limit: number): Promise<AuditEvent[]> {
    this.auditLimit = limit;
    return [];
  }
}

class TestBackupService implements BackupOperations {
  isBusy = false;
  restored: [string, string, string] | undefined;
  readonly file: BackupFile = {
    fileName: 'malligai-kadai_20261019_120000_123e4567-e89b-12d3-a456-426614174000.dump',
    createdAt: '2026-10-19T12:00:00.000Z',
    sizeBytes: 1024,
  };

  async list() {
    return [this.file];
  }

  async create() {
    return this.file;
  }

  async restore(actorId: string, fileName: string, confirmation: string) {
    this.restored = [actorId, fileName, confirmation];
  }
}

describe('Phase 7 report and backup APIs', () => {
  const auth = new TestAuthRepository();
  const reports = new TestReportRepository();
  const backups = new TestBackupService();
  const app = createApp({
    jwtSecret: secret,
    repository: auth,
    reportRepository: reports,
    backupService: backups,
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

  it('protects reports and validates bounded inclusive date filters', async () => {
    await request(app)
      .get('/admin/reports/sales?startDate=2026-10-01&endDate=2026-10-31')
      .expect(401);
    await request(app)
      .get('/admin/reports/sales?startDate=2026-10-01&endDate=2026-10-31')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(403);

    const report = await request(app)
      .get('/admin/reports/sales?startDate=2026-10-01&endDate=2026-10-31')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    deepStrictEqual(reports.salesRange, ['2026-10-01', '2026-10-31']);
    equal(report.body.report.totalSales, '50.00');
    equal(report.body.report.paymentSummary.length, 5);

    for (const query of [
      'startDate=2026-02-30&endDate=2026-03-01',
      'startDate=2026-10-02&endDate=2026-10-01',
      'startDate=2025-01-01&endDate=2026-01-02',
      'startDate=2026-10-01',
    ]) {
      await request(app)
        .get(`/admin/reports/sales?${query}`)
        .set('Authorization', `Bearer ${adminToken}`)
        .expect(400);
    }
  });

  it('returns dashboard totals and audit logs for Admins', async () => {
    const dashboard = await request(app)
      .get('/admin/dashboard?date=2026-10-19')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    equal(reports.dashboardDate, '2026-10-19');
    equal(dashboard.body.dashboard.totalSales, '150.00');
    equal(dashboard.body.dashboard.invoiceCount, 3);

    await request(app)
      .get('/admin/reports/inventory')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(404);

    await request(app)
      .get('/admin/audit?limit=15')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    equal(reports.auditLimit, 15);
  });

  it('restricts backup operations to Admins and forwards explicit restore confirmation', async () => {
    await request(app).get('/admin/backups').expect(401);
    await request(app)
      .get('/admin/backups')
      .set('Authorization', `Bearer ${cashierToken}`)
      .expect(403);
    const list = await request(app)
      .get('/admin/backups')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(200);
    equal(list.body.backups[0].sizeBytes, 1024);

    await request(app)
      .post('/admin/backups')
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(201);
    const confirmation = `RESTORE ${backups.file.fileName}`;
    await request(app)
      .post('/admin/backups/restore')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ fileName: backups.file.fileName, confirmation })
      .expect(200);
    deepStrictEqual(backups.restored, ['1', backups.file.fileName, confirmation]);
    await request(app)
      .post('/admin/backups/restore')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ fileName: backups.file.fileName })
      .expect(400);
  });
});
