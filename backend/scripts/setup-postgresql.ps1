param(
  [string]$DatabaseName = 'malligai_kadai',
  [string]$AppRole = 'malligai_app',
  [string]$HostName = '127.0.0.1',
  [int]$Port = 5432,
  [string]$PsqlPath
)

$ErrorActionPreference = 'Stop'

foreach ($identifier in @($DatabaseName, $AppRole)) {
  if ($identifier -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,62}$') {
    throw 'Database and role names must use simple PostgreSQL identifiers.'
  }
}
if ($Port -lt 1 -or $Port -gt 65535) {
  throw 'Port must be between 1 and 65535.'
}

if (-not $PsqlPath) {
  $psqlCommand = Get-Command psql.exe -ErrorAction SilentlyContinue
  if ($psqlCommand) {
    $PsqlPath = $psqlCommand.Source
  } else {
    $service = Get-CimInstance Win32_Service `
      -Filter "Name='postgresql-x64-18'" -ErrorAction SilentlyContinue
    if ($service -and $service.PathName -match '-D\s+"([^"]+)"') {
      $dataDirectory = $Matches[1]
      $candidate = Join-Path (Split-Path $dataDirectory -Parent) 'bin\psql.exe'
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $PsqlPath = $candidate
      }
    }
  }
}
if (-not $PsqlPath -or -not (Test-Path -LiteralPath $PsqlPath -PathType Leaf)) {
  throw 'psql.exe was not found. Install PostgreSQL 18 command-line tools or pass -PsqlPath.'
}

$administrator = (Read-Host 'PostgreSQL setup administrator role').Trim()
if (-not $administrator) {
  throw 'A PostgreSQL setup administrator role is required.'
}

function Invoke-Psql {
  param(
    [string]$Database,
    [string[]]$Arguments
  )
  & $PsqlPath -X -W --set=ON_ERROR_STOP=1 `
    --host=$HostName --port=$Port --username=$administrator `
    --dbname=$Database @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw 'PostgreSQL setup command failed. No database was dropped or reset.'
  }
}

Write-Host 'psql will prompt securely for the PostgreSQL administrator password.'
$state = Invoke-Psql -Database 'postgres' -Arguments @(
  '--tuples-only',
  '--no-align',
  "--command=SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$DatabaseName')::text || '|' || EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$AppRole')::text || '|' || EXISTS (SELECT 1 FROM pg_auth_members WHERE member = (SELECT oid FROM pg_roles WHERE rolname = '$AppRole'))::text;"
)
$parts = ([string]($state | Select-Object -Last 1)).Trim().Split('|')
if ($parts.Count -ne 3) {
  throw 'Could not determine whether the requested database and role exist.'
}
$databaseExists = $parts[0] -eq 'true'
$roleExists = $parts[1] -eq 'true'
$hasRoleMemberships = $parts[2] -eq 'true'

if ($databaseExists) {
  $answer = Read-Host "Database '$DatabaseName' already exists. Continue without creating or resetting it, and update only Malligai Kadai access and object ownership? Type YES to continue"
  if ($answer -cne 'YES') { throw 'Cancelled; the existing database was not changed.' }
} else {
  $answer = Read-Host "Database '$DatabaseName' does not exist. Create this new, empty database? Type CREATE to continue"
  if ($answer -cne 'CREATE') { throw 'Cancelled; no database was created.' }
}

if ($roleExists) {
  $answer = Read-Host "Role '$AppRole' already exists. Remove its direct role memberships, restrict its flags, rotate its password, and update Malligai Kadai access? Type YES to continue"
  if ($answer -cne 'YES') { throw 'Cancelled; the existing role was not changed.' }
}

if (-not $roleExists) {
  Invoke-Psql -Database 'postgres' -Arguments @(
    "--command=CREATE ROLE $AppRole LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;"
  ) | Out-Null
} else {
  Invoke-Psql -Database 'postgres' -Arguments @(
    "--command=ALTER ROLE $AppRole LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;"
  ) | Out-Null
  if ($hasRoleMemberships) {
    $membershipSql = @"
DO `$`$
DECLARE
  granted_role record;
BEGIN
  FOR granted_role IN
    SELECT granted.rolname
    FROM pg_auth_members membership
    JOIN pg_roles granted ON granted.oid = membership.roleid
    WHERE membership.member = (SELECT oid FROM pg_roles WHERE rolname = '$AppRole')
  LOOP
    EXECUTE format('REVOKE %I FROM %I', granted_role.rolname, '$AppRole');
  END LOOP;
END
`$`$;
"@
    $membershipPath = Join-Path ([IO.Path]::GetTempPath()) (
      'malligai-role-membership-' + [guid]::NewGuid().ToString('N') + '.sql'
    )
    try {
      Set-Content -LiteralPath $membershipPath -Value $membershipSql -Encoding ascii
      Invoke-Psql -Database 'postgres' -Arguments @("--file=$membershipPath") | Out-Null
    } finally {
      if (Test-Path -LiteralPath $membershipPath) {
        Remove-Item -LiteralPath $membershipPath -Force
      }
    }
  }
}

Write-Host "Set a strong password for '$AppRole' at the hidden psql prompt. Do not reuse the PostgreSQL administrator password."
Invoke-Psql -Database 'postgres' -Arguments @("--command=\password $AppRole") | Out-Null

if (-not $databaseExists) {
  Invoke-Psql -Database 'postgres' -Arguments @(
    "--command=CREATE DATABASE `"$DatabaseName`";"
  ) | Out-Null
}

$setupSql = @"
GRANT CONNECT ON DATABASE "$DatabaseName" TO "$AppRole";
\connect "$DatabaseName"
GRANT USAGE, CREATE ON SCHEMA public TO "$AppRole";
DO `$`$
DECLARE
  app_object record;
BEGIN
  FOR app_object IN
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename = ANY (ARRAY[
        'app_users', 'products', 'invoices', 'invoice_items',
        'invoice_payments', 'shop_settings', 'schema_migrations',
        'inventory_movements', 'audit_logs'
      ])
  LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO %I', app_object.tablename, '$AppRole');
  END LOOP;
END
`$`$;
ALTER SEQUENCE IF EXISTS public.invoice_number_seq OWNER TO "$AppRole";
"@
$scriptPath = Join-Path ([IO.Path]::GetTempPath()) (
  'malligai-postgresql-setup-' + [guid]::NewGuid().ToString('N') + '.sql'
)
try {
  Set-Content -LiteralPath $scriptPath -Value $setupSql -Encoding ascii
  Invoke-Psql -Database 'postgres' -Arguments @("--file=$scriptPath") | Out-Null
} finally {
  if (Test-Path -LiteralPath $scriptPath) {
    Remove-Item -LiteralPath $scriptPath -Force
  }
}

Write-Host "PostgreSQL access setup completed for '$AppRole' on '$DatabaseName'."
Write-Host 'The role is not a superuser and cannot create databases or roles.'
Write-Host 'Existing rows were not dropped, truncated, or reset.'
Write-Host 'Enter the app role password in Malligai Kadai first-run setup; it is not saved by this script.'
