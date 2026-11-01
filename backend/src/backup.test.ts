import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import { deepStrictEqual, equal, ok, rejects } from 'node:assert/strict';
import { BackupService } from './backup';
import { HttpError } from './auth';

const backupName =
  'thanigai-stores_20261019_120000_123e4567-e89b-12d3-a456-426614174000.dump';
const credentials: NodeJS.ProcessEnv = {
  DB_HOST: '127.0.0.1',
  DB_PORT: '5432',
  DB_NAME: 'unit_test',
  DB_USER: 'test_user',
  DB_PASSWORD: 'test-password-that-must-not-be-logged',
  PATH: process.env.PATH,
  PATHEXT: process.env.PATHEXT,
  SystemRoot: process.env.SystemRoot,
  TEMP: process.env.TEMP,
};

describe('database backup service', () => {
  let directory: string;

  before(async () => {
    directory = await mkdtemp(path.join(os.tmpdir(), 'malligai-backup-test-'));
  });

  after(async () => {
    await rm(directory, { recursive: true, force: true });
  });

  it('creates, lists, and restores a verified backup without putting secrets in arguments', async () => {
    const commands: Array<{ executable: string; args: string[] }> = [];
    const audit: string[] = [];
    const service = new BackupService({
      directory,
      environment: credentials,
      runner: async (executable, args, environment) => {
        commands.push({ executable, args });
        equal(environment.PGPASSWORD, credentials.DB_PASSWORD);
        if (args.some((argument) => argument.startsWith('--file='))) {
          const output = args.find((argument) => argument.startsWith('--file='))!;
          await writeFile(output.slice('--file='.length), 'valid custom-format backup');
        }
      },
      audit: async (event) => {
        audit.push(event.action);
      },
    });

    const backup = await service.create('7');
    ok(backup.fileName.endsWith('.dump'));
    ok(backup.sizeBytes > 0);
    deepStrictEqual(await service.list(), [backup]);
    ok(commands.every(({ args }) => !args.some((arg) => arg.includes(credentials.DB_PASSWORD!))));
    ok(commands[0].args.includes(`--username=${credentials.DB_USER}`));
    await rejects(
      service.restore('7', backup.fileName, 'not confirmed'),
      (error: unknown) => error instanceof HttpError && error.status === 400,
    );
    equal(commands.length, 2);
    await service.restore('7', backup.fileName, `RESTORE ${backup.fileName}`);
    equal(commands.length, 4);
    deepStrictEqual(audit, ['backup.created', 'backup.restored']);
    ok(commands[3].args.includes('--single-transaction'));
    ok(commands[3].args.includes('--clean'));
  });

  it('records backup utility failures, removes partial output, and reports the error', async () => {
    const audit: string[] = [];
    const service = new BackupService({
      directory,
      environment: credentials,
      runner: async (_executable, args) => {
        const output = args.find((argument) => argument.startsWith('--file='));
        if (output) await writeFile(output.slice('--file='.length), '');
        throw new Error('Injected backup utility failure.');
      },
      audit: async (event) => {
        audit.push(event.action);
      },
    });
    await rejects(service.create('7'), /Injected backup utility failure/);
    deepStrictEqual(audit, ['backup.failed']);
    equal((await service.list()).length, 1);
  });

  it('rejects untrusted file names, missing backup files, and incomplete database configuration', async () => {
    const audit: string[] = [];
    const service = new BackupService({
      directory,
      environment: credentials,
      runner: async () => {},
      audit: async (event) => {
        audit.push(event.action);
      },
    });
    await rejects(
      service.restore('7', '..\\outside.dump', 'anything'),
      (error: unknown) => error instanceof HttpError && error.status === 400,
    );
    await rejects(
      service.restore('7', backupName, `RESTORE ${backupName}`),
      (error: unknown) => error instanceof Error && /ENOENT/.test(error.message),
    );
    const missingConfig = new BackupService({
      directory,
      environment: { ...credentials, DB_PASSWORD: undefined },
      runner: async () => {},
      audit: async () => {},
    });
    await rejects(missingConfig.create('7'), /DB_PASSWORD/);
    equal((await stat(directory)).isDirectory(), true);
    deepStrictEqual(audit, ['backup.restore_failed']);
  });
});
