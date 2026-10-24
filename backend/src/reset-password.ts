import { emitKeypressEvents } from 'node:readline';
import { createInterface } from 'node:readline/promises';
import { validatePassword, validateUsername } from './auth';

const apiBaseUrl = 'http://127.0.0.1:3000';

async function readHiddenPassword(label: string): Promise<string> {
  if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== 'function') {
    throw new Error('Run this command in an interactive terminal.');
  }

  emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdout.write(`${label} (input hidden): `);

  return new Promise((resolve, reject) => {
    let password = '';
    const finish = (error?: Error) => {
      process.stdin.off('keypress', onKeypress);
      process.stdin.setRawMode(false);
      process.stdout.write('\n');
      if (error) reject(error);
      else resolve(password);
    };
    const onKeypress = (character: string, key: { name?: string; ctrl?: boolean }) => {
      if (key.ctrl && key.name === 'c') {
        finish(new Error('Password entry cancelled.'));
        return;
      }
      if (key.name === 'return' || key.name === 'enter') {
        finish();
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

async function postJson(
  path: string,
  body: Record<string, string>,
  token?: string,
): Promise<Record<string, unknown>> {
  let response: Response;
  try {
    response = await fetch(`${apiBaseUrl}${path}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(8000),
    });
  } catch {
    throw new Error(
      'Could not connect to Thanigai Stores. Open the app and try again.',
    );
  }

  let result: unknown;
  try {
    result = await response.json();
  } catch {
    throw new Error('The local API returned an invalid response.');
  }
  if (result === null || typeof result !== 'object' || Array.isArray(result)) {
    throw new Error('The local API returned an invalid response.');
  }
  const bodyResult = result as Record<string, unknown>;
  if (!response.ok) {
    throw new Error(
      typeof bodyResult.message === 'string'
        ? bodyResult.message
        : 'The password reset request failed.',
    );
  }
  return bodyResult;
}

async function main(): Promise<void> {
  const prompt = createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  let adminUsername: string;
  let targetUsername: string;
  try {
    adminUsername = validateUsername(
      (await prompt.question('Admin username: ')).trim(),
    );
    targetUsername = validateUsername(
      (await prompt.question('Account username to reset (Admin or Cashier): ')).trim(),
    );
  } finally {
    prompt.close();
  }

  const adminPassword = await readHiddenPassword('Admin password');
  const login = await postJson('/auth/login', {
    username: adminUsername,
    password: adminPassword,
  });
  if (typeof login.token !== 'string' || !login.token) {
    throw new Error('The local API did not return a valid Admin session.');
  }

  const newPassword = validatePassword(
    await readHiddenPassword('New account password'),
  );
  const confirmation = await readHiddenPassword('Confirm new password');
  if (newPassword !== confirmation) {
    throw new Error('The new passwords do not match.');
  }

  const result = await postJson(
    '/admin/users/password',
    { username: targetUsername, newPassword },
    login.token,
  );
  const user = result.user;
  if (
    user === null ||
    typeof user !== 'object' ||
    !('username' in user) ||
    !('role' in user)
  ) {
    throw new Error('The local API returned an invalid account response.');
  }
  console.log(
    `Password reset for ${user.username} (${user.role}). Sign in with the new password.`,
  );
}

main().catch((error: unknown) => {
  console.error(
    'Password reset failed:',
    error instanceof Error ? error.message : 'Unknown error',
  );
  process.exitCode = 1;
});
