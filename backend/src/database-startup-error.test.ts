import { deepStrictEqual } from 'node:assert/strict';
import { it } from 'node:test';
import { getDatabaseStartupFailureCategory } from './database-startup-error';

it('classifies PostgreSQL setup failures without exposing error details', () => {
  const cases = [
    ['28P01', 'authentication'],
    ['28000', 'authentication'],
    ['3D000', 'database_missing'],
    ['42501', 'insufficient_privileges'],
    ['ECONNREFUSED', 'server_unavailable'],
    ['ETIMEDOUT', 'server_unavailable'],
    ['ENOTFOUND', 'server_unavailable'],
    ['XX000', 'migration'],
    ['', 'migration'],
  ] as const;

  for (const [code, expected] of cases) {
    deepStrictEqual(
      getDatabaseStartupFailureCategory({
        code,
        message: 'secret-bearing driver message must not be returned',
      }),
      expected,
    );
  }
});
