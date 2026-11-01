import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

String _joinLocalPath(String first, String second) =>
    '$first${Platform.pathSeparator}$second';

String? postgresManagerFailureReason(
  Iterable<String> logLines, {
  int? managerProcessId,
}) {
  const marker = '] Failed: ';
  final lines = logLines.toList();
  var currentRunStart = 0;
  if (managerProcessId != null) {
    currentRunStart = -1;
    for (var index = lines.length - 1; index >= 0; index--) {
      final match = RegExp(r'manager_started manager_pid=(\d+)')
          .firstMatch(lines[index]);
      if (match != null && int.tryParse(match.group(1)!) == managerProcessId) {
        currentRunStart = index;
        break;
      }
    }
    if (currentRunStart < 0) return null;
  }
  for (final line in lines.skip(currentRunStart).toList().reversed) {
    final markerIndex = line.indexOf(marker);
    if (markerIndex >= 0) {
      final reason = line.substring(markerIndex + marker.length).trim();
      if (reason.isNotEmpty) return reason;
    }
  }
  return null;
}

String _applicationDirectory() => File(Platform.resolvedExecutable).parent.path;

String _perUserShopDirectory() {
  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    return _joinLocalPath(localAppData, 'Thanigai Stores');
  }
  final userProfile = Platform.environment['USERPROFILE'];
  if (userProfile == null || userProfile.isEmpty) {
    throw const BackendStartFailure(
      'The current Windows user profile could not be located.',
    );
  }
  return _joinLocalPath(userProfile, r'AppData\Local\Thanigai Stores');
}

String _postgresToolsDirectory() {
  final applicationRuntime = _joinLocalPath(
    _applicationDirectory(),
    r'postgresql\18\runtime\bin',
  );
  if (File(_joinLocalPath(applicationRuntime, 'pg_dump.exe')).existsSync()) {
    return applicationRuntime;
  }

  final programData = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
  final packagedRuntime = _joinLocalPath(
    programData,
    r'Thanigai Stores\PostgreSQL\18\runtime\bin',
  );
  if (File(_joinLocalPath(packagedRuntime, 'pg_dump.exe')).existsSync()) {
    return packagedRuntime;
  }

  final programFiles =
      Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
  return _joinLocalPath(programFiles, r'Thanigai Stores\PostgreSQL\18\bin');
}

typedef _GetExtendedTcpTableNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint32>,
  ffi.Int32,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Uint32,
);
typedef _GetExtendedTcpTableDart = int Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint32>,
  int,
  int,
  int,
  int,
);
typedef _OpenProcessNative = ffi.Pointer<ffi.Void> Function(
  ffi.Uint32,
  ffi.Int32,
  ffi.Uint32,
);
typedef _OpenProcessDart = ffi.Pointer<ffi.Void> Function(int, int, int);
typedef _QueryProcessImageNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Uint32,
  ffi.Pointer<Utf16>,
  ffi.Pointer<ffi.Uint32>,
);
typedef _QueryProcessImageDart = int Function(
  ffi.Pointer<ffi.Void>,
  int,
  ffi.Pointer<Utf16>,
  ffi.Pointer<ffi.Uint32>,
);
typedef _CloseNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _CloseDart = int Function(ffi.Pointer<ffi.Void>);

int? _windowsTcpListenerProcessId({
  required int addressFamily,
  required int rowSize,
  required int localPortOffset,
  required int processIdOffset,
  required int port,
}) {
  final ipHelper = ffi.DynamicLibrary.open('iphlpapi.dll');
  final getTcpTable = ipHelper
      .lookupFunction<_GetExtendedTcpTableNative, _GetExtendedTcpTableDart>(
        'GetExtendedTcpTable',
      );
  final size = calloc<ffi.Uint32>();
  try {
    final firstResult = getTcpTable(ffi.nullptr, size, 0, addressFamily, 3, 0);
    if ((firstResult != 122 && firstResult != 0) || size.value < 4) {
      return null;
    }
    final table = calloc<ffi.Uint8>(size.value);
    try {
      final result = getTcpTable(
        table.cast<ffi.Void>(),
        size,
        0,
        addressFamily,
        3,
        0,
      );
      if (result != 0) return null;

      final entries = table.cast<ffi.Uint32>().value;
      for (var index = 0; index < entries; index += 1) {
        final row = table + (4 + index * rowSize);
        final rawPort =
            (row + localPortOffset).cast<ffi.Uint32>().value & 0xffff;
        final localPort = ((rawPort & 0xff) << 8) | (rawPort >> 8);
        if (localPort == port) {
          return (row + processIdOffset).cast<ffi.Uint32>().value;
        }
      }
      return null;
    } finally {
      calloc.free(table);
    }
  } finally {
    calloc.free(size);
  }
}

({
  int processId,
  String processName,
  String? executablePath,
  int? parentProcessId,
})?
_windowsProcessIdentity(int processId) {
  final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
  final openProcess = kernel32
      .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
  final queryImage = kernel32
      .lookupFunction<_QueryProcessImageNative, _QueryProcessImageDart>(
        'QueryFullProcessImageNameW',
      );
  final closeHandle = kernel32.lookupFunction<_CloseNative, _CloseDart>(
    'CloseHandle',
  );
  final handle = openProcess(0x1000, 0, processId);
  if (handle == ffi.nullptr) {
    return (
      processId: processId,
      processName: 'unknown.exe',
      executablePath: null,
      parentProcessId: null,
    );
  }

  final buffer = calloc<ffi.Uint16>(32768);
  final length = calloc<ffi.Uint32>()..value = 32768;
  try {
    final succeeded = queryImage(handle, 0, buffer.cast<Utf16>(), length);
    if (succeeded == 0) {
      return (
        processId: processId,
        processName: 'unknown.exe',
        executablePath: null,
        parentProcessId: null,
      );
    }
    final path = buffer.cast<Utf16>().toDartString(length: length.value);
    return (
      processId: processId,
      processName: path.split(Platform.pathSeparator).last,
      executablePath: path,
      parentProcessId: null,
    );
  } finally {
    closeHandle(handle);
    calloc.free(length);
    calloc.free(buffer);
  }
}

class LocalBackendSettings {
  const LocalBackendSettings({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.jwtSecret,
    required this.initialSetupToken,
  });

  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final String jwtSecret;
  final String initialSetupToken;

  Map<String, String> processEnvironment({required int apiPort}) => {
    'API_PORT': '$apiPort',
    'NODE_ENV': 'production',
    'THANIGAI_SUPERVISED': '1',
    'DB_HOST': host,
    'DB_PORT': '$port',
    'DB_NAME': database,
    'DB_USER': username,
    'DB_PASSWORD': password,
    'JWT_SECRET': jwtSecret,
    'INITIAL_SETUP_TOKEN': initialSetupToken,
    'PG_DUMP_PATH': _joinLocalPath(_postgresToolsDirectory(), 'pg_dump.exe'),
    'PG_RESTORE_PATH': _joinLocalPath(
      _postgresToolsDirectory(),
      'pg_restore.exe',
    ),
  };

  Map<String, Object> toJson() => {
    'host': host,
    'port': port,
    'database': database,
    'username': username,
    'password': password,
    'jwtSecret': jwtSecret,
    'initialSetupToken': initialSetupToken,
  };

  factory LocalBackendSettings.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['host'] is! String ||
        value['port'] is! num ||
        value['database'] is! String ||
        value['username'] is! String ||
        value['password'] is! String ||
        value['jwtSecret'] is! String ||
        value['initialSetupToken'] is! String) {
      throw const BackendStartFailure(
        'Saved local database settings are invalid. Repair the Thanigai Stores installation.',
      );
    }
    if (value['host'] != '127.0.0.1' ||
        value['database'] != 'thanigai_stores' ||
        value['username'] != 'thanigai_app' ||
        (value['port'] as num) != (value['port'] as num).toInt() ||
        (value['port'] as num) < 55432 ||
        (value['port'] as num) > 55462) {
      throw const BackendStartFailure(
        'Saved database settings do not identify the bundled Thanigai Stores database. Repair the installation.',
      );
    }
    return LocalBackendSettings(
      host: value['host'] as String,
      port: (value['port'] as num).toInt(),
      database: value['database'] as String,
      username: value['username'] as String,
      password: value['password'] as String,
      jwtSecret: value['jwtSecret'] as String,
      initialSetupToken: value['initialSetupToken'] as String,
    );
  }
}

class BackendStartFailure implements Exception {
  const BackendStartFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

String databaseStartupFailureMessage(String? category) => switch (category) {
  'authentication' => 'The local PostgreSQL process rejected Thanigai Stores database credentials. Repair the installation; existing shop data is not reset.',
  'database_missing' => 'The local Thanigai Stores database is missing. Repair the installation; existing data is not reset.',
  'insufficient_privileges' => 'The local app database role lacks required permissions. Repair the installation instead of using a PostgreSQL superuser.',
  'server_unavailable' => 'Could not reach the per-user PostgreSQL process. Restart Thanigai Stores and retry.',
  'migration' => 'PostgreSQL connected, but safe database initialization failed. Existing shop data was not reset; contact support before changing the database.',
  'port_in_use' => 'The selected local API port is already in use. Select Retry to try again; Thanigai Stores will not stop unrelated processes.',
  _ => 'The local API stopped before becoming ready. Confirm PostgreSQL is running and verify the connection details.',
};

bool isHealthyLocalApiResponse(int statusCode, Object? decodedBody) =>
    statusCode == 200 &&
    decodedBody is Map<String, dynamic> &&
    decodedBody['status'] == 'ok' &&
    decodedBody['service'] == 'thanigai-stores-api' &&
    decodedBody['database'] == 'ok';

bool isBundledThanigaiBackendOwner({
  required String processName,
  required String? executablePath,
  required String? commandLine,
  required String expectedNodeExecutable,
  required String expectedServerScript,
}) {
  String normalizePath(String value) =>
      value.replaceAll('/', r'\').toLowerCase();

  return processName.toLowerCase() == 'node.exe' &&
      executablePath != null &&
      commandLine != null &&
      normalizePath(executablePath) == normalizePath(expectedNodeExecutable) &&
      normalizePath(commandLine).contains(normalizePath(expectedServerScript));
}

String apiPortConflictMessage({
  int port = 3000,
  required int processId,
  required String processName,
  String? executablePath,
  int? parentProcessId,
}) {
  final path = executablePath == null || executablePath.isEmpty
      ? ''
      : ' ($executablePath)';
  final parent = parentProcessId == null ? '' : ', parent PID $parentProcessId';
  return 'Port $port is already in use by $processName (PID $processId$parent)$path. No process was stopped.';
}

Future<int> selectAvailableApiPort({int preferredPort = 3000}) async {
  ServerSocket? socket;
  try {
    socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      preferredPort,
    );
    return preferredPort;
  } on SocketException {
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      return socket.port;
    } on SocketException catch (error) {
      throw BackendStartFailure(
        'Could not find an available local API port: ${error.message}',
      );
    }
  } finally {
    await socket?.close();
  }
}

class LocalBackendSupervisor {
  LocalBackendSupervisor({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _settingsKey = 'thanigai_stores_per_user_backend_settings_v1';
  static const _defaultApiPort = 3000;

  final FlutterSecureStorage _secureStorage;
  int _apiPort = _defaultApiPort;
  Process? _process;
  String? _startupFailureCategory;
  String? _startupLogPath;
  LocalBackendSettings? _startupLogSettings;
  Future<void> _startupLogWrites = Future<void>.value();
  Future<LocalBackendSettings>? _starting;
  Future<void>? _stopping;
  Future<void>? _preparingDatabase;
  Process? _managerProcess;
  int? _managerExitCode;
  Stopwatch? _startupClock;
  bool _shutdownRequested = false;
  LocalBackendSettings? _managerSettings;
  LocalBackendSettings? _activeSettings;

  String get apiBaseUrl => 'http://127.0.0.1:$_apiPort';

  Future<void> prepareDatabase() {
    final preparing = _preparingDatabase;
    if (preparing != null) return preparing;
    final future = _prepareDatabase();
    _preparingDatabase = future;
    return future.whenComplete(() {
      if (identical(_preparingDatabase, future)) {
        _preparingDatabase = null;
      }
    });
  }

  Future<void> _prepareDatabase() async {
    if (!Platform.isWindows) {
      throw const BackendStartFailure(
        'The bundled PostgreSQL runtime is supported on Windows only.',
      );
    }

    final applicationDirectory = _applicationDirectory();
    final scriptPath = _joinLocalPath(
      applicationDirectory,
      r'database-tools\manage-postgresql.ps1',
    );
    final runtimeDirectory = _joinLocalPath(
      applicationDirectory,
      r'postgresql\18\runtime',
    );
    final shopDirectory = _perUserShopDirectory();
    final dataDirectory = _joinLocalPath(shopDirectory, r'PostgreSQL\18\data');
    final logPath = _joinLocalPath(shopDirectory, 'database-setup.log');
    _startupLogPath = _joinLocalPath(shopDirectory, 'backend-startup.log');
    _startupLogSettings = null;
    _startupClock ??= Stopwatch()..start();
    await _recordStartupDiagnostic('PostgreSQL manager startup requested.');

    if (!File(scriptPath).existsSync() ||
        !File(_joinLocalPath(runtimeDirectory, r'bin\initdb.exe'))
            .existsSync()) {
      throw const BackendStartFailure(
        'The per-user PostgreSQL runtime is missing. Reinstall Thanigai Stores.',
      );
    }

    try {
      await _recordStartupDiagnostic(
        'Running the per-user PostgreSQL manager.',
      );
      final exitCode = await _runPostgresManager(
        mode: 'Start',
        scriptPath: scriptPath,
        runtimeDirectory: runtimeDirectory,
        stateDirectory: shopDirectory,
        dataDirectory: dataDirectory,
        logPath: logPath,
        timeout: const Duration(minutes: 5),
      );
      if (exitCode != 0) {
        await _recordStartupDiagnostic(
          'PostgreSQL manager exited with code $exitCode.',
        );
        throw BackendStartFailure(
          'Local PostgreSQL setup failed. Review $logPath; existing data was not reset.',
        );
      }
    } on ProcessException {
      await _recordStartupDiagnostic(
        'Could not launch the PostgreSQL manager.',
      );
      throw BackendStartFailure(
        'Windows could not start local PostgreSQL setup. Review $logPath.',
      );
    } on TimeoutException {
      await _recordStartupDiagnostic(
        'PostgreSQL manager timed out and its owned PowerShell process was stopped.',
      );
      throw BackendStartFailure(
        'Local PostgreSQL setup did not finish within 5 minutes. Check $logPath before retrying; existing data was not reset.',
      );
    }
    await _recordStartupDiagnostic(
      'PostgreSQL manager completed successfully.',
    );
    final settings = await _readPerUserBootstrapSettings();
    if (settings == null) {
      throw BackendStartFailure(
        'PostgreSQL setup completed without protected database settings. Review $logPath.',
      );
    }
    try {
      await _secureStorage.write(
        key: _settingsKey,
        value: jsonEncode(settings.toJson()),
      );
    } catch (_) {
      throw const BackendStartFailure(
        'Windows could not securely save the recovered Thanigai Stores database settings.',
      );
    }
    _managerSettings = settings;
    _startupLogSettings = settings;
  }

  Future<LocalBackendSettings?> readSettings() async {
    _startupLogPath ??= _joinLocalPath(
      _perUserShopDirectory(),
      'backend-startup.log',
    );
    _startupClock ??= Stopwatch()..start();
    final readStarted = Stopwatch()..start();
    final raw = await _secureStorage.read(key: _settingsKey);
    if (raw != null) {
      try {
        final settings = LocalBackendSettings.fromJson(jsonDecode(raw));
        await _recordStartupDiagnostic(
          'Secure database settings loaded in ${readStarted.elapsedMilliseconds} ms.',
        );
        return settings;
      } on FormatException catch (error) {
        await _recordStartupDiagnostic(
          'Secure database settings are unreadable and will be recovered from the PostgreSQL manager: ${error.message}.',
        );
      } on BackendStartFailure catch (error) {
        await _recordStartupDiagnostic(
          'Secure database settings failed validation and will be recovered from the PostgreSQL manager: ${error.message}.',
        );
      }
    }

    LocalBackendSettings? bootstrapSettings;
    try {
      bootstrapSettings = await _readPerUserBootstrapSettings();
    } on BackendStartFailure catch (error) {
      await _recordStartupDiagnostic(
        'Protected PostgreSQL bootstrap settings could not be loaded; the manager will check recovery options: ${error.message}.',
      );
    }
    if (bootstrapSettings == null) {
      await _recordStartupDiagnostic(
        'No saved or protected bootstrap database settings were found (${readStarted.elapsedMilliseconds} ms).',
      );
      return null;
    }
    try {
      await _secureStorage.write(
        key: _settingsKey,
        value: jsonEncode(bootstrapSettings.toJson()),
      );
    } catch (_) {
      throw const BackendStartFailure(
        'Windows could not save the automatically configured database settings securely.',
      );
    }
    await _recordStartupDiagnostic(
      'Protected database settings imported in ${readStarted.elapsedMilliseconds} ms.',
    );
    return bootstrapSettings;
  }

  Future<LocalBackendSettings> loadOrInitializeSettings() async {
    var settings = await readSettings();
    if (settings == null) {
      await prepareDatabase();
      settings = await readSettings();
    }
    if (settings == null) {
      throw BackendStartFailure(
        'Local PostgreSQL setup finished without protected database settings. Review ${_joinLocalPath(_perUserShopDirectory(), 'database-setup.log')} before retrying.',
      );
    }
    return settings;
  }

  Future<LocalBackendSettings?> _readPerUserBootstrapSettings() async {
    if (!Platform.isWindows) return null;
    final bootstrapPath = _joinLocalPath(
      _perUserShopDirectory(),
      'database-bootstrap.bin',
    );
    if (!File(bootstrapPath).existsSync()) return null;

    const decryptScript = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$encrypted = [IO.File]::ReadAllBytes($env:THANIGAI_BOOTSTRAP_FILE)
$entropy = [Text.Encoding]::UTF8.GetBytes('ThanigaiStores|PerUserDatabase|v1')
$plain = [Security.Cryptography.ProtectedData]::Unprotect(
  $encrypted,
  $entropy,
  [Security.Cryptography.DataProtectionScope]::CurrentUser
)
[Console]::Out.Write([Text.Encoding]::UTF8.GetString($plain))
''';

    late final Process process;
    try {
      process = await Process.start(
        'powershell.exe',
        ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', decryptScript],
        environment: {
          ...Platform.environment,
          'THANIGAI_BOOTSTRAP_FILE': bootstrapPath,
        },
        runInShell: false,
      );
    } on ProcessException {
      throw const BackendStartFailure(
        'Windows could not load the protected local database settings. Repair the Thanigai Stores installation.',
      );
    }
    final outputFuture = process.stdout.transform(utf8.decoder).join();
    process.stderr.listen((_) {});
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (exitCode == -1) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        await _recordStartupDiagnostic(
          'Protected settings PowerShell child PID ${process.pid} did not exit after timeout termination.',
        );
      }
      throw const BackendStartFailure(
        'Windows could not load the protected local database settings within 10 seconds. Repair the Thanigai Stores installation.',
      );
    }
    if (exitCode != 0) {
      throw const BackendStartFailure(
        'The protected local database settings could not be read. Repair the Thanigai Stores installation.',
      );
    }
    try {
      return LocalBackendSettings.fromJson(jsonDecode(await outputFuture));
    } on FormatException {
      throw const BackendStartFailure(
        'The protected local database settings are invalid. Repair the Thanigai Stores installation.',
      );
    }
  }

  Future<void> saveSettings({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
  }) async {
    await stop();
    final settings = LocalBackendSettings(
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
      jwtSecret: _randomSecret(),
      initialSetupToken: _randomSecret(),
    );
    try {
      await _secureStorage.write(
        key: _settingsKey,
        value: jsonEncode(settings.toJson()),
      );
    } catch (_) {
      throw const BackendStartFailure(
        'Windows could not save the PostgreSQL settings securely. Check your Windows account and try again.',
      );
    }
  }

  Future<LocalBackendSettings> startAndWait({LocalBackendSettings? settings}) {
    if (_shutdownRequested) {
      return Future<LocalBackendSettings>.error(
        const BackendStartFailure('Thanigai Stores is closing.'),
      );
    }
    final starting = _starting;
    if (starting != null) return starting;
    final future = _startAndWait(settings: settings);
    _starting = future;
    return future.whenComplete(() {
      if (identical(_starting, future)) _starting = null;
    });
  }

  Future<LocalBackendSettings> _startAndWait({
    LocalBackendSettings? settings,
  }) async {
    if (_shutdownRequested) {
      throw const BackendStartFailure('Thanigai Stores is closing.');
    }
    _startupClock = Stopwatch()..start();
    _startupLogPath ??= _joinLocalPath(
      _perUserShopDirectory(),
      'backend-startup.log',
    );
    final currentProcess = _process;
    if (currentProcess != null) {
      if (await _isApiHealthy()) {
        await _recordStartupDiagnostic(
          'Existing app-owned API passed the health check.',
        );
        final activeSettings =
            _activeSettings ?? settings ?? await readSettings();
        if (activeSettings == null) {
          throw const BackendStartFailure(
            'Local database settings are unavailable. Restart Thanigai Stores.',
          );
        }
        return activeSettings;
      }
      await _stopBackendProcess(currentProcess);
    }
    _apiPort = _defaultApiPort;
    settings ??= await readSettings();
    if (settings == null) {
      throw const BackendStartFailure(
        'Automatic local database settings are unavailable. Repair the Thanigai Stores installation.',
      );
    }
    _startupLogSettings = settings;

    final appDirectory = _applicationDirectory();
    final backendDirectory = _join(appDirectory, 'backend');
    final nodeExecutable = _join(backendDirectory, 'node.exe');
    final serverScript = _join(backendDirectory, 'dist', 'server.js');
    if (!File(nodeExecutable).existsSync() ||
        !File(serverScript).existsSync()) {
      throw const BackendStartFailure(
        'The bundled local API runtime is missing. Repair or reinstall Thanigai Stores.',
      );
    }

    final existingApiProbe = Stopwatch()..start();
    final existingApiProcessId = await _findHealthyThanigaiBackend(settings);
    await _recordStartupDiagnostic(
      'Existing API identity/health probe completed in ${existingApiProbe.elapsedMilliseconds} ms (verified=${existingApiProcessId != null}).',
    );
    if (_shutdownRequested) {
      throw const BackendStartFailure('Thanigai Stores is closing.');
    }
    if (existingApiProcessId != null) {
      _startupLogSettings = settings;
      await _recordStartupDiagnostic(
        'Reusing the healthy Thanigai Stores API (PID $existingApiProcessId).',
      );
      _activeSettings = settings;
      return settings;
    }
    if (_shutdownRequested) {
      throw const BackendStartFailure('Thanigai Stores is closing.');
    }
    await _recordStartupDiagnostic('Starting PostgreSQL manager stage.');
    await prepareDatabase();
    settings = _managerSettings ?? settings;
    if (_shutdownRequested) {
      throw const BackendStartFailure('Thanigai Stores is closing.');
    }
    _apiPort = await selectAvailableApiPort(preferredPort: _defaultApiPort);
    await _recordStartupDiagnostic(
      _apiPort == _defaultApiPort
          ? 'Local API will use preferred port $_apiPort.'
          : 'Port $_defaultApiPort is occupied; local API will use available port $_apiPort.',
    );
    _startupFailureCategory = null;
    _startupLogSettings = settings;
    await _recordStartupDiagnostic('Starting the bundled local API.');
    final processLaunch = Stopwatch()..start();
    try {
      _process = await Process.start(
        nodeExecutable,
        [serverScript],
        workingDirectory: backendDirectory,
        environment: {
          ...Platform.environment,
          ...settings.processEnvironment(apiPort: _apiPort),
        },
        runInShell: false,
      );
    } on ProcessException {
      await _recordStartupDiagnostic(
        'Windows could not launch the bundled API.',
      );
      throw const BackendStartFailure(
        'Windows could not start the bundled local API. Repair or reinstall Thanigai Stores.',
      );
    }
    final process = _process!;
    await _recordStartupDiagnostic(
      'Bundled API child started: pid=${process.pid}, ppid=$pid, process_start_ms=${processLaunch.elapsedMilliseconds}.',
    );
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _recordBackendOutput('stdout', line));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _recordBackendOutput('stderr', line));
    unawaited(
      process.exitCode.then((exitCode) async {
        await _recordStartupDiagnostic(
          'Bundled API child exited: pid=${process.pid}, exit_code=$exitCode.',
        );
        if (identical(_process, process)) _process = null;
        await _flushStartupLog();
      }),
    );
    if (_shutdownRequested) {
      await _stopBackendProcess(process);
      throw const BackendStartFailure('Thanigai Stores is closing.');
    }

    final client = http.Client();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline)) {
        if (!identical(_process, process)) {
          final startupFailureCategory = _startupFailureCategory;
          await _stopBackendProcess(process);
          if (startupFailureCategory == 'port_in_use') {
            throw BackendStartFailure(await _apiPortConflictDetails());
          }
          throw BackendStartFailure(_startupFailureMessage());
        }
        try {
          final response = await client
              .get(Uri.parse('http://127.0.0.1:$_apiPort/health'))
              .timeout(const Duration(seconds: 2));
          final body = jsonDecode(response.body);
          if (isHealthyLocalApiResponse(response.statusCode, body)) {
            await _recordStartupDiagnostic(
              'API health check passed after ${_startupClock?.elapsedMilliseconds ?? 0} ms.',
            );
            await _flushStartupLog();
            _activeSettings = settings;
            return settings;
          }
        } on SocketException {
          // The server has not started listening yet.
        } on TimeoutException {
          // Database migration and first startup can take several seconds.
        } on http.ClientException {
          // Retry while the local server is starting.
        } on FormatException {
          // A listener that is not the Thanigai Stores API is not ready.
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    } finally {
      client.close();
    }

    final startupFailureCategory = _startupFailureCategory;
    await _flushStartupLog();
    await _stopBackendProcess(process);
    if (startupFailureCategory == 'port_in_use') {
      throw BackendStartFailure(await _apiPortConflictDetails());
    }
    final startupLogPath = _startupLogPath;
    throw BackendStartFailure(
      startupLogPath == null
          ? 'The local API did not become ready with a healthy PostgreSQL connection. Review the PostgreSQL setup log, then restart Thanigai Stores.'
          : 'The local API did not become ready with a healthy PostgreSQL connection. Review $startupLogPath and the PostgreSQL setup log, then restart Thanigai Stores.',
    );
  }

  void _captureStartupFailure(String line) {
    const databasePrefix = 'THANIGAI_DB_STARTUP_FAILURE=';
    const apiPrefix = 'THANIGAI_API_STARTUP_FAILURE=';
    final prefix = line.startsWith(databasePrefix)
        ? databasePrefix
        : line.startsWith(apiPrefix)
        ? apiPrefix
        : null;
    if (prefix == null) return;
    final category = line.substring(prefix.length);
    if (const {
      'authentication',
      'database_missing',
      'insufficient_privileges',
      'server_unavailable',
      'migration',
      'port_in_use',
    }.contains(category)) {
      _startupFailureCategory = category;
    }
  }

  void _recordBackendOutput(String stream, String line) {
    _captureStartupFailure(line);
    final path = _startupLogPath;
    if (path == null) return;
    var safeLine = line;
    final settings = _startupLogSettings;
    if (settings != null) {
      for (final secret in [
        settings.password,
        settings.jwtSecret,
        settings.initialSetupToken,
      ]) {
        if (secret.isNotEmpty) {
          safeLine = safeLine.replaceAll(secret, '[REDACTED]');
        }
      }
    }
    _startupLogWrites = _startupLogWrites.then((_) async {
      try {
        await File(path).parent.create(recursive: true);
        final timestamp = DateTime.now().toIso8601String();
        await File(path).writeAsString(
          '[$timestamp] [$stream] $safeLine\n',
          mode: FileMode.append,
        );
      } on FileSystemException catch (error) {
        debugPrint('Could not append to the local API startup log: $error');
      }
    });
  }

  Future<void> _flushStartupLog() => _startupLogWrites;

  Future<void> _recordStartupDiagnostic(String message) async {
    final path = _startupLogPath;
    if (path == null) return;
    final timestamp = DateTime.now().toIso8601String();
    final elapsed = _startupClock?.elapsedMilliseconds;
    _startupLogWrites = _startupLogWrites.then((_) async {
      try {
        await File(path).parent.create(recursive: true);
        await File(path).writeAsString(
          '[$timestamp]${elapsed == null ? '' : ' +$elapsed ms'} $message\n',
          mode: FileMode.append,
          flush: true,
        );
      } on FileSystemException catch (error) {
        debugPrint('Could not append to the local API startup log: $error');
      }
    });
    await _startupLogWrites;
  }

  String _startupFailureMessage() {
    final message = databaseStartupFailureMessage(_startupFailureCategory);
    final logPath = _startupLogPath;
    if (logPath == null || _startupFailureCategory == 'port_in_use') {
      return message;
    }
    return '$message Review local API startup diagnostics at $logPath.';
  }

  Future<void> stop({bool stopDatabase = true}) {
    final stopping = _stopping;
    if (stopping != null) return stopping;
    final future = _stop(stopDatabase: stopDatabase);
    _stopping = future;
    return future.whenComplete(() {
      if (identical(_stopping, future)) _stopping = null;
    });
  }

  Future<void> _stop({required bool stopDatabase}) async {
    if (!stopDatabase) _shutdownRequested = true;
    if (!stopDatabase) {
      final manager = _managerProcess;
      if (manager != null) {
        await _terminateManagerProcess(manager, 'app shutdown');
      }
    }
    final preparing = _preparingDatabase;
    if (preparing != null) {
      try {
        await preparing;
      } on BackendStartFailure catch (error) {
        debugPrint('Database setup ended before shutdown: $error');
      } on TimeoutException catch (error) {
        debugPrint('Database setup was cancelled during shutdown: $error');
      }
    }
    final process = _process;
    if (process != null) {
      await _stopBackendProcess(process);
    }

    if (!stopDatabase) return;
    if (!Platform.isWindows) return;
    final shopDirectory = _perUserShopDirectory();
    final scriptPath = _joinLocalPath(
      _applicationDirectory(),
      r'database-tools\manage-postgresql.ps1',
    );
    if (!File(scriptPath).existsSync()) return;
    final logPath = _joinLocalPath(shopDirectory, 'database-setup.log');
    final shutdownStarted = Stopwatch()..start();
    final exitCode = await _runPostgresManager(
      mode: 'Stop',
      scriptPath: scriptPath,
      runtimeDirectory: _joinLocalPath(
        _applicationDirectory(),
        r'postgresql\18\runtime',
      ),
      stateDirectory: shopDirectory,
      dataDirectory: _joinLocalPath(shopDirectory, r'PostgreSQL\18\data'),
      logPath: logPath,
      timeout: const Duration(seconds: 45),
    );
    await _recordStartupDiagnostic(
      'PostgreSQL shutdown completed in ${shutdownStarted.elapsedMilliseconds} ms with exit_code=$exitCode.',
    );
    if (exitCode != 0) {
      throw BackendStartFailure(
        'The local database did not stop cleanly (exit code $exitCode). Review $logPath.',
      );
    }
  }

  Future<void> _stopBackendProcess(Process process) async {
    final shutdownStarted = Stopwatch()..start();
    try {
      process.stdin.writeln('shutdown');
      await process.stdin.flush();
      await process.stdin.close();
    } on IOException {
      // The backend may have exited while shutdown was being requested.
    }
    try {
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 6),
      );
      await _recordStartupDiagnostic(
        'Owned backend shutdown completed in ${shutdownStarted.elapsedMilliseconds} ms with exit_code=$exitCode.',
      );
    } on TimeoutException {
      await _recordStartupDiagnostic(
        'Owned backend did not shut down gracefully in 6 seconds; terminating only child PID ${process.pid}.',
      );
      process.kill(ProcessSignal.sigkill);
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 2),
      );
      await _recordStartupDiagnostic(
        'Owned backend terminated in ${shutdownStarted.elapsedMilliseconds} ms with exit_code=$exitCode.',
      );
    } finally {
      if (identical(_process, process)) _process = null;
    }
  }

  Future<void> _terminateManagerProcess(Process process, String reason) async {
    if (!identical(_managerProcess, process)) {
      final exitCode = _managerExitCode;
      if (exitCode != null) {
        await _recordStartupDiagnostic(
          'Owned PostgreSQL manager already exited with code $exitCode.',
        );
      }
      return;
    }
    await _recordStartupDiagnostic(
      'Stopping owned PostgreSQL manager PID ${process.pid}: $reason.',
    );
    process.kill(ProcessSignal.sigkill);
    try {
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 2),
      );
      await _recordStartupDiagnostic(
        'Owned PostgreSQL manager exited with code $exitCode.',
      );
    } on TimeoutException {
      await _recordStartupDiagnostic(
        'Owned PostgreSQL manager PID ${process.pid} did not exit after termination was requested.',
      );
    } finally {
      if (identical(_managerProcess, process)) _managerProcess = null;
    }
  }

  Future<int> _runPostgresManager({
    required String mode,
    required String scriptPath,
    required String runtimeDirectory,
    required String stateDirectory,
    required String dataDirectory,
    required String logPath,
    required Duration timeout,
  }) async {
    final resultPath = _joinLocalPath(
      stateDirectory,
      'database-manager-${mode.toLowerCase()}-${_randomSecret()}.result',
    );
    final managerProcess = await Process.start('powershell.exe', [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      '-Mode',
      mode,
      '-RuntimeDirectory',
      runtimeDirectory,
      '-StateDirectory',
      stateDirectory,
      '-DataDirectory',
      dataDirectory,
      '-LogPath',
      logPath,
      '-ResultPath',
      resultPath,
    ], runInShell: false);
    _managerProcess = managerProcess;
    _managerExitCode = null;
    final stdoutLines = <String>[];
    final stderrLines = <String>[];
    managerProcess.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stdoutLines.add);
    managerProcess.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add);
    int? managerExitCode;
    unawaited(
      managerProcess.exitCode.then((exitCode) {
        managerExitCode = exitCode;
        _managerExitCode = exitCode;
        if (identical(_managerProcess, managerProcess)) {
          _managerProcess = null;
        }
      }),
    );

    try {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final resultFile = File(resultPath);
        if (resultFile.existsSync()) {
          final result = resultFile.readAsStringSync().trim();
          resultFile.deleteSync();
          final exitCode = int.tryParse(result);
          if (exitCode == null) {
            throw BackendStartFailure(
              'The PostgreSQL manager returned an invalid result. Review $logPath.',
            );
          }
          final processExitCode = await managerProcess.exitCode.timeout(
            const Duration(seconds: 3),
            onTimeout: () => -1,
          );
          if (identical(_managerProcess, managerProcess)) {
            _managerProcess = null;
          }
          if (processExitCode == -1) {
            await _terminateManagerProcess(
              managerProcess,
              'result file was written but the process did not exit',
            );
            throw BackendStartFailure(
              'The PostgreSQL manager did not exit after reporting completion. Review $logPath.',
            );
          }
          if (exitCode != 0) {
            throw await _postgresManagerFailure(
              exitCode,
              logPath,
              managerProcessId: managerProcess.pid,
              processDiagnostics: [...stdoutLines, ...stderrLines],
            );
          }
          if (processExitCode != 0) {
            throw BackendStartFailure(
              'The PostgreSQL manager exited with code $processExitCode. Review $logPath.',
            );
          }
          return exitCode;
        }
        final completedManagerExitCode = managerExitCode;
        if (completedManagerExitCode != null) {
          throw await _postgresManagerFailure(
            completedManagerExitCode,
            logPath,
            withoutResult: true,
            managerProcessId: managerProcess.pid,
            processDiagnostics: [...stdoutLines, ...stderrLines],
          );
        }
        if (_shutdownRequested) {
          throw const BackendStartFailure('Thanigai Stores is closing.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      await _terminateManagerProcess(managerProcess, 'startup timeout');
      throw TimeoutException(
        'The PostgreSQL manager did not finish in time. Review $logPath before retrying.',
      );
    } catch (_) {
      if (identical(_managerProcess, managerProcess)) {
        await _terminateManagerProcess(
          managerProcess,
          'manager operation failed',
        );
      }
      rethrow;
    } finally {
      if (identical(_managerProcess, managerProcess) &&
          managerExitCode != null) {
        _managerProcess = null;
      }
    }
  }

  Future<BackendStartFailure> _postgresManagerFailure(
    int exitCode,
    String logPath, {
    bool withoutResult = false,
    int? managerProcessId,
    List<String> processDiagnostics = const [],
  }) async {
    final logFile = File(logPath);
    if (!await logFile.exists()) {
      await _recordStartupDiagnostic(
        'PostgreSQL setup failed, but its diagnostic log was not found.',
      );
      return _managerFailureWithDiagnostics(
        exitCode,
        logPath,
        processDiagnostics,
      );
    }
    try {
      final reason = postgresManagerFailureReason(
        await logFile.readAsLines(),
        managerProcessId: managerProcessId,
      );
      if (reason != null) {
        return BackendStartFailure(
          'Local PostgreSQL setup failed: $reason Review $logPath; existing shop data was not reset.',
        );
      }
      await _recordStartupDiagnostic(
        'PostgreSQL setup failed without a failure reason in its setup log.',
      );
    } on FileSystemException catch (error) {
      await _recordStartupDiagnostic(
        'Could not read PostgreSQL setup failure details: ${error.message}.',
      );
    }
    final resultDescription = withoutResult ? ' without a result' : '';
    return _managerFailureWithDiagnostics(
      exitCode,
      logPath,
      processDiagnostics,
      resultDescription: resultDescription,
    );
  }

  BackendStartFailure _managerFailureWithDiagnostics(
    int exitCode,
    String logPath,
    List<String> processDiagnostics, {
    String resultDescription = '',
  }) {
    final diagnostics = processDiagnostics
        .map(_redactDiagnostic)
        .where((line) => line.trim().isNotEmpty)
        .take(5)
        .join(' ');
    final detail = diagnostics.isEmpty ? '' : ' Details: $diagnostics';
    return BackendStartFailure(
      'The PostgreSQL manager exited with code $exitCode$resultDescription.$detail Review $logPath.',
    );
  }

  String _redactDiagnostic(String value) {
    var safe = value;
    final settings = _startupLogSettings;
    if (settings != null) {
      for (final secret in [
        settings.password,
        settings.jwtSecret,
        settings.initialSetupToken,
      ]) {
        if (secret.isNotEmpty) safe = safe.replaceAll(secret, '[REDACTED]');
      }
    }
    return safe.replaceAll(
      RegExp(r'\b[0-9a-f]{96}\b', caseSensitive: false),
      '[REDACTED]',
    );
  }

  Future<int?> _findHealthyThanigaiBackend(
    LocalBackendSettings settings,
  ) async {
    final healthStarted = Stopwatch()..start();
    if (!await _isApiHealthy()) {
      await _recordStartupDiagnostic(
        'Existing API health probe failed in ${healthStarted.elapsedMilliseconds} ms.',
      );
      return null;
    }
    final identityProcessId = await _bundledBackendIdentity(settings);
    if (identityProcessId == null) {
      await _recordStartupDiagnostic(
        'Existing API did not prove its protected Thanigai Stores identity.',
      );
      return null;
    }
    final owner = await _apiPortOwner(port: _defaultApiPort);
    if (owner?.processId != identityProcessId ||
        owner?.processName.toLowerCase() != 'node.exe') {
      await _recordStartupDiagnostic(
        'Existing API identity PID did not match the observed port owner; it will not be reused.',
      );
      return null;
    }
    await _recordStartupDiagnostic(
      'Verified healthy backend identity: PID ${owner!.processId}, parent PID ${owner.parentProcessId}, executable ${owner.executablePath ?? 'unavailable'}.',
    );
    return owner.processId;
  }

  Future<int?> _bundledBackendIdentity(LocalBackendSettings settings) async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse('http://127.0.0.1:$_apiPort/internal/identity'),
            headers: {'X-Local-Shutdown-Token': settings.initialSetupToken},
          )
          .timeout(const Duration(seconds: 2));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic> ||
          body['service'] != 'thanigai-stores-api' ||
          body['processId'] is! int) {
        return null;
      }
      return body['processId'] as int;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    } on FormatException {
      return null;
    } finally {
      client.close();
    }
  }

  Future<bool> _isApiHealthy() async {
    final client = http.Client();
    try {
      final response = await client
          .get(Uri.parse('http://127.0.0.1:$_apiPort/health'))
          .timeout(const Duration(seconds: 2));
      return isHealthyLocalApiResponse(
        response.statusCode,
        jsonDecode(response.body),
      );
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    } on FormatException {
      return false;
    } finally {
      client.close();
    }
  }

  Future<
    ({
      int processId,
      String processName,
      String? executablePath,
      int? parentProcessId,
    })?
  >
  _apiPortOwner({required int port}) async {
    if (!Platform.isWindows) return null;
    try {
      final processId =
          _windowsTcpListenerProcessId(
            addressFamily: 2,
            rowSize: 24,
            localPortOffset: 8,
            processIdOffset: 20,
            port: port,
          ) ??
          _windowsTcpListenerProcessId(
            addressFamily: 23,
            rowSize: 56,
            localPortOffset: 20,
            processIdOffset: 52,
            port: port,
          );
      if (processId == null) return null;
      return _windowsProcessIdentity(processId);
    } on ArgumentError catch (error) {
      await _recordStartupDiagnostic(
        'Windows could not inspect the port owner: ${error.message}.',
      );
      return null;
    }
  }

  Future<String> _apiPortConflictDetails() async {
    final owner = await _apiPortOwner(port: _apiPort);
    if (owner == null) {
      await _recordStartupDiagnostic(
        'Port $_apiPort conflict detected; Windows could not identify its owner.',
      );
      return 'Port $_apiPort is already in use, but Windows could not identify its owner. Thanigai Stores will not stop unrelated processes.';
    }
    await _recordStartupDiagnostic(
      'Port $_apiPort owner: pid=${owner.processId}, name=${owner.processName}, parent_pid=${owner.parentProcessId ?? 'unavailable'}, executable=${owner.executablePath ?? 'unavailable'}. No process was stopped.',
    );
    return apiPortConflictMessage(
      port: _apiPort,
      processId: owner.processId,
      processName: owner.processName,
      executablePath: owner.executablePath,
      parentProcessId: owner.parentProcessId,
    );
  }

  static String _randomSecret() {
    final random = Random.secure();
    return List<int>.generate(
      48,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _join(String first, String second, [String? third]) {
    final parts = [first, second, ?third];
    return parts.join(Platform.pathSeparator);
  }
}

class InitialAdminSetupApi {
  InitialAdminSetupApi({
    required this.setupToken,
    this.baseUrl = 'http://127.0.0.1:3000',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String setupToken;
  final String baseUrl;

  Future<bool> setupRequired() async {
    late final http.Response response;
    try {
      response = await _send(_client.get(Uri.parse('$baseUrl/setup/status')));
    } finally {
      _client.close();
    }
    final body = _decode(response);
    if (response.statusCode != 200 || body['setupRequired'] is! bool) {
      throw BackendStartFailure(
        body['message'] as String? ??
            'Could not check whether the initial Admin account is configured.',
      );
    }
    return body['setupRequired'] as bool;
  }

  Future<void> createInitialAdmin(String username, String password) async {
    late final http.Response response;
    try {
      response = await _send(
        _client.post(
          Uri.parse('$baseUrl/setup/admin'),
          headers: {
            'Content-Type': 'application/json',
            'X-Initial-Setup-Token': setupToken,
          },
          body: jsonEncode({'username': username.trim(), 'password': password}),
        ),
      );
    } finally {
      _client.close();
    }
    final body = _decode(response);
    if (response.statusCode != 201) {
      throw BackendStartFailure(
        body['message'] as String? ??
            'Could not create the initial Admin account.',
      );
    }
  }

  Future<http.Response> _send(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw const BackendStartFailure(
        'The local API did not respond. Restart Thanigai Stores and try again.',
      );
    } on SocketException {
      throw const BackendStartFailure(
        'Could not connect to the local API. Restart Thanigai Stores and try again.',
      );
    } on http.ClientException {
      throw const BackendStartFailure(
        'Could not connect to the local API. Restart Thanigai Stores and try again.',
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      throw const BackendStartFailure(
        'The local API returned an invalid response.',
      );
    }
    throw const BackendStartFailure(
      'The local API returned an invalid response.',
    );
  }
}
