import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { chmod, lstat, mkdir, readdir, rm, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { HttpError } from './auth';
import { recordAuditEvent } from './audit';

export interface BackupFile {
  fileName: string;
  createdAt: string;
  sizeBytes: number;
}

type CommandRunner = (
  executable: string,
  args: string[],
  environment: NodeJS.ProcessEnv,
) => Promise<void>;

export interface BackupOperations {
  readonly isBusy: boolean;
  list(): Promise<BackupFile[]>;
  create(actorId: string | null): Promise<BackupFile>;
  restore(
    actorId: string | null,
    fileName: string,
    confirmation: string,
  ): Promise<void>;
}

interface BackupServiceOptions {
  directory?: string;
  runner?: CommandRunner;
  audit?: typeof recordAuditEvent;
  environment?: NodeJS.ProcessEnv;
}

function databaseEnvironment(source: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const required = ['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASSWORD'];
  const missing = required.filter((name) => !source[name]);
  if (missing.length) {
    throw new Error(`Missing database environment variables: ${missing.join(', ')}`);
  }
  const port = Number(source.DB_PORT ?? '5432');
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('DB_PORT must be an integer between 1 and 65535.');
  }
  const environment: NodeJS.ProcessEnv = {};
  for (const name of [
    'PATH',
    'PATHEXT',
    'SystemRoot',
    'WINDIR',
    'TEMP',
    'TMP',
  ]) {
    const value = source[name];
    if (value) environment[name] = value;
  }
  return {
    ...environment,
    PGHOST: source.DB_HOST,
    PGPORT: String(port),
    PGUSER: source.DB_USER,
    PGPASSWORD: source.DB_PASSWORD,
    PGDATABASE: source.DB_NAME,
  };
}

function runCommand(
  executable: string,
  args: string[],
  environment: NodeJS.ProcessEnv,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      env: environment,
      stdio: ['ignore', 'ignore', 'ignore'],
      windowsHide: true,
    });
    child.once('error', () => {
      reject(
        new Error(
          'Could not start the PostgreSQL backup utility. Check the configured PostgreSQL client-tool paths.',
        ),
      );
    });
    child.once('close', (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(
          new Error(
            `The PostgreSQL backup utility failed with exit code ${code ?? 'unknown'}. Check database connectivity, permissions, and available disk space.`,
          ),
        );
      }
    });
  });
}

function backupDirectory(): string {
  const appData =
    process.env.APPDATA ??
    path.join(homedir(), 'AppData', 'Roaming');
  const directory = path.resolve(appData, 'Malligai Kadai', 'Backups');
  const projectRoot = path.resolve(__dirname, '../..');
  const relative = path.relative(projectRoot, directory);
  if (
    relative === '' ||
    (!relative.startsWith(`..${path.sep}`) &&
      relative !== '..' &&
      !path.isAbsolute(relative))
  ) {
    throw new Error('Database backups must be stored outside the application project folder.');
  }
  return directory;
}

function validateFileName(fileName: string): string {
  if (!/^malligai-kadai_\d{8}_\d{6}_[a-f0-9-]{36}\.dump$/.test(fileName)) {
    throw new HttpError(400, 'Choose a backup created by this application.');
  }
  return fileName;
}

export class BackupService {
  private readonly directory: string;
  private readonly runner: CommandRunner;
  private readonly audit: typeof recordAuditEvent;
  private readonly environment: NodeJS.ProcessEnv;
  private operationRunning = false;

  constructor(options: BackupServiceOptions = {}) {
    this.directory = options.directory ?? backupDirectory();
    this.runner = options.runner ?? runCommand;
    this.audit = options.audit ?? recordAuditEvent;
    this.environment = options.environment ?? process.env;
  }

  get isBusy(): boolean {
    return this.operationRunning;
  }

  async list(): Promise<BackupFile[]> {
    await this.ensureDirectory();
    const names = (await readdir(this.directory))
      .filter((name) => /^malligai-kadai_\d{8}_\d{6}_[a-f0-9-]{36}\.dump$/.test(name))
      .sort()
      .reverse();
    const found = await Promise.all(
      names.map(async (fileName) => {
        const file = await lstat(path.join(this.directory, fileName));
        if (!file.isFile()) return null;
        return {
          fileName,
          createdAt: file.birthtime.toISOString(),
          sizeBytes: file.size,
        };
      }),
    );
    return found.filter((file): file is BackupFile => file !== null);
  }

  async create(actorId: string | null): Promise<BackupFile> {
    return this.withExclusiveOperation(async () => {
      const fileName = this.newFileName();
      const fullPath = path.join(this.directory, fileName);
      try {
        await this.ensureDirectory();
        const environment = databaseEnvironment(this.environment);
        const dumpTool =
          this.environment.PG_DUMP_PATH ??
          path.join(
            this.environment.ProgramFiles ?? 'C:\\Program Files',
            'PostgreSQL',
            '18',
            'bin',
            process.platform === 'win32' ? 'pg_dump.exe' : 'pg_dump',
          );
        await this.runner(
          dumpTool,
          [
            '--format=custom',
            `--file=${fullPath}`,
            `--host=${this.environment.DB_HOST}`,
            `--port=${environment.PGPORT}`,
            `--username=${this.environment.DB_USER}`,
            `--dbname=${this.environment.DB_NAME}`,
          ],
          environment,
        );
        await this.runner(
          this.restoreTool(),
          ['--list', fullPath],
          environment,
        );
        const file = await lstat(fullPath);
        if (file.size === 0) {
          throw new Error('The PostgreSQL backup utility produced an empty backup.');
        }
        if (process.platform !== 'win32') {
          await chmod(fullPath, 0o600);
        }
        await this.audit({
          actorId,
          action: 'backup.created',
          entityType: 'database_backup',
          entityId: fileName,
          details: { sizeBytes: file.size },
        });
        return {
          fileName,
          createdAt: file.birthtime.toISOString(),
          sizeBytes: file.size,
        };
      } catch (error) {
        let cleanupFailure: unknown;
        try {
          await rm(fullPath, { force: true });
        } catch (caughtCleanupFailure) {
          cleanupFailure = caughtCleanupFailure;
        }
        await this.audit({
          actorId,
          action: 'backup.failed',
          entityType: 'database_backup',
          entityId: fileName,
          ...(cleanupFailure === undefined
            ? {}
            : { details: { cleanupFailed: true } }),
        });
        if (cleanupFailure !== undefined) {
          throw new AggregateError(
            [error, cleanupFailure],
            'Backup failed and its incomplete file could not be removed.',
          );
        }
        if (error instanceof HttpError) throw error;
        throw new HttpError(
          500,
          error instanceof Error ? error.message : 'The database backup failed.',
        );
      }
    });
  }

  async restore(
    actorId: string | null,
    requestedFileName: string,
    confirmation: string,
  ): Promise<void> {
    const fileName = validateFileName(requestedFileName);
    if (confirmation !== `RESTORE ${fileName}`) {
      throw new HttpError(
        400,
        `Explicit confirmation is required. Enter RESTORE ${fileName} exactly.`,
      );
    }

    await this.withExclusiveOperation(async () => {
      const fullPath = path.join(this.directory, fileName);
      try {
        await this.ensureDirectory();
        const file = await lstat(fullPath);
        if (!file.isFile() || file.size === 0) {
          throw new HttpError(404, 'The selected backup file is unavailable or empty.');
        }
        const environment = databaseEnvironment(this.environment);
        const restoreTool = this.restoreTool();
        const connectionArgs = [
          `--host=${this.environment.DB_HOST}`,
          `--port=${environment.PGPORT}`,
          `--username=${this.environment.DB_USER}`,
          `--dbname=${this.environment.DB_NAME}`,
        ];
        await this.runner(restoreTool, ['--list', fullPath], environment);
        await this.runner(
          restoreTool,
          [
            '--exit-on-error',
            '--single-transaction',
            '--clean',
            '--if-exists',
            '--no-owner',
            '--no-privileges',
            ...connectionArgs,
            fullPath,
          ],
          environment,
        );
      } catch (error) {
        await this.audit({
          actorId,
          action: 'backup.restore_failed',
          entityType: 'database_backup',
          entityId: fileName,
        });
        if (error instanceof HttpError) throw error;
        throw new HttpError(
          500,
          error instanceof Error ? error.message : 'The database restore failed.',
        );
      }
      try {
        await this.audit({
          actorId: null,
          action: 'backup.restored',
          entityType: 'database_backup',
          entityId: fileName,
          details: actorId === null ? {} : { requestedById: actorId },
        });
      } catch {
        throw new HttpError(
          500,
          'Database restore completed, but its success could not be written to the audit log. Verify the restored database before continuing.',
        );
      }
    });
  }

  private async withExclusiveOperation<T>(operation: () => Promise<T>): Promise<T> {
    if (this.operationRunning) {
      throw new HttpError(409, 'Another backup or restore operation is already running.');
    }
    this.operationRunning = true;
    try {
      return await operation();
    } finally {
      this.operationRunning = false;
    }
  }

  private async ensureDirectory(): Promise<void> {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    if (process.platform !== 'win32') {
      await chmod(this.directory, 0o700);
    }
  }

  private restoreTool(): string {
    return (
      this.environment.PG_RESTORE_PATH ??
      path.join(
        this.environment.ProgramFiles ?? 'C:\\Program Files',
        'PostgreSQL',
        '18',
        'bin',
        process.platform === 'win32' ? 'pg_restore.exe' : 'pg_restore',
      )
    );
  }

  private newFileName(): string {
    const timestamp = new Date()
      .toISOString()
      .replace(/[-:]/g, '')
      .replace(/\.\d{3}Z$/, '')
      .replace('T', '_');
    return `malligai-kadai_${timestamp}_${randomUUID()}.dump`;
  }
}

export const postgresBackupService = new BackupService();
