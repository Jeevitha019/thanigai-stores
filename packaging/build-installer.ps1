param(
  [string]$Flutter = 'C:\flutter\flutter\bin\flutter.bat',
  [string]$Node = 'C:\Program Files\nodejs\node.exe',
  [string]$PostgreSqlRoot = 'C:\Program Files\PostgreSQL\18',
  [string]$OutputBaseFilename = 'ThanigaiStores-Setup'
)

$ErrorActionPreference = 'Stop'
if ($OutputBaseFilename -notmatch '^[A-Za-z0-9_-]+$') {
  throw 'OutputBaseFilename may contain only letters, numbers, hyphens, and underscores.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterProject = Join-Path $projectRoot 'malligai_kadai'
$backendProject = Join-Path $projectRoot 'backend'
$stageRoot = Join-Path $PSScriptRoot 'stage'
$payloadRoot = Join-Path $stageRoot 'app'
$backendPayload = Join-Path $payloadRoot 'backend'
$backendBuild = Join-Path $stageRoot 'backend-build'
$runtimeBackend = Join-Path $stageRoot 'backend-runtime'
$databaseTools = Join-Path $payloadRoot 'database-tools'
$postgresqlPayload = Join-Path $payloadRoot 'postgresql\18'
$postgresqlRuntime = Join-Path $postgresqlPayload 'runtime'
$postgresqlCrtPayload = $payloadRoot
$artifactRoot = Join-Path $projectRoot 'artifacts'
$iss = Join-Path $PSScriptRoot 'MalligaiKadai.iss'
$nodeSha256 = 'e3be0545990c90995d7bf3a7af5d64af1f2e0fc1bbd9b79c27f7abc1e9676e50'
$pubspec = Get-Content -LiteralPath (Join-Path $flutterProject 'pubspec.yaml') -Raw
$versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$')
if (-not $versionMatch.Success) {
  throw 'Could not read the application version from malligai_kadai\pubspec.yaml.'
}
$appVersion = $versionMatch.Groups[1].Value

if (-not (Test-Path -LiteralPath $Flutter -PathType Leaf)) {
  throw "Flutter SDK command was not found at '$Flutter'. Pass -Flutter with its full path."
}
if (-not (Test-Path -LiteralPath $Node -PathType Leaf)) {
  throw "Node.js runtime was not found at '$Node'. Pass -Node with its full path."
}
$compilerCandidates = @(
  (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
  (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
)
$iscc = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) {
  throw 'Inno Setup 6 compiler (ISCC.exe) is required. Install JRSoftware.InnoSetup first.'
}
$visualStudioRoots = @(
  (Join-Path $env:ProgramFiles 'Microsoft Visual Studio'),
  (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
$vcRuntimeCandidates = @(
  foreach ($root in $visualStudioRoots) {
    Get-ChildItem -LiteralPath $root -Directory `
      -Filter 'Microsoft.VC*.CRT' -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\x64\\Microsoft\.VC\d+\.CRT$' }
  }
)
$vcRuntimeVersions = @(
  foreach ($candidate in $vcRuntimeCandidates) {
    if ($candidate.FullName -match '\\MSVC\\(?<version>\d+\.\d+\.\d+)\\x64\\Microsoft\.VC\d+\.CRT$') {
      try {
        [pscustomobject]@{
          Version = [version]$Matches.version
          Path = $candidate.FullName
        }
      } catch {
        continue
      }
    }
  }
)
$vcRuntime = $vcRuntimeVersions |
  Sort-Object Version -Descending |
  Select-Object -First 1
if (-not $vcRuntime) {
  throw 'The Microsoft x64 app-local Visual C++ runtime was not found in Visual Studio. Install the C++ redistributable workload.'
}
foreach ($requiredDll in @(
  'concrt140.dll',
  'msvcp140.dll',
  'vcruntime140.dll',
  'vcruntime140_1.dll'
)) {
  $dllPath = Join-Path $vcRuntime.Path $requiredDll
  if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
    throw "The app-local Visual C++ runtime is incomplete. Missing '$requiredDll'."
  }
  $dllSignature = Get-AuthenticodeSignature -FilePath $dllPath
  if (
    $dllSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
    $dllSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation'
  ) {
    throw "The Microsoft Visual C++ runtime DLL '$requiredDll' failed Authenticode verification."
  }
}
$nodeSignature = Get-AuthenticodeSignature -FilePath $Node
if (
  $nodeSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
  $nodeSignature.SignerCertificate.Subject -notmatch 'OpenJS Foundation' -or
  (Get-FileHash -LiteralPath $Node -Algorithm SHA256).Hash -ne $nodeSha256
) {
  throw 'The bundled Node.js runtime must match the signed, verified Node.js 24.13.1 win-x64 release.'
}
$postgresExecutable = Join-Path $PostgreSqlRoot 'bin\postgres.exe'
foreach ($executable in @(
  'postgres.exe','pg_ctl.exe','initdb.exe','psql.exe','pg_dump.exe',
  'pg_dumpall.exe','pg_restore.exe','pg_isready.exe'
)) {
  $path = Join-Path $PostgreSqlRoot "bin\$executable"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "PostgreSQL 18 runtime is incomplete at '$PostgreSqlRoot'. Missing '$executable'."
  }
}
$postgresVersion = & $postgresExecutable --version
if ($LASTEXITCODE -ne 0 -or $postgresVersion -notmatch 'PostgreSQL\) 18\.') {
  throw "A working PostgreSQL 18 installation is required to stage the local server runtime. Found: $postgresVersion"
}

Write-Host 'Building the Flutter Windows release...'
& (Join-Path $PSScriptRoot 'generate-app-icon.ps1')
Push-Location $flutterProject
try {
  & $Flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "Flutter release build failed with exit code $LASTEXITCODE." }
} finally {
  Pop-Location
}

if (Test-Path -LiteralPath $stageRoot) {
  Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $payloadRoot,$backendPayload,$backendBuild,$runtimeBackend,$databaseTools,$postgresqlRuntime,$artifactRoot -Force | Out-Null
Write-Host ("Staging the PostgreSQL server runtime ({0}) without development databases or pgAdmin..." -f $postgresVersion)
foreach ($directory in @('bin','lib','share')) {
  Copy-Item -LiteralPath (Join-Path $PostgreSqlRoot $directory) -Destination $postgresqlRuntime -Recurse -Force
}
foreach ($license in @('server_license.txt','commandlinetools_3rd_party_licenses.txt')) {
  $licensePath = Join-Path $PostgreSqlRoot $license
  if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
    throw "Required PostgreSQL redistribution notice '$license' was not found under '$PostgreSqlRoot'."
  }
  Copy-Item -LiteralPath $licensePath -Destination $postgresqlRuntime -Force
}

Write-Host 'Building the production TypeScript backend in an isolated staging folder...'
foreach ($sourceName in @('package.json','package-lock.json','tsconfig.json')) {
  Copy-Item -LiteralPath (Join-Path $backendProject $sourceName) -Destination $backendBuild
}
Copy-Item -LiteralPath (Join-Path $backendProject 'src') -Destination $backendBuild -Recurse
Copy-Item -LiteralPath (Join-Path $backendProject 'migrations') -Destination $backendBuild -Recurse
Push-Location $backendBuild
try {
  npm ci
  if ($LASTEXITCODE -ne 0) { throw "Backend dependency installation failed with exit code $LASTEXITCODE." }
  npm run build
  if ($LASTEXITCODE -ne 0) { throw "Backend build failed with exit code $LASTEXITCODE." }
  npm test
  if ($LASTEXITCODE -ne 0) { throw "Backend tests failed with exit code $LASTEXITCODE." }
} finally {
  Pop-Location
}

$releaseDirectory = Join-Path $flutterProject 'build\windows\x64\runner\Release'
if (-not (Test-Path -LiteralPath (Join-Path $releaseDirectory 'malligai_kadai.exe'))) {
  throw 'Flutter release output does not contain malligai_kadai.exe.'
}
$releaseBackend = Join-Path $releaseDirectory 'backend'
$releaseBackendDist = Join-Path $releaseBackend 'dist'
if (Test-Path -LiteralPath $releaseBackendDist) {
  Remove-Item -LiteralPath $releaseBackendDist -Recurse -Force
}
$releaseBackendMigrations = Join-Path $releaseBackend 'migrations'
if (Test-Path -LiteralPath $releaseBackendMigrations) {
  Remove-Item -LiteralPath $releaseBackendMigrations -Recurse -Force
}
New-Item -ItemType Directory -Path $releaseBackend -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $backendBuild 'dist') -Destination $releaseBackend -Recurse -Force
Copy-Item -Path (Join-Path $releaseDirectory '*') -Destination $payloadRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'manage-postgresql.ps1') -Destination $databaseTools -Force
Write-Host ("Bundling app-local Microsoft Visual C++ runtime {0}..." -f $vcRuntime.Version)
Copy-Item -Path (Join-Path $vcRuntime.Path '*.dll') `
  -Destination $postgresqlCrtPayload -Force

Copy-Item -LiteralPath (Join-Path $backendBuild 'package.json') -Destination $runtimeBackend
Copy-Item -LiteralPath (Join-Path $backendBuild 'package-lock.json') -Destination $runtimeBackend
Push-Location $runtimeBackend
try {
  npm ci --omit=dev
  if ($LASTEXITCODE -ne 0) { throw "Production dependency install failed with exit code $LASTEXITCODE." }
} finally {
  Pop-Location
}
Copy-Item -LiteralPath (Join-Path $backendBuild 'dist') -Destination $backendPayload -Recurse -Force
Copy-Item -LiteralPath (Join-Path $backendBuild 'migrations') -Destination $backendPayload -Recurse -Force
Copy-Item -LiteralPath (Join-Path $runtimeBackend 'node_modules') -Destination $backendPayload -Recurse -Force
Copy-Item -LiteralPath (Join-Path $backendProject 'reset-password.cmd') -Destination $backendPayload
Copy-Item -LiteralPath $Node -Destination (Join-Path $backendPayload 'node.exe') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dependencies\node-LICENSE.txt') -Destination $backendPayload -Force

Write-Host 'Removing unused PostgreSQL GUI components to keep installation fast...'
Get-ChildItem -LiteralPath (Join-Path $postgresqlRuntime 'bin') -File |
  Where-Object { $_.Name -like 'wx*' -or $_.Name -eq 'stackbuilder.exe' } |
  Remove-Item -Force
Remove-Item -LiteralPath (Join-Path $postgresqlRuntime 'share\doc') -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ("Compiling {0}.exe..." -f $OutputBaseFilename)
$installer = Join-Path $artifactRoot "$OutputBaseFilename.exe"
$backupInstaller = Join-Path $artifactRoot "$OutputBaseFilename-Backup.exe"
if (
  (Test-Path -LiteralPath $installer -PathType Leaf) -and
  -not (Test-Path -LiteralPath $backupInstaller -PathType Leaf)
) {
  Copy-Item -LiteralPath $installer -Destination $backupInstaller
  Write-Host ("Preserved the previous installer as: {0}" -f $backupInstaller)
}
& $iscc "/DAppVersion=$appVersion" "/F$OutputBaseFilename" "/O$artifactRoot" $iss
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE." }

if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
  throw 'Inno Setup reported success but the installer file was not created.'
}
$file = Get-Item -LiteralPath $installer
Write-Host ("Installer created: {0} ({1:N0} bytes)" -f $file.FullName,$file.Length)
