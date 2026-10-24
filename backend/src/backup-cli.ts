import 'dotenv/config';
import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { BackupService } from './backup';

async function main(): Promise<void> {
  const command = process.argv[2];
  const service = new BackupService();
  if (command === 'backup') {
    const backup = await service.create(null);
    console.log(`Database backup created: ${backup.fileName} (${backup.sizeBytes} bytes).`);
    return;
  }

  if (command === 'restore') {
    const fileName = process.argv[3];
    if (!fileName) {
      throw new Error('Usage: npm run db:restore -- <backup-file-name>');
    }
    const readline = createInterface({ input: stdin, output: stdout });
    try {
      const confirmation = await readline.question(
        `WARNING: this replaces the current database contents. Type RESTORE ${fileName} to continue: `,
      );
      await service.restore(null, fileName, confirmation);
      console.log('Database restore completed.');
    } finally {
      readline.close();
    }
    return;
  }

  throw new Error('Choose either the backup or restore command.');
}

main().catch((error: unknown) => {
  console.error(
    'Database backup/restore failed:',
    error instanceof Error ? error.message : 'Unknown error',
  );
  process.exitCode = 1;
});
