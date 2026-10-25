import { Pool } from 'pg';
import { getDatabasePool } from './database';
import { insertAuditEvent } from './audit';
import { AuthRepository, PublicUser, StoredUser, UserRole } from './types';

interface UserRow {
  id: string;
  username: string;
  role: UserRole;
  password_hash?: string;
}

function toPublicUser(row: UserRow): PublicUser {
  return { id: row.id, username: row.username, role: row.role };
}

export function createPostgresAuthRepository(
  getPool: () => Pool = getDatabasePool,
): AuthRepository {
  return {
    async findByUsername(username): Promise<StoredUser | null> {
      const result = await getPool().query<UserRow>(
        `SELECT id, username, role, password_hash
         FROM app_users
         WHERE LOWER(username) = LOWER($1)`,
        [username],
      );
      const row = result.rows[0];
      if (!row?.password_hash) {
        return null;
      }
      return {
        ...toPublicUser(row),
        passwordHash: row.password_hash,
      };
    },

    async findById(id): Promise<PublicUser | null> {
      const result = await getPool().query<UserRow>(
        'SELECT id, username, role FROM app_users WHERE id = $1',
        [id],
      );
      const row = result.rows[0];
      return row ? toPublicUser(row) : null;
    },

    async hasAdmin(): Promise<boolean> {
      const result = await getPool().query(
        "SELECT 1 FROM app_users WHERE role = 'admin' LIMIT 1",
      );
      return (result.rowCount ?? 0) > 0;
    },

    async createInitialAdmin(username, passwordHash): Promise<PublicUser> {
      const client = await getPool().connect();
      try {
        await client.query('BEGIN');
        await client.query('SELECT pg_advisory_xact_lock($1)', [63817402]);
        const existingAdmin = await client.query(
          "SELECT 1 FROM app_users WHERE role = 'admin' LIMIT 1",
        );
        if (existingAdmin.rowCount) {
          const error = new Error('An admin account already exists.');
          Object.assign(error, { code: 'ADMIN_EXISTS' });
          throw error;
        }

        const result = await client.query<UserRow>(
          `INSERT INTO app_users (username, password_hash, role)
           VALUES ($1, $2, 'admin')
           RETURNING id, username, role`,
          [username, passwordHash],
        );
        const row = result.rows[0];
        if (!row) {
          throw new Error('Initial admin account could not be created.');
        }
        await insertAuditEvent(client, {
          actorId: row.id,
          action: 'auth.initial_admin_created',
          entityType: 'user',
          entityId: row.id,
        });

        await client.query('COMMIT');
        return toPublicUser(row);
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      } finally {
        client.release();
      }
    },

    async createCashier(username, passwordHash, createdBy): Promise<PublicUser> {
      const client = await getPool().connect();
      try {
        await client.query('BEGIN');
        const result = await client.query<UserRow>(
          `INSERT INTO app_users (username, password_hash, role)
           VALUES ($1, $2, 'cashier')
           RETURNING id, username, role`,
          [username, passwordHash],
        );
        const row = result.rows[0];
        if (!row) {
          throw new Error('Cashier account could not be created.');
        }
        await insertAuditEvent(client, {
          actorId: createdBy ?? null,
          action: 'cashier.created',
          entityType: 'user',
          entityId: row.id,
        });
        await client.query('COMMIT');
        return toPublicUser(row);
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      } finally {
        client.release();
      }
    },

    async changePassword(id, passwordHash, actorId = id) {
      const client = await getPool().connect();
      try {
        await client.query('BEGIN');
        const result = await client.query(
          'UPDATE app_users SET password_hash = $2 WHERE id = $1',
          [id, passwordHash],
        );
        if (result.rowCount !== 1) {
          throw new Error('The account password could not be updated.');
        }
        await insertAuditEvent(client, {
          actorId,
          action: 'auth.password.changed',
          entityType: 'user',
          entityId: id,
        });
        await client.query('COMMIT');
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      } finally {
        client.release();
      }
    },

    async recordLogin(id) {
      const client = await getPool().connect();
      try {
        await insertAuditEvent(client, {
          actorId: id,
          action: 'auth.login',
          entityType: 'user',
          entityId: id,
        });
      } finally {
        client.release();
      }
    },
  };
}

export const postgresAuthRepository = createPostgresAuthRepository();
