param(
  [ValidateSet('Start', 'Stop')]
  [string]$Mode = 'Start',
  [Parameter(Mandatory = $true)]
  [string]$RuntimeDirectory,
  [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'Malligai Kadai'),
  [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'Malligai Kadai\PostgreSQL\18\data'),
  [string]$LogPath,
  [string]$ResultPath
)

$ErrorActionPreference = 'Stop'

$databaseName = 'malligai_kadai'
$applicationRole = 'malligai_app'
$bootstrapPath = Join-Path $StateDirectory 'database-bootstrap.bin'
$pendingPath = Join-Path $StateDirectory 'database-bootstrap.pending.bin'
$script:SetupStage = 'starting'
$script:StageStartedAtUtc = [DateTime]::UtcNow
$script:ManagerStartedAtUtc = [DateTime]::UtcNow
$script:GeneratedSecrets = @()

if (-not $LogPath) {
  $LogPath = Join-Path $StateDirectory 'database-setup.log'
}
New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
Add-Content -LiteralPath $LogPath -Value (
  "`nMalligai Kadai PostgreSQL $Mode started at $([DateTime]::UtcNow.ToString('u'))."
) -Encoding utf8

function Write-SetupLog {
  param([string]$Message)

  foreach ($secret in $script:GeneratedSecrets) {
    if ($secret) {
      $Message = $Message.Replace([string]$secret, '[REDACTED]')
    }
  }
  $Message = [regex]::Replace($Message, '\b[0-9a-f]{96}\b', '[REDACTED]')
  Add-Content -LiteralPath $LogPath -Value (
    '{0:u} [{1}] {2}' -f [DateTime]::UtcNow, $script:SetupStage, $Message
  ) -Encoding utf8
}

Write-SetupLog "manager_started manager_pid=$PID"

function Set-SetupStage {
  param([string]$Stage)

  $now = [DateTime]::UtcNow
  $elapsed = [int][Math]::Max(0, ($now - $script:StageStartedAtUtc).TotalMilliseconds)
  Write-SetupLog "stage_elapsed_ms=$elapsed"
  $script:SetupStage = $Stage
  $script:StageStartedAtUtc = $now
  Write-SetupLog "stage_started manager_pid=$PID"
}

function Write-SetupResult {
  param([int]$ExitCode)

  $elapsed = [int][Math]::Max(
    0,
    ([DateTime]::UtcNow - $script:ManagerStartedAtUtc).TotalMilliseconds
  )
  Write-SetupLog "manager_exit_code=$ExitCode elapsed_ms=$elapsed"
  if (-not $ResultPath) {
    return
  }
  $temporaryPath = "$ResultPath.tmp"
  try {
    [IO.File]::WriteAllText($temporaryPath, [string]$ExitCode)
    Move-Item -LiteralPath $temporaryPath -Destination $ResultPath -Force
  } catch {
    Write-SetupLog "Could not write the setup result file (exit code $ExitCode)."
  }
}

function New-RandomHex {
  param([int]$ByteCount = 48)

  $bytes = New-Object byte[] $ByteCount
  $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $generator.GetBytes($bytes)
  } finally {
    $generator.Dispose()
  }
  return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Protect-Settings {
  param([string]$Json)

  Add-Type -AssemblyName System.Security
  $entropy = [Text.Encoding]::UTF8.GetBytes('MalligaiKadai|PerUserDatabase|v1')
  $plain = [Text.Encoding]::UTF8.GetBytes($Json)
  return [Security.Cryptography.ProtectedData]::Protect(
    $plain,
    $entropy,
    [Security.Cryptography.DataProtectionScope]::CurrentUser
  )
}

function Read-ProtectedSettings {
  param([string]$Path)

  Add-Type -AssemblyName System.Security
  $entropy = [Text.Encoding]::UTF8.GetBytes('MalligaiKadai|PerUserDatabase|v1')
  $encrypted = [IO.File]::ReadAllBytes($Path)
  $plain = [Security.Cryptography.ProtectedData]::Unprotect(
    $encrypted,
    $entropy,
    [Security.Cryptography.DataProtectionScope]::CurrentUser
  )
  return [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
}

function Write-ProtectedSettings {
  param(
    [string]$Path,
    [object]$Settings
  )

  $temporaryPath = "$Path.tmp"
  [IO.File]::WriteAllBytes(
    $temporaryPath,
    (Protect-Settings -Json ($Settings | ConvertTo-Json -Compress))
  )
  Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-FreeDatabasePort {
  foreach ($port in 55432..55462) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
    try {
      $listener.Start()
      return $port
    } catch {
      continue
    } finally {
      $listener.Stop()
    }
  }
  throw 'No free local PostgreSQL port was found in the reserved range 55432-55462.'
}

function Save-NativeOutput {
  param(
    [string]$Prefix,
    [object[]]$Output
  )

  foreach ($line in ($Output | Select-Object -Last 80)) {
    if ($null -ne $line) {
      Write-SetupLog ("{0}: {1}" -f $Prefix, $line.ToString())
    }
  }
}

function Invoke-Psql {
  param(
    [string]$PsqlPath,
    [string]$Database,
    [string]$Username,
    [string]$Password,
    [int]$Port,
    [string[]]$Arguments
  )

  $previousPassword = $env:PGPASSWORD
  $env:PGPASSWORD = $Password
  try {
    $output = @(& $PsqlPath -X -w --set=ON_ERROR_STOP=1 `
      --host=127.0.0.1 "--port=$Port" `
      "--username=$Username" "--dbname=$Database" @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    Save-NativeOutput -Prefix 'psql' -Output $output
    if ($exitCode -ne 0) {
      Write-SetupLog "psql exited with code $exitCode."
      throw "PostgreSQL database setup failed with exit code $exitCode. Review the psql diagnostics above."
    }
  } finally {
    $env:PGPASSWORD = $previousPassword
  }
}

function Get-PostgresTool {
  param([string]$Name)

  $path = Join-Path $RuntimeDirectory "bin\$Name.exe"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "The bundled PostgreSQL tool '$Name.exe' is missing."
  }
  return $path
}

function Test-PostgresRunning {
  param([string]$PgCtlPath)

  $output = @(& $PgCtlPath status "--pgdata=$DataDirectory" 2>&1)
  $exitCode = $LASTEXITCODE
  if ($exitCode -eq 0) {
    return $true
  }
  if ($output) {
    Save-NativeOutput -Prefix 'pg_ctl status' -Output $output
  }
  return $false
}

function Wait-StartedProcess {
  param(
    [int]$ProcessId,
    [int]$TimeoutMilliseconds
  )

  if (-not ('MalligaiKadaiProcessWaiter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class MalligaiKadaiProcessWaiter
{
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetExitCodeProcess(IntPtr handle, out uint exitCode);
  [DllImport("kernel32.dll")]
  private static extern bool CloseHandle(IntPtr handle);

  public static uint WaitForExitCode(int processId, uint timeoutMilliseconds)
  {
    IntPtr handle = OpenProcess(0x00100000u | 0x1000u, false, processId);
    if (handle == IntPtr.Zero)
      throw new Win32Exception(Marshal.GetLastWin32Error());

    try
    {
      uint result = WaitForSingleObject(handle, timeoutMilliseconds);
      if (result == 258u)
        throw new TimeoutException("The process did not exit before the timeout.");
      if (result != 0u)
        throw new Win32Exception(Marshal.GetLastWin32Error());

      uint exitCode;
      if (!GetExitCodeProcess(handle, out exitCode))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      return exitCode;
    }
    finally
    {
      CloseHandle(handle);
    }
  }
}
'@
  }

  return [MalligaiKadaiProcessWaiter]::WaitForExitCode(
    $ProcessId,
    [uint32]$TimeoutMilliseconds
  )
}

function Start-LocalPostgres {
  param(
    [string]$PgCtlPath,
    [string]$ReadyPath,
    [int]$Port
  )

  Set-SetupStage 'checking PostgreSQL service readiness'
  $readinessStartedAt = [DateTime]::UtcNow
  if (Test-PostgresRunning -PgCtlPath $PgCtlPath) {
    $output = @(& $ReadyPath --host=127.0.0.1 "--port=$Port" `
      --username=postgres --dbname=postgres 2>&1)
    if ($LASTEXITCODE -ne 0) {
      Save-NativeOutput -Prefix 'pg_isready' -Output $output
      throw 'The existing PostgreSQL process is not listening on the saved local port. It was not stopped or replaced.'
    }
    $elapsed = [int][Math]::Max(
      0,
      ([DateTime]::UtcNow - $readinessStartedAt).TotalMilliseconds
    )
    Write-SetupLog "existing_service_ready_ms=$elapsed"
    Write-SetupLog 'The existing per-user PostgreSQL process is already ready.'
    return
  }

  Set-SetupStage 'starting the per-user PostgreSQL process'
  $serverLog = Join-Path $StateDirectory 'postgresql-server.log'
  $stdoutLog = Join-Path $StateDirectory 'pg_ctl-start.stdout.log'
  $stderrLog = Join-Path $StateDirectory 'pg_ctl-start.stderr.log'
  Set-Content -LiteralPath $stdoutLog -Value '' -Encoding utf8
  Set-Content -LiteralPath $stderrLog -Value '' -Encoding utf8
  $options = "-h 127.0.0.1 -p $Port"
  $arguments = 'start "--pgdata={0}" "--log={1}" "--options={2}" --wait --timeout=90' -f `
    $DataDirectory, $serverLog, $options
  $start = Start-Process -FilePath $PgCtlPath -ArgumentList $arguments `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
  $exitCode = Wait-StartedProcess -ProcessId $start.Id `
    -TimeoutMilliseconds 95000
  $output = @(
    Get-Content -LiteralPath $stdoutLog -ErrorAction SilentlyContinue
    Get-Content -LiteralPath $stderrLog -ErrorAction SilentlyContinue
  )
  Save-NativeOutput -Prefix 'pg_ctl start' -Output $output
  if ($exitCode -ne 0) {
    Write-SetupLog "pg_ctl start exited with code $exitCode."
    throw "The local PostgreSQL process failed to start with exit code $exitCode. Review postgresql-server.log."
  }

  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  do {
    $output = @(& $ReadyPath --host=127.0.0.1 "--port=$Port" `
      --username=postgres --dbname=postgres 2>&1)
    if ($LASTEXITCODE -eq 0) {
      $elapsed = [int][Math]::Max(
        0,
        ([DateTime]::UtcNow - $readinessStartedAt).TotalMilliseconds
      )
      Write-SetupLog "new_service_ready_ms=$elapsed"
      Write-SetupLog 'The per-user PostgreSQL process is accepting loopback connections.'
      return
    }
    Start-Sleep -Milliseconds 500
  } while ([DateTime]::UtcNow -lt $deadline)

  Save-NativeOutput -Prefix 'pg_isready' -Output $output
  throw 'The local PostgreSQL process started but did not accept loopback connections.'
}

function Stop-LocalPostgres {
  $pgCtlPath = Join-Path $RuntimeDirectory 'bin\pg_ctl.exe'
  if (-not (Test-Path -LiteralPath $pgCtlPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Join-Path $DataDirectory 'PG_VERSION') -PathType Leaf)) {
    Write-SetupLog 'No per-user PostgreSQL cluster exists; nothing to stop.'
    return
  }
  if (-not (Test-PostgresRunning -PgCtlPath $pgCtlPath)) {
    Write-SetupLog 'The per-user PostgreSQL process is already stopped.'
    return
  }

  Set-SetupStage 'stopping the per-user PostgreSQL process'
  $output = @(& $pgCtlPath stop "--pgdata=$DataDirectory" --mode=fast `
    --wait --timeout=30 2>&1)
  $exitCode = $LASTEXITCODE
  Save-NativeOutput -Prefix 'pg_ctl stop' -Output $output
  if ($exitCode -ne 0) {
    Write-SetupLog "pg_ctl stop exited with code $exitCode."
    throw "The local PostgreSQL process did not stop cleanly (exit code $exitCode)."
  }
  Write-SetupLog 'The per-user PostgreSQL process stopped cleanly.'
}

function Start-Database {
  Set-SetupStage 'validating the bundled PostgreSQL runtime'
  $postgresPath = Get-PostgresTool -Name 'postgres'
  $initdbPath = Get-PostgresTool -Name 'initdb'
  $pgCtlPath = Get-PostgresTool -Name 'pg_ctl'
  $psqlPath = Get-PostgresTool -Name 'psql'
  $readyPath = Get-PostgresTool -Name 'pg_isready'
  $version = & $postgresPath --version 2>&1
  if ($LASTEXITCODE -ne 0 -or $version -notmatch 'PostgreSQL\) 18\.') {
    throw 'The bundled runtime is invalid or is not PostgreSQL 18.'
  }

  $hasFinalSettings = Test-Path -LiteralPath $bootstrapPath -PathType Leaf
  $hasPendingSettings = Test-Path -LiteralPath $pendingPath -PathType Leaf
  if ($hasFinalSettings) {
    try {
      $settings = Read-ProtectedSettings -Path $bootstrapPath
    } catch {
      throw 'The saved per-user PostgreSQL settings could not be read. The data directory was left untouched.'
    }
  } elseif ($hasPendingSettings) {
    try {
      $settings = Read-ProtectedSettings -Path $pendingPath
    } catch {
      throw 'The pending per-user PostgreSQL settings could not be read. The data directory was left untouched.'
    }
  } else {
    if (Test-Path -LiteralPath $DataDirectory) {
      $files = Get-ChildItem -LiteralPath $DataDirectory -Force
      if ($files) {
        throw 'A PostgreSQL data directory exists without Malligai Kadai recovery settings. It was not changed.'
      }
    }
    $settings = @{
      host = '127.0.0.1'
      port = Get-FreeDatabasePort
      database = $databaseName
      username = $applicationRole
      password = New-RandomHex
      postgresPassword = New-RandomHex
      jwtSecret = New-RandomHex
      initialSetupToken = New-RandomHex
    }
    $script:GeneratedSecrets = @(
      [string]$settings.password,
      [string]$settings.postgresPassword,
      [string]$settings.jwtSecret,
      [string]$settings.initialSetupToken
    )
    Write-ProtectedSettings -Path $pendingPath -Settings $settings
    Write-SetupLog 'Created protected per-user recovery settings.'
  }

  $script:GeneratedSecrets = @(
    [string]$settings.password,
    [string]$settings.postgresPassword,
    [string]$settings.jwtSecret,
    [string]$settings.initialSetupToken
  )
  if (
    $settings.port -isnot [ValueType] -or
    [int]$settings.port -lt 55432 -or [int]$settings.port -gt 55462 -or
    $settings.password -notmatch '^[0-9a-f]{96}$' -or
    $settings.postgresPassword -notmatch '^[0-9a-f]{96}$' -or
    $settings.jwtSecret -notmatch '^[0-9a-f]{96}$' -or
    $settings.initialSetupToken -notmatch '^[0-9a-f]{96}$'
  ) {
    throw 'Saved per-user PostgreSQL recovery settings are invalid. The data directory was left untouched.'
  }

  Set-SetupStage 'checking the per-user data directory'
  $clusterVersionPath = Join-Path $DataDirectory 'PG_VERSION'
  $configurationPath = Join-Path $DataDirectory 'postgresql.conf'
  if (-not (Test-Path -LiteralPath $clusterVersionPath -PathType Leaf)) {
    if ($hasFinalSettings) {
      throw 'The saved per-user database settings exist but the PostgreSQL cluster is missing. No data was recreated.'
    }
    if (Test-Path -LiteralPath $DataDirectory) {
      $files = Get-ChildItem -LiteralPath $DataDirectory -Force
      if ($files) {
        throw 'PostgreSQL initialization left a non-empty incomplete directory. It was preserved; contact support before retrying.'
      }
    }
    Set-SetupStage 'initializing the per-user shop database'
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    $passwordFile = Join-Path $StateDirectory 'postgres-password.tmp'
    try {
      Set-Content -LiteralPath $passwordFile -Value $settings.postgresPassword `
        -NoNewline -Encoding ascii
      $output = @(& $initdbPath "--pgdata=$DataDirectory" `
        '--username=postgres' "--pwfile=$passwordFile" `
        '--auth-local=scram-sha-256' '--auth-host=scram-sha-256' `
        '--encoding=UTF8' 2>&1)
      $exitCode = $LASTEXITCODE
      Save-NativeOutput -Prefix 'initdb' -Output $output
      if ($exitCode -ne 0) {
        Write-SetupLog "initdb exited with code $exitCode."
        throw "PostgreSQL initialization failed with exit code $exitCode. Review the initdb diagnostics above."
      }
      Write-SetupLog 'Initialized a new PostgreSQL cluster in the current Windows user profile.'
    } finally {
      Remove-Item -LiteralPath $passwordFile -Force -ErrorAction SilentlyContinue
    }
  } elseif (
    (Get-Content -LiteralPath $clusterVersionPath -Raw).Trim() -ne '18' -or
    -not (Test-Path -LiteralPath $configurationPath -PathType Leaf)
  ) {
    throw 'The existing per-user PostgreSQL directory is not a complete version-18 cluster. It was preserved.'
  }

  $configuration = Get-Content -LiteralPath $configurationPath -Raw
  if ($configuration -notmatch '(?m)^\s*listen_addresses\s*=') {
    Add-Content -LiteralPath $configurationPath -Value "`nlisten_addresses = '127.0.0.1'`n" -Encoding ascii
  }
  if ($configuration -notmatch '(?m)^\s*port\s*=') {
    Add-Content -LiteralPath $configurationPath -Value "`nport = $($settings.port)`n" -Encoding ascii
  }
  Start-LocalPostgres -PgCtlPath $pgCtlPath -ReadyPath $readyPath `
    -Port ([int]$settings.port)

  if (-not $hasFinalSettings) {
    Set-SetupStage 'creating the per-user application database'
    $sqlDirectory = Join-Path $StateDirectory ('setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sqlDirectory -Force | Out-Null
    $sqlPath = Join-Path $sqlDirectory 'initialize-shop.sql'
    $sql = @"
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$applicationRole') AS app_role_exists \gset
\if :app_role_exists
ALTER ROLE $applicationRole LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD '$($settings.password)';
\else
CREATE ROLE $applicationRole LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD '$($settings.password)';
\endif
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$databaseName') AS shop_database_exists \gset
\if :shop_database_exists
\else
CREATE DATABASE $databaseName OWNER $applicationRole;
\endif
"@
    try {
      Set-Content -LiteralPath $sqlPath -Value $sql -Encoding ascii
      Invoke-Psql -PsqlPath $psqlPath -Database 'postgres' `
        -Username 'postgres' -Password $settings.postgresPassword `
        -Port ([int]$settings.port) -Arguments @("--file=$sqlPath")
    } finally {
      Remove-Item -LiteralPath $sqlDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Set-SetupStage 'verifying per-user application database access'
    Invoke-Psql -PsqlPath $psqlPath -Database $databaseName `
      -Username $applicationRole -Password $settings.password `
      -Port ([int]$settings.port) -Arguments @('--command=SELECT 1;')
    Write-ProtectedSettings -Path $bootstrapPath -Settings $settings
    Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
  }

  Set-SetupStage 'complete'
  Write-SetupLog "Local PostgreSQL is ready on loopback port $($settings.port)."
}

try {
  if ($Mode -eq 'Stop') {
    Stop-LocalPostgres
  } else {
    Start-Database
  }
  Write-SetupResult -ExitCode 0
  exit 0
} catch {
  $message = $_.Exception.Message
  foreach ($secret in $script:GeneratedSecrets) {
    if ($secret) {
      $message = $message.Replace([string]$secret, '[REDACTED]')
    }
  }
  $message = [regex]::Replace($message, '\b[0-9a-f]{96}\b', '[REDACTED]')
  Write-SetupLog "Failed: $message"
  Write-SetupResult -ExitCode 1
  Write-Error "Malligai Kadai PostgreSQL $Mode failed during $script:SetupStage. Details were written to $LogPath."
  exit 1
}
