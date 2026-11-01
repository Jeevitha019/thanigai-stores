import express, {
  ErrorRequestHandler,
  NextFunction,
  Request,
  Response,
} from 'express';
import { timingSafeEqual } from 'node:crypto';
import rateLimit from 'express-rate-limit';
import { AuthRepository } from './types';
import { postgresAuthRepository } from './postgres-auth-repository';
import { ProductRepository } from './product-types';
import { postgresProductRepository } from './postgres-product-repository';
import { validateProductInput } from './product-validation';
import { ReportRepository } from './report-types';
import { postgresReportRepository } from './postgres-report-repository';
import { BillingRepository } from './billing-types';
import { postgresBillingRepository } from './postgres-billing-repository';
import { StockRepository } from './stock-types';
import { postgresStockRepository } from './postgres-stock-repository';
import {
  validateOpeningStock,
  validateStockPurchase,
} from './stock-validation';
import {
  BackupOperations,
  postgresBackupService,
} from './backup';
import {
  validateGstSettings,
  validateInvoiceRequest,
} from './billing-validation';
import {
  authenticateUser,
  comparePassword,
  getJwtSecret,
  hashPassword,
  HttpError,
  validatePassword,
  validateUsername,
  verifyToken,
} from './auth';

declare global {
  namespace Express {
    interface Request {
      authenticatedUser?: { id: string; username: string; role: string };
    }
  }
}

interface AppOptions {
  jwtSecret?: string;
  initialSetupToken?: string;
  shutdownToken?: string;
  onShutdown?: () => void;
  repository?: AuthRepository;
  productRepository?: ProductRepository;
  stockRepository?: StockRepository;
  billingRepository?: BillingRepository;
  reportRepository?: ReportRepository;
  backupService?: BackupOperations;
  loginLimit?: number;
  healthCheck?: () => Promise<void>;
}

function reportDate(value: unknown, field: string, fallback?: string): string {
  const date = value === undefined ? fallback : value;
  if (
    typeof date !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}$/.test(date)
  ) {
    throw new HttpError(400, `${field} must be a valid date in YYYY-MM-DD format.`);
  }
  const parsed = new Date(`${date}T00:00:00.000Z`);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date) {
    throw new HttpError(400, `${field} must be a valid date in YYYY-MM-DD format.`);
  }
  return date;
}

function queryLimit(value: unknown, fallback: number, maximum: number, label: string): number {
  if (value === undefined) return fallback;
  const limit = typeof value === 'string' ? Number(value) : Number.NaN;
  if (!/^\d+$/.test(String(value)) || !Number.isInteger(limit) || limit < 1 || limit > maximum) {
    throw new HttpError(400, `${label} must be between 1 and ${maximum}.`);
  }
  return limit;
}

function localDate(): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function requestBody(request: Request): Record<string, unknown> {
  if (
    request.body === null ||
    typeof request.body !== 'object' ||
    Array.isArray(request.body)
  ) {
    throw new HttpError(400, 'A JSON request body is required.');
  }
  return request.body as Record<string, unknown>;
}

function productIdParam(request: Request): string {
  const id = request.params.id;
  if (typeof id !== 'string' || !/^\d+$/.test(id)) {
    throw new HttpError(400, 'Product ID must be a positive integer.');
  }
  return id;
}

function invoiceIdParam(request: Request): string {
  const id = request.params.id;
  if (typeof id !== 'string' || !/^[1-9]\d*$/.test(id)) {
    throw new HttpError(400, 'Invoice ID must be a positive integer.');
  }
  if (BigInt(id) > 9223372036854775807n) {
    throw new HttpError(400, 'Invoice ID is too large.');
  }
  return id;
}

export function createApp(options: AppOptions = {}) {
  const secret = options.jwtSecret ?? getJwtSecret();
  const initialSetupToken =
    options.initialSetupToken ?? process.env.INITIAL_SETUP_TOKEN;
  const repository = options.repository ?? postgresAuthRepository;
  const products = options.productRepository ?? postgresProductRepository;
  const stocks = options.stockRepository ?? postgresStockRepository;
  const billing = options.billingRepository ?? postgresBillingRepository;
  const reports = options.reportRepository ?? postgresReportRepository;
  const backups = options.backupService ?? postgresBackupService;
  const app = express();
  const hasValidLocalProcessToken = (request: Request): boolean => {
    const expected = options.shutdownToken ?? '';
    const supplied = request.header('x-local-shutdown-token') ?? '';
    const expectedBytes = Buffer.from(expected);
    const suppliedBytes = Buffer.from(supplied);
    return (
      expectedBytes.length > 0 &&
      expectedBytes.length === suppliedBytes.length &&
      timingSafeEqual(expectedBytes, suppliedBytes)
    );
  };

  app.disable('x-powered-by');
  app.use(express.json({ limit: '32kb' }));

  const loginLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: options.loginLimit ?? 5,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    message: { status: 'error', message: 'Too many login attempts. Try again later.' },
  });
  const setupLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 5,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    message: { status: 'error', message: 'Too many setup attempts. Try again later.' },
  });

  app.get('/health', async (_request, response) => {
    try {
      await options.healthCheck?.();
      response.status(200).json({
        status: 'ok',
        service: 'thanigai-stores-api',
        database: options.healthCheck ? 'ok' : 'unchecked',
        message: 'Thanigai Stores API is running',
      });
    } catch {
      response.status(503).json({
        status: 'error',
        service: 'thanigai-stores-api',
        database: 'unavailable',
        message: 'The local database is unavailable.',
      });
    }
  });

  app.get('/internal/identity', (request, response) => {
    if (!hasValidLocalProcessToken(request)) {
      response.status(404).end();
      return;
    }
    response.status(200).json({
      service: 'thanigai-stores-api',
      processId: process.pid,
      parentProcessId: process.ppid,
    });
  });

  app.get('/setup/status', async (_request, response) => {
    if (!repository.hasAdmin) {
      throw new HttpError(503, 'Initial account setup is unavailable.');
    }
    response.status(200).json({ setupRequired: !(await repository.hasAdmin()) });
  });

  app.post('/setup/admin', setupLimiter, async (request, response) => {
    if (!repository.hasAdmin || !repository.createInitialAdmin) {
      throw new HttpError(503, 'Initial account setup is unavailable.');
    }
    if (!initialSetupToken) {
      throw new HttpError(503, 'Initial account setup is unavailable.');
    }
    const suppliedSetupToken = request.header('x-initial-setup-token');
    if (
      !suppliedSetupToken ||
      Buffer.byteLength(suppliedSetupToken) !==
        Buffer.byteLength(initialSetupToken) ||
      !timingSafeEqual(
        Buffer.from(suppliedSetupToken),
        Buffer.from(initialSetupToken),
      )
    ) {
      throw new HttpError(403, 'Initial setup authorization is invalid.');
    }
    const body = requestBody(request);
    const username = validateUsername(body.username);
    const password = validatePassword(body.password);
    const alreadyConfigured = await repository.hasAdmin();
    if (alreadyConfigured) {
      throw new HttpError(409, 'An admin account already exists.');
    }

    try {
      const user = await repository.createInitialAdmin(
        username,
        await hashPassword(password),
      );
      response.status(201).json({ user });
    } catch (error) {
      if (
        typeof error === 'object' &&
        error !== null &&
        'code' in error &&
        error.code === 'ADMIN_EXISTS'
      ) {
        throw new HttpError(409, 'An admin account already exists.');
      }
      if (
        typeof error === 'object' &&
        error !== null &&
        'code' in error &&
        error.code === '23505'
      ) {
        throw new HttpError(409, 'That username is already in use.');
      }
      throw error;
    }
  });

  app.use((request, _response, next) => {
    if (backups.isBusy) {
      throw new HttpError(503, 'The database is being restored. Try again when the operation completes.');
    }
    next();
  });

  app.post('/auth/login', loginLimiter, async (request, response) => {
    const body = requestBody(request);
    if (
      typeof body.username !== 'string' ||
      typeof body.password !== 'string' ||
      (body.role !== undefined &&
        body.role !== 'admin' &&
        body.role !== 'cashier') ||
      !body.username.trim() ||
      !body.password
    ) {
      throw new HttpError(400, 'Username and password are required; the selected role must be valid.');
    }

    const result = await authenticateUser(
      body.username.trim(),
      body.password,
      secret,
      (username) => repository.findByUsername(username),
    );
    if (body.role !== undefined && result.user.role !== body.role) {
      throw new HttpError(401, 'Invalid username or password.');
    }
    await repository.recordLogin?.(result.user.id);
    response.status(200).json(result);
  });

  const requireAuthentication = async (
    request: Request,
    _response: Response,
    next: NextFunction,
  ) => {
    const authorization = request.header('authorization');
    const [scheme, token, extra] = authorization?.trim().split(/\s+/) ?? [];
    if (
      scheme?.toLowerCase() !== 'bearer' ||
      !token ||
      extra !== undefined
    ) {
      throw new HttpError(401, 'Authentication required.');
    }

    const claims = verifyToken(token, secret);
    const user = await repository.findById(claims.id);
    if (!user) {
      throw new HttpError(401, 'Authentication required.');
    }
    request.authenticatedUser = user;
    next();
  };

  const requireRole =
    (role: 'admin' | 'cashier') =>
    (request: Request, _response: Response, next: NextFunction) => {
      if (request.authenticatedUser?.role !== role) {
        throw new HttpError(403, 'You are not authorized to access this resource.');
      }
      next();
    };

  app.get(
    '/stocks',
    requireAuthentication,
    requireRole('admin'),
    async (_request, response) => {
      response.status(200).json({ products: await stocks.list() });
    },
  );

  app.put(
    '/stocks/:id/opening',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const id = productIdParam(request);
      const input = validateOpeningStock(requestBody(request));
      const product = await stocks.setOpeningStock(
        id,
        input.quantity,
        input.purchasePrice,
        request.authenticatedUser!.id,
      );
      if (!product) throw new HttpError(404, 'Product not found.');
      response.status(200).json({ product });
    },
  );

  app.post(
    '/stocks/:id/purchases',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const id = productIdParam(request);
      const input = validateStockPurchase(requestBody(request));
      const product = await stocks.receivePurchase(
        id,
        input.quantity,
        input.purchasePrice,
        input.purchaseDate,
        request.authenticatedUser!.id,
      );
      if (!product) throw new HttpError(404, 'Product not found.');
      response.status(201).json({ product });
    },
  );

  app.get('/auth/me', requireAuthentication, (request, response) => {
    response.status(200).json({ user: request.authenticatedUser });
  });

  app.post('/auth/password', requireAuthentication, async (request, response) => {
    if (!repository.changePassword) {
      throw new HttpError(503, 'Password changes are unavailable.');
    }
    const body = requestBody(request);
    const currentPassword = validatePassword(body.currentPassword);
    const newPassword = validatePassword(body.newPassword);
    const user = request.authenticatedUser;
    if (!user) throw new HttpError(401, 'Authentication required.');

    const storedUser = await repository.findByUsername(user.username);
    if (
      !storedUser ||
      !(await comparePassword(currentPassword, storedUser.passwordHash))
    ) {
      throw new HttpError(401, 'Current password is incorrect.');
    }
    if (currentPassword === newPassword) {
      throw new HttpError(400, 'Choose a new password different from the current password.');
    }

    await repository.changePassword(user.id, await hashPassword(newPassword));
    response.status(200).json({ message: 'Password changed successfully.' });
  });

  app.get('/products', requireAuthentication, async (request, response) => {
    const search =
      typeof request.query.search === 'string' ? request.query.search.trim() : '';
    if (search.length > 100) {
      throw new HttpError(400, 'Product search must be 100 characters or fewer.');
    }
    const result = await products.list(search);
    const visibleProducts =
      request.authenticatedUser?.role === 'admin'
        ? result
        : result.map(({ purchasePrice: _purchasePrice, ...product }) => product);
    response.status(200).json({ products: visibleProducts });
  });

  app.get(
    '/products/:id',
    requireAuthentication,
    async (request, response) => {
      const id = productIdParam(request);
      const product = await products.findById(id);
      if (!product) {
        throw new HttpError(404, 'Product not found.');
      }
      if (request.authenticatedUser?.role === 'admin') {
        response.status(200).json({ product });
      } else {
        const { purchasePrice: _purchasePrice, ...visibleProduct } = product;
        response.status(200).json({ product: visibleProduct });
      }
    },
  );

  app.post(
    '/products',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const input = validateProductInput(requestBody(request));
      try {
        const product = await products.create(
          input,
          request.authenticatedUser?.id,
        );
        response.status(201).json({ product });
      } catch (error) {
        if (
          typeof error === 'object' &&
          error !== null &&
          'code' in error &&
          error.code === '23505'
        ) {
          throw new HttpError(409, 'That product code is already in use.');
        }
        throw error;
      }
    },
  );

  app.put(
    '/products/:id',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const id = productIdParam(request);
      const input = validateProductInput(requestBody(request));
      try {
        const product = await products.update(
          id,
          input,
          request.authenticatedUser?.id,
        );
        if (!product) {
          throw new HttpError(404, 'Product not found.');
        }
        response.status(200).json({ product });
      } catch (error) {
        if (
          typeof error === 'object' &&
          error !== null &&
          'code' in error &&
          error.code === '23505'
        ) {
          throw new HttpError(409, 'That product code is already in use.');
        }
        throw error;
      }
    },
  );

  app.delete(
    '/products/:id',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const id = productIdParam(request);
      if (!(await products.softDelete(id, request.authenticatedUser?.id))) {
        throw new HttpError(404, 'Product not found.');
      }
      response.status(204).end();
    },
  );

  app.get('/settings/gst', requireAuthentication, async (_request, response) => {
    response.status(200).json({ settings: await billing.getGstSettings() });
  });

  app.put(
    '/admin/settings/gst',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const settings = validateGstSettings(requestBody(request));
      response.status(200).json({
        settings: await billing.updateGstSettings(
          settings,
          request.authenticatedUser?.id,
        ),
      });
    },
  );

  app.post(
    '/invoices',
    requireAuthentication,
    async (request, response) => {
      const user = request.authenticatedUser;
      if (!user) {
        throw new HttpError(401, 'Authentication required.');
      }
      const invoiceRequest = validateInvoiceRequest(requestBody(request));
      const result = await billing.createInvoice(user.id, invoiceRequest);
      response
        .status(result.replayed ? 200 : 201)
        .json({ invoice: result.invoice, replayed: result.replayed });
    },
  );

  app.get('/invoices', requireAuthentication, async (request, response) => {
    const rawLimit = request.query.limit;
    const limit = rawLimit === undefined ? 50 : Number(rawLimit);
    if (
      typeof rawLimit !== 'undefined' &&
      (typeof rawLimit !== 'string' ||
        !/^\d+$/.test(rawLimit) ||
        !Number.isInteger(limit) ||
        limit < 1 ||
        limit > 100)
    ) {
      throw new HttpError(400, 'Invoice list limit must be between 1 and 100.');
    }
    response.status(200).json({ invoices: await billing.listInvoices(limit) });
  });

  app.get(
    '/invoices/:id',
    requireAuthentication,
    async (request, response) => {
      const id = invoiceIdParam(request);
      const invoice = await billing.findInvoiceById(id);
      if (!invoice) throw new HttpError(404, 'Invoice not found.');
      response.status(200).json({ invoice });
    },
  );

  app.delete(
    '/admin/invoices/:id',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const id = invoiceIdParam(request);
      const user = request.authenticatedUser;
      if (!user) throw new HttpError(401, 'Authentication required.');
      if (!(await billing.voidInvoice(id, user.id))) {
        throw new HttpError(404, 'Invoice not found or already voided.');
      }
      response.status(204).end();
    },
  );

  app.post(
    '/admin/cashiers',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const body = requestBody(request);
      const username = validateUsername(body.username);
      const password = validatePassword(body.password);
      const passwordHash = await hashPassword(password);

      try {
        const user = await repository.createCashier(
          username,
          passwordHash,
          request.authenticatedUser?.id,
        );
        response.status(201).json({ user });
      } catch (error) {
        if (
          typeof error === 'object' &&
          error !== null &&
          'code' in error &&
          error.code === '23505'
        ) {
          throw new HttpError(409, 'That username is already in use.');
        }
        throw error;
      }
    },
  );

  app.post(
    '/admin/users/password',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      if (!repository.changePassword) {
        throw new HttpError(503, 'Password resets are unavailable.');
      }
      const body = requestBody(request);
      const username = validateUsername(body.username);
      const newPassword = validatePassword(body.newPassword);
      const target = await repository.findByUsername(username);
      if (!target) throw new HttpError(404, 'Account not found.');
      await repository.changePassword(
        target.id,
        await hashPassword(newPassword),
        request.authenticatedUser?.id,
      );
      response.status(200).json({
        message: 'Password reset.',
        user: { id: target.id, username: target.username, role: target.role },
      });
    },
  );

  app.get(
    '/admin/dashboard',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const date = reportDate(request.query.date, 'date', localDate());
      response.status(200).json({ dashboard: await reports.dashboard(date) });
    },
  );

  app.get(
    '/admin/reports/sales',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const startDate = reportDate(request.query.startDate, 'startDate');
      const endDate = reportDate(request.query.endDate, 'endDate');
      if (startDate > endDate) {
        throw new HttpError(400, 'startDate must be on or before endDate.');
      }
      const dayCount =
        (Date.parse(`${endDate}T00:00:00Z`) -
          Date.parse(`${startDate}T00:00:00Z`)) /
        86400000;
      if (dayCount > 365) {
        throw new HttpError(400, 'Sales report date ranges cannot exceed 366 days.');
      }
      response.status(200).json({
        report: await reports.sales(startDate, endDate),
      });
    },
  );

  app.get(
    '/admin/audit',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const limit = queryLimit(request.query.limit, 100, 500, 'Audit limit');
      response.status(200).json({ events: await reports.auditLog(limit) });
    },
  );

  app.get(
    '/admin/backups',
    requireAuthentication,
    requireRole('admin'),
    async (_request, response) => {
      response.status(200).json({ backups: await backups.list() });
    },
  );

  app.post(
    '/admin/backups',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const user = request.authenticatedUser;
      if (!user) throw new HttpError(401, 'Authentication required.');
      response.status(201).json({ backup: await backups.create(user.id) });
    },
  );

  app.post(
    '/admin/backups/restore',
    requireAuthentication,
    requireRole('admin'),
    async (request, response) => {
      const user = request.authenticatedUser;
      if (!user) throw new HttpError(401, 'Authentication required.');
      const body = requestBody(request);
      if (
        typeof body.fileName !== 'string' ||
        typeof body.confirmation !== 'string'
      ) {
        throw new HttpError(400, 'A backup file name and explicit confirmation are required.');
      }
      await backups.restore(user.id, body.fileName, body.confirmation);
      response.status(200).json({ status: 'ok', message: 'Database restore completed.' });
    },
  );

  app.post('/internal/shutdown', (request, response) => {
    if (!hasValidLocalProcessToken(request)) {
      response.status(404).json({ status: 'error', message: 'Route not found' });
      return;
    }

    response.status(202).json({ status: 'shutting_down' });
    setImmediate(() => options.onShutdown?.());
  });

  app.get(
    '/cashier/dashboard',
    requireAuthentication,
    requireRole('cashier'),
    (_request, response) => {
      response.status(200).json({ role: 'cashier', message: 'Cashier home' });
    },
  );

  app.use((_request, response) => {
    response.status(404).json({
      status: 'error',
      message: 'Route not found',
    });
  });

  const errorHandler: ErrorRequestHandler = (
    error: unknown,
    _request,
    response,
    _next,
  ) => {
    if (error instanceof HttpError) {
      response.status(error.status).json({
        status: 'error',
        message: error.message,
      });
      return;
    }

    if (error instanceof SyntaxError && 'status' in error && error.status === 400) {
      response.status(400).json({
        status: 'error',
        message: 'Request body must contain valid JSON.',
      });
      return;
    }

    if (
      typeof error === 'object' &&
      error !== null &&
      'status' in error &&
      error.status === 413
    ) {
      response.status(413).json({
        status: 'error',
        message: 'Request body is too large.',
      });
      return;
    }

    console.error(
      'Unhandled API error:',
      error instanceof Error ? error.message : 'Unknown error',
    );
    response.status(500).json({
      status: 'error',
      message: 'Internal server error',
    });
  };
  app.use(errorHandler);

  return app;
}
