import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:malligai_kadai/auth/local_backend_supervisor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'initial setup creates settings before attempting API startup',
    () async {
      const settings = LocalBackendSettings(
        host: '127.0.0.1',
        port: 55432,
        database: 'thanigai_stores',
        username: 'thanigai_app',
        password: 'generated-database-password',
        jwtSecret: 'generated-jwt-secret',
        initialSetupToken: 'generated-initial-setup-token',
      );
      final supervisor = _FirstRunSupervisor(settings);

      expect(await supervisor.readSettings(), isNull);
      final prepared = await supervisor.loadOrInitializeSettings();

      expect(prepared.toJson(), settings.toJson());
      expect(supervisor.prepareCalls, 1);
      expect(
        (await supervisor.loadOrInitializeSettings()).toJson(),
        settings.toJson(),
      );
      expect(supervisor.prepareCalls, 1);
    },
  );

  test('rejects saved database settings that target another database', () {
    expect(
      () => LocalBackendSettings.fromJson({
        'host': 'localhost',
        'port': 5432,
        'database': 'developer_database',
        'username': 'developer',
        'password': 'password',
        'jwtSecret': 'jwt-secret',
        'initialSetupToken': 'setup-token',
      }),
      throwsA(isA<BackendStartFailure>()),
    );
  });

  test(
    'closing the app does not wait for or stop the local database',
    () async {
      final supervisor = LocalBackendSupervisor();

      await supervisor.stop(stopDatabase: false);

      await expectLater(
        supervisor.startAndWait(),
        throwsA(
          isA<BackendStartFailure>().having(
            (error) => error.message,
            'message',
            'Thanigai Stores is closing.',
          ),
        ),
      );
    },
  );

  test(
    'starts a Windows manager and drains output without waiting for EOF',
    () async {
      if (!Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'malligai-detached-process-',
      );
      final marker = File(
        '${directory.path}${Platform.pathSeparator}result.txt',
      );
      try {
        final process = await Process.start(
          r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
          [
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'[IO.File]::WriteAllText($env:THANIGAI_PROCESS_MARKER, "0")',
          ],
          environment: {
            ...Platform.environment,
            'THANIGAI_PROCESS_MARKER': marker.path,
          },
          runInShell: false,
          mode: ProcessStartMode.normal,
        );
        final stdout = StringBuffer();
        final stderr = StringBuffer();
        process.stdout.transform(utf8.decoder).listen(stdout.write);
        process.stderr.transform(utf8.decoder).listen(stderr.write);
        await process.stdin.close();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!await marker.exists() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          await marker.exists(),
          isTrue,
          reason:
              'Detached process ${process.pid} did not write ${marker.path}. '
              'stdout=${stdout.toString()} stderr=${stderr.toString()}',
        );
        expect(await marker.readAsString(), '0');
        expect(await process.exitCode, 0);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'accepts API readiness only after its database health check succeeds',
    () {
      expect(
        isHealthyLocalApiResponse(200, {
          'status': 'ok',
          'service': 'thanigai-stores-api',
          'database': 'ok',
        }),
        isTrue,
      );
      expect(
        isHealthyLocalApiResponse(503, {
          'status': 'error',
          'service': 'thanigai-stores-api',
          'database': 'unavailable',
        }),
        isFalse,
      );
      expect(
        isHealthyLocalApiResponse(200, {
          'status': 'ok',
          'message': 'A different service is listening.',
        }),
        isFalse,
      );
    },
  );

  test('selects a free API port when the preferred port is occupied', () async {
    final occupiedPort = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    try {
      final selectedPort = await selectAvailableApiPort(
        preferredPort: occupiedPort.port,
      );

      expect(selectedPort, isNot(occupiedPort.port));
      final selectedSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        selectedPort,
      );
      await selectedSocket.close();
    } finally {
      await occupiedPort.close();
    }
  });

  test('recognizes only the bundled Thanigai backend as reusable', () {
    expect(
      isBundledThanigaiBackendOwner(
        processName: 'node.exe',
        executablePath: r'C:\Thanigai Stores\backend\node.exe',
        commandLine: r'"C:\Thanigai Stores\backend\node.exe" "C:\Thanigai Stores\backend\dist\server.js"',
        expectedNodeExecutable: r'C:\Thanigai Stores\backend\node.exe',
        expectedServerScript: r'C:\Thanigai Stores\backend\dist\server.js',
      ),
      isTrue,
    );
    expect(
      isBundledThanigaiBackendOwner(
        processName: 'node.exe',
        executablePath: r'C:\Program Files\nodejs\node.exe',
        commandLine: r'node.exe server.js',
        expectedNodeExecutable: r'C:\Thanigai Stores\backend\node.exe',
        expectedServerScript: r'C:\Thanigai Stores\backend\dist\server.js',
      ),
      isFalse,
    );
  });

  test('reports the port owner and does not suggest terminating it', () {
    final message = apiPortConflictMessage(
      processId: 18420,
      processName: 'node.exe',
      executablePath: r'C:\Thanigai Stores\backend\node.exe',
    );

    expect(message, contains('PID 18420'));
    expect(message, contains(r'C:\Thanigai Stores\backend\node.exe'));
    expect(message, contains('No process was stopped'));
  });

  test('persists and supplies the initial setup token to the backend', () {
    const settings = LocalBackendSettings(
      host: '127.0.0.1',
      port: 55432,
      database: 'thanigai_stores',
      username: 'thanigai_app',
      password: 'database-password',
      jwtSecret: 'jwt-secret',
      initialSetupToken: 'one-time-setup-token',
    );
    final restored = LocalBackendSettings.fromJson(
      jsonDecode(jsonEncode(settings.toJson())),
    );

    final environment = restored.processEnvironment(apiPort: 31337);
    expect(environment['INITIAL_SETUP_TOKEN'], 'one-time-setup-token');
    expect(environment['API_PORT'], '31337');
  });

  test('sends the setup token only with initial Admin creation', () async {
    const setupToken = 'one-time-setup-token';
    var receivedToken = '';
    final client = MockClient((request) async {
      expect(request.url.port, 31337);
      receivedToken = request.headers.entries
          .firstWhere(
            (entry) => entry.key.toLowerCase() == 'x-initial-setup-token',
          )
          .value;
      expect(request.method, 'POST');
      expect(request.url.path, '/setup/admin');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body, {'username': 'admin', 'password': 'admin-password'});
      expect(utf8.encode(request.body).length, lessThanOrEqualTo(32 * 1024));
      return http.Response('{}', 201);
    });

    await InitialAdminSetupApi(
      setupToken: setupToken,
      baseUrl: 'http://127.0.0.1:31337',
      client: client,
    ).createInitialAdmin('admin', 'admin-password');

    expect(receivedToken, setupToken);
  });

  test('maps startup failures to actionable, secret-free setup messages', () {
    expect(
      databaseStartupFailureMessage('authentication'),
      contains('Repair the installation'),
    );
    expect(
      databaseStartupFailureMessage('database_missing'),
      contains('database is missing'),
    );
    expect(
      databaseStartupFailureMessage('insufficient_privileges'),
      contains('permissions'),
    );
    expect(
      databaseStartupFailureMessage('server_unavailable'),
      contains('per-user PostgreSQL process'),
    );
    expect(
      databaseStartupFailureMessage('migration'),
      contains('initialization failed'),
    );
    expect(
      databaseStartupFailureMessage('port_in_use'),
      contains('will not stop unrelated processes'),
    );
    expect(
      databaseStartupFailureMessage('unknown'),
      contains('stopped before becoming ready'),
    );
  });

  test('reads the most recent PostgreSQL setup failure from the safe log', () {
    expect(
      postgresManagerFailureReason([
        '2026-10-31 16:00:00Z [starting] Failed: earlier setup failure.',
        '2026-10-31 16:01:00Z [starting] Still retrying.',
        '2026-10-31 16:02:00Z [starting] Failed: latest setup failure.',
      ]),
      'latest setup failure.',
    );
    expect(
      postgresManagerFailureReason([
        '2026-10-31 16:00:00Z [starting] manager started.',
      ]),
      isNull,
    );
  });

  test('does not report a failure from an earlier PostgreSQL run', () {
    expect(
      postgresManagerFailureReason([
        '2026-10-31 16:00:00Z [starting] manager_started manager_pid=184.',
        '2026-10-31 16:00:00Z [starting] Failed: earlier setup failure.',
        '2026-10-31 16:02:00Z [starting] manager_started manager_pid=285.',
        '2026-10-31 16:02:00Z [starting] Failed: current setup failure.',
      ], managerProcessId: 285),
      'current setup failure.',
    );
    expect(
      postgresManagerFailureReason([
        '2026-10-31 16:00:00Z [starting] manager_started manager_pid=184.',
        '2026-10-31 16:00:00Z [starting] Failed: earlier setup failure.',
      ], managerProcessId: 285),
      isNull,
    );
  });
}

class _FirstRunSupervisor extends LocalBackendSupervisor {
  _FirstRunSupervisor(this.settings);

  final LocalBackendSettings settings;
  LocalBackendSettings? savedSettings;
  int prepareCalls = 0;

  @override
  Future<LocalBackendSettings?> readSettings() async => savedSettings;

  @override
  Future<void> prepareDatabase() async {
    prepareCalls++;
    savedSettings = settings;
  }
}
