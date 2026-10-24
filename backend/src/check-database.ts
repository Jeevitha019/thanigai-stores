import 'dotenv/config';
import { checkDatabaseConnection } from './database';

async function main(): Promise<void> {
  try {
    await checkDatabaseConnection();
    console.log('PostgreSQL connection successful.');
  } catch (error) {
    console.error(
      'PostgreSQL connection failed:',
      error instanceof Error ? error.message : 'Unknown error',
    );
    process.exitCode = 1;
  }
}

void main();
