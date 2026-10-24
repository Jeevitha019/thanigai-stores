export type DatabaseStartupFailureCategory =
  | 'authentication'
  | 'database_missing'
  | 'insufficient_privileges'
  | 'server_unavailable'
  | 'migration';

export function getDatabaseStartupFailureCategory(
  error: unknown,
): DatabaseStartupFailureCategory {
  const code =
    typeof error === 'object' && error !== null && 'code' in error
      ? String(error.code)
      : '';

  if (code === '28P01' || code === '28000') return 'authentication';
  if (code === '3D000') return 'database_missing';
  if (code === '42501') return 'insufficient_privileges';
  if (
    [
      'ECONNREFUSED',
      'ECONNRESET',
      'ETIMEDOUT',
      'ENOTFOUND',
      'EHOSTUNREACH',
    ].includes(code)
  ) {
    return 'server_unavailable';
  }
  return 'migration';
}
