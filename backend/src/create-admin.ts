import 'dotenv/config';
import bcrypt from 'bcryptjs';
import { emitKeypressEvents } from 'node:readline';
import { createInterface } from 'node:readline/promises';
import { getDatabasePool } from './database';
import { validatePassword, validateUsername } from './auth';

async function readHiddenPassword(): Promise<string> {
  if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== 'function') {
    throw new Error('Run this command in an interactive terminal to enter a password safely.');
  }

  emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdout.write('Initial admin password (input hidden): ');

  return new Promise((resolve, reject) => {
    let password = '';
    const onKeypress = (character: string, key: { name?: string; ctrl?: boolean }) => {
      if (key.ctrl && key.name === 'c') {
        process.stdin.off('keypress', onKeypress);
        process.stdin.setRawMode(false);
        process.stdout.write('\n');
        reject(new Error('Password entry cancelled.'));
        return;
      }

      if (key.name === 'return' || key.name === 'enter') {
        process.stdin.off('keypress', onKeypress);
        process.stdin.setRawMode(false);
        process.stdout.write('\n');
        resolve(password);
        return;
      }

      if (key.name === 'backspace' || key.name === 'delete') {
        if (password.length > 0) {
          password = password.slice(0, -1);
          process.stdout.write('\b \b');
        }
        return;
      }

      if (!key.ctrl && character && character.length === 1) {
        password += character;
        process.stdout.write('*');
      }
    };

    process.stdin.on('keypress', onKeypress);
  });
}

async function main(): Promise<void> {
  if (process.env.ADMIN_USERNAME || process.env.ADMIN_PASSWORD) {
    throw new Error(
      'Do not supply admin credentials through environment variables; enter them at the secure prompt.',
    );
  }

  const prompt = createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  const username = validateUsername(
    (await prompt.question('Initial admin username: ')).trim(),
  );
  prompt.close();
  const password = validatePassword(await readHiddenPassword());
  const passwordHash = await bcrypt.hash(password, 12);
  const pool = getDatabasePool();
  const client = await pool.connect();

  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock($1)', [63817402]);
    const existingAdmin = await client.query(
      "SELECT 1 FROM app_users WHERE role = 'admin' LIMIT 1",
    );
    if (existingAdmin.rowCount) {
      throw new Error('An admin account already exists; refusing to create another initial admin.');
    }

    await client.query(
      "INSERT INTO app_users (username, password_hash, role) VALUES ($1, $2, 'admin')",
      [username, passwordHash],
    );
    await client.query('COMMIT');
    console.log(`Initial admin account "${username}" created.`);
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
    await pool.end();
  }
}

main().catch((error: unknown) => {
  console.error(
    'Initial admin setup failed:',
    error instanceof Error ? error.message : 'Unknown error',
  );
  process.exitCode = 1;
});
