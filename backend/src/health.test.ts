import request from 'supertest';
import { describe, it } from 'node:test';
import { deepStrictEqual, equal } from 'node:assert/strict';
import { createApp } from './app';

describe('local API health endpoint', () => {
  it('reports readiness only when the database check succeeds', async () => {
    const app = createApp({
      jwtSecret: 'test-only-jwt-secret-with-more-than-thirty-two-bytes',
      healthCheck: async () => {},
    });
    const response = await request(app).get('/health').expect(200);

    deepStrictEqual(response.body, {
      status: 'ok',
      service: 'thanigai-stores-api',
      database: 'ok',
      message: 'Thanigai Stores API is running',
    });
  });

  it('returns an unavailable status without leaking database errors', async () => {
    const app = createApp({
      jwtSecret: 'test-only-jwt-secret-with-more-than-thirty-two-bytes',
      healthCheck: async () => {
        throw new Error('sensitive connection details');
      },
    });
    const response = await request(app).get('/health').expect(503);

    equal(response.body.status, 'error');
    equal(response.body.database, 'unavailable');
    equal(response.body.message, 'The local database is unavailable.');
  });

  it('requires the local shutdown token before requesting graceful shutdown', async () => {
    let shutdownRequested = false;
    const app = createApp({
      jwtSecret: 'test-only-jwt-secret-with-more-than-thirty-two-bytes',
      shutdownToken: 'test-only-local-shutdown-token',
      onShutdown: () => {
        shutdownRequested = true;
      },
    });

    await request(app).get('/internal/identity').expect(404);
    await request(app)
      .get('/internal/identity')
      .set('X-Local-Shutdown-Token', 'test-only-local-shutdown-token')
      .expect(200)
      .expect({
        service: 'thanigai-stores-api',
        processId: process.pid,
        parentProcessId: process.ppid,
      });
    await request(app)
      .post('/internal/shutdown')
      .set('X-Local-Shutdown-Token', 'incorrect-token')
      .expect(404);
    equal(shutdownRequested, false);

    const response = await request(app)
      .post('/internal/shutdown')
      .set('X-Local-Shutdown-Token', 'test-only-local-shutdown-token')
      .expect(202);
    deepStrictEqual(response.body, { status: 'shutting_down' });
    await new Promise((resolve) => setImmediate(resolve));
    equal(shutdownRequested, true);
  });
});
