import { PoolClient } from 'pg';
import { getDatabasePool } from './database';

export interface AuditEntry {
  actorId: string | null;
  action: string;
  entityType: string;
  entityId?: string | null;
  details?: Record<string, string | number | boolean | null>;
}

export async function insertAuditEvent(
  client: PoolClient,
  entry: AuditEntry,
): Promise<void> {
  await client.query(
    `INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
     VALUES ($1, $2, $3, $4, $5::jsonb)`,
    [
      entry.actorId,
      entry.action,
      entry.entityType,
      entry.entityId ?? null,
      JSON.stringify(entry.details ?? {}),
    ],
  );
}

export async function recordAuditEvent(entry: AuditEntry): Promise<void> {
  const client = await getDatabasePool().connect();
  try {
    await client.query('BEGIN');
    await insertAuditEvent(client, entry);
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
