import 'dotenv/config';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { Pool, PoolClient } from 'pg';
import { getDatabasePool } from './database';

export async function applyMigrations(pool: Pool): Promise<void> {
  const client = await pool.connect();

  try {
    const directory = path.resolve(__dirname, '../migrations');
    const files = (await readdir(directory))
      .filter((file) => /^\d+_[a-z0-9_-]+\.sql$/i.test(file))
      .sort();

    await applyMigrationsWithClient(client, directory, files);
  } finally {
    client.release();
  }
}

async function applyMigrationsWithClient(
  client: PoolClient,
  directory: string,
  files: string[],
): Promise<void> {
  await client.query('BEGIN');
  try {
    await client.query('SELECT pg_advisory_xact_lock($1)', [63817401]);
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version VARCHAR(255) PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);

    const appliedResult = await client.query<{ version: string }>(
      'SELECT version FROM schema_migrations',
    );
    const appliedVersions = new Set(
      appliedResult.rows.map(({ version }) => version),
    );
    let appliedCount = 0;
    for (const file of files) {
      if (appliedVersions.has(file)) continue;

      const sql = await readFile(path.join(directory, file), 'utf8');
      await client.query(sql);
      await client.query('INSERT INTO schema_migrations (version) VALUES ($1)', [
        file,
      ]);
      appliedCount += 1;
    }

    await client.query('COMMIT');
    console.log(
      `Database migrations complete; ${appliedCount} migration(s) applied.`,
    );
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  }
}

async function main(): Promise<void> {
  const pool = getDatabasePool();
  try {
    await applyMigrations(pool);
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  main().catch((error: unknown) => {
    console.error(
      'Database migrations failed:',
      error instanceof Error ? error.message : 'Unknown error',
    );
    process.exitCode = 1;
  });
}
