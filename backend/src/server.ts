import 'dotenv/config';
import { createApp } from './app';
import { getJwtSecret } from './auth';
import { getDatabasePool } from './database';
import { applyMigrations } from './migrate';
import { getDatabaseStartupFailureCategory } from './database-startup-error';
import { performance } from 'node:perf_hooks';

const port = Number(process.env.API_PORT ?? '3000');

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('API_PORT must be an integer between 1 and 65535.');
}

async function start(): Promise<void> {
  const startupStartedAt = performance.now();
  const pool = getDatabasePool();
  try {
    const databaseStartedAt = performance.now();
    await pool.query('SELECT 1');
    console.log(
      `[startup] database_connection_ms=${Math.round(performance.now() - databaseStartedAt)}`,
    );
    const migrationStartedAt = performance.now();
    await applyMigrations(pool);
    console.log(
      `[startup] migrations_ms=${Math.round(performance.now() - migrationStartedAt)}`,
    );
  } catch (error) {
    const category = getDatabaseStartupFailureCategory(error);
    console.error(`THANIGAI_DB_STARTUP_FAILURE=${category}`);
    console.error(
      `[startup] database_and_migrations_failed_ms=${Math.round(performance.now() - startupStartedAt)} category=${category}`,
    );
    await pool.end();
    process.exitCode = 1;
    return;
  }

  let requestShutdown: () => void = () => {};
  const app = createApp({
    jwtSecret: getJwtSecret(),
    initialSetupToken: process.env.INITIAL_SETUP_TOKEN,
    shutdownToken: process.env.INITIAL_SETUP_TOKEN,
    onShutdown: () => requestShutdown(),
    healthCheck: async () => {
      await pool.query('SELECT 1');
    },
  });
  const server = app.listen(port, '127.0.0.1', () => {
    console.log(
      `[startup] api_listening_ms=${Math.round(performance.now() - startupStartedAt)} pid=${process.pid} ppid=${process.ppid}`,
    );
    console.log(`Thanigai Stores API listening at http://127.0.0.1:${port}`);
  });

  let shutdownPromise: Promise<void> | undefined;
  let parentMonitor: NodeJS.Timeout | undefined;
  const shutdown = (): void => {
    if (shutdownPromise) return;
    const shutdownStartedAt = performance.now();
    if (parentMonitor) clearInterval(parentMonitor);
    shutdownPromise = new Promise<void>((resolve) => {
      if (!server.listening) {
        resolve();
        return;
      }
      server.close(() => resolve());
      server.closeAllConnections();
    }).then(async () => {
      await pool.end();
      console.log(
        `[shutdown] completed_ms=${Math.round(performance.now() - shutdownStartedAt)}`,
      );
    });
    void shutdownPromise.then(
      () => process.exit(0),
      (error: unknown) => {
        console.error(
          'Unable to shut down the Thanigai Stores API cleanly:',
          error instanceof Error ? error.message : 'Unknown error',
        );
        process.exit(1);
      },
    );
  };
  requestShutdown = shutdown;
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
  if (process.env.THANIGAI_SUPERVISED === '1') {
    parentMonitor = setInterval(() => {
      try {
        process.kill(process.ppid, 0);
      } catch {
        shutdown();
      }
    }, 1000);
    parentMonitor.unref();
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (command: string) => {
      if (command.trim() === 'shutdown') shutdown();
    });
    process.stdin.once('end', shutdown);
  }

  server.on('error', (error: NodeJS.ErrnoException) => {
    if (error.code === 'EADDRINUSE') {
      console.error('THANIGAI_API_STARTUP_FAILURE=port_in_use');
    }
    console.error(`Unable to start the API server: ${error.message}`);
    if (parentMonitor) clearInterval(parentMonitor);
    void pool.end().finally(() => process.exit(1));
  });
}

start().catch((error: unknown) => {
  console.error(
    'Unable to start Thanigai Stores API:',
    error instanceof Error ? error.message : 'Unknown error',
  );
  void getDatabasePool().end();
  process.exitCode = 1;
});
