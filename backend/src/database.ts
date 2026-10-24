import { Pool, PoolConfig } from 'pg';

function getDatabaseConfig(): PoolConfig {
  const requiredVariables = ['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASSWORD'];
  const missingVariables = requiredVariables.filter(
    (name) => !process.env[name],
  );

  if (missingVariables.length > 0) {
    throw new Error(
      `Missing required database environment variables: ${missingVariables.join(', ')}`,
    );
  }

  const port = Number(process.env.DB_PORT ?? '5432');
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('DB_PORT must be an integer between 1 and 65535.');
  }

  return {
    host: process.env.DB_HOST,
    port,
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    connectionTimeoutMillis: 5_000,
    statement_timeout: 10_000,
    query_timeout: 12_000,
    idleTimeoutMillis: 30_000,
  };
}

let pool: Pool | undefined;

export function getDatabasePool(): Pool {
  pool ??= new Pool(getDatabaseConfig());
  return pool;
}

export async function checkDatabaseConnection(): Promise<void> {
  const database = getDatabasePool();

  try {
    await database.query('SELECT 1');
  } finally {
    await database.end();
    pool = undefined;
  }
}
