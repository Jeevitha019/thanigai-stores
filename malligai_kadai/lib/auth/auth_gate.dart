import 'dart:async';

import 'package:flutter/material.dart';

import 'auth_gateway.dart';
import 'first_run_setup_screen.dart';
import 'home_screens.dart';
import 'local_backend_supervisor.dart';
import 'login_screen.dart';
import '../products/sample_product_importer.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authGateway,
    this.backendSupervisor,
  });

  final AuthGateway authGateway;
  final LocalBackendSupervisor? backendSupervisor;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  static const _defaultApiBaseUrl = 'http://127.0.0.1:3000';
  static const _sessionLifetime = Duration(minutes: 15);

  AuthUser? _user;
  String? _restoreError;
  String? _backendError;
  String _loadingMessage = 'Starting Thanigai Stores...';
  String? _savedToken;
  String _apiBaseUrl = _defaultApiBaseUrl;
  AuthGateway? _backendGateway;
  LocalBackendSettings? _backendSettings;
  bool _isLoading = true;
  bool _needsDatabaseConfiguration = false;
  bool _needsInitialAdmin = false;
  bool _isWorking = false;
  bool _launchSessionCleared = false;
  Timer? _sessionExpiryTimer;

  AuthGateway get _authGateway => _backendGateway ?? widget.authGateway;

  void _useSelectedApiPort(LocalBackendSupervisor supervisor) {
    _apiBaseUrl = supervisor.apiBaseUrl;
    if (_apiBaseUrl != _defaultApiBaseUrl &&
        widget.authGateway is HttpAuthGateway) {
      _backendGateway = HttpAuthGateway(baseUrl: _apiBaseUrl);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.backendSupervisor != null) {
      _initializePackagedApp();
    } else {
      _restoreSession();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _user != null) {
      _validateSessionOnResume();
    }
  }

  Future<void> _validateSessionOnResume() async {
    try {
      final token = await _authGateway.readToken();
      if (token == null || token.isEmpty) {
        await _expireSession();
        return;
      }
      await _authGateway.currentUser(token);
    } on AuthFailure catch (error) {
      if (error.statusCode == 401) await _expireSession();
    } catch (_) {
      // A temporary network failure must not invalidate a still-live session.
    }
  }

  Future<void> _expireSession() async {
    _sessionExpiryTimer?.cancel();
    String? clearError;
    try {
      await _authGateway.clearToken();
    } catch (_) {
      clearError = 'Could not securely clear the expired sign-in. Restart the app and try again.';
    }
    if (mounted) {
      setState(() {
        _user = null;
        _savedToken = null;
        _restoreError = clearError;
      });
    }
  }

  void _scheduleSessionExpiry() {
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = Timer(_sessionLifetime, _expireSession);
  }

  void _setLoadingMessage(String message) {
    if (!mounted) return;
    setState(() => _loadingMessage = message);
  }

  Future<void> _initializePackagedApp() async {
    final supervisor = widget.backendSupervisor!;
    setState(() {
      _isLoading = true;
      _backendError = null;
      _loadingMessage = 'Starting your local shop database...';
    });
    try {
      if (!_launchSessionCleared) {
        await _authGateway.clearToken();
        _launchSessionCleared = true;
      }
      _setLoadingMessage('Preparing your local shop database...');
      _backendSettings = await supervisor.loadOrInitializeSettings();
      _setLoadingMessage('Connecting to your shop...');
      await supervisor.startAndWait(settings: _backendSettings);
      _useSelectedApiPort(supervisor);
      if (!mounted) return;
      _setLoadingMessage('Checking your sign-in...');
      _needsInitialAdmin = await InitialAdminSetupApi(
        setupToken: _backendSettings!.initialSetupToken,
        baseUrl: _apiBaseUrl,
      ).setupRequired();
      _needsDatabaseConfiguration = false;
      if (_needsInitialAdmin) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      await _restoreSession();
    } on BackendStartFailure catch (error) {
      if (mounted) {
        setState(() {
          _needsDatabaseConfiguration = true;
          _backendError = error.message;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _needsDatabaseConfiguration = true;
          _backendError = 'Thanigai Stores could not finish preparing your shop. Select Retry to try again. Review %LOCALAPPDATA%\\Malligai Kadai\\database-setup.log and backend-startup.log for details.';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveDatabaseSettings({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
  }) async {
    final supervisor = widget.backendSupervisor;
    if (supervisor == null) return;
    setState(() {
      _isWorking = true;
      _backendError = null;
    });
    try {
      await supervisor.saveSettings(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
      );
      _backendSettings = await supervisor.readSettings();
      await supervisor.startAndWait(settings: _backendSettings);
      _useSelectedApiPort(supervisor);
      _needsInitialAdmin = await InitialAdminSetupApi(
        setupToken: _backendSettings!.initialSetupToken,
        baseUrl: _apiBaseUrl,
      ).setupRequired();
      _needsDatabaseConfiguration = false;
      if (_needsInitialAdmin) {
        if (mounted) {
          setState(() {
            _isWorking = false;
            _isLoading = false;
          });
        }
      } else {
        await _restoreSession();
      }
    } on BackendStartFailure catch (error) {
      if (mounted) {
        setState(() {
          _needsDatabaseConfiguration = true;
          _backendError = error.message;
          _isWorking = false;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _needsDatabaseConfiguration = true;
          _backendError = 'Could not securely save settings or connect to the database. Verify the PostgreSQL details and retry.';
          _isWorking = false;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _retryAutomaticDatabaseSetup() async {
    final supervisor = widget.backendSupervisor;
    if (supervisor == null) return;
    setState(() {
      _isWorking = true;
      _backendError = null;
    });
    try {
      _backendSettings ??= await supervisor.loadOrInitializeSettings();
      await supervisor.startAndWait(settings: _backendSettings);
      _useSelectedApiPort(supervisor);
      _needsInitialAdmin = await InitialAdminSetupApi(
        setupToken: _backendSettings!.initialSetupToken,
        baseUrl: _apiBaseUrl,
      ).setupRequired();
      _needsDatabaseConfiguration = false;
      if (_needsInitialAdmin) {
        if (mounted) {
          setState(() {
            _isWorking = false;
            _isLoading = false;
          });
        }
      } else {
        await _restoreSession();
      }
    } on BackendStartFailure catch (error) {
      if (mounted) {
        setState(() {
          _needsDatabaseConfiguration = true;
          _backendError = error.message;
          _isWorking = false;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _needsDatabaseConfiguration = true;
          _backendError = 'Could not complete local database setup. Select Retry and review %LOCALAPPDATA%\\Malligai Kadai\\database-setup.log and backend-startup.log.';
          _isWorking = false;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _createInitialAdmin(String username, String password) async {
    setState(() {
      _isWorking = true;
      _backendError = null;
    });
    try {
      final setupToken = _backendSettings?.initialSetupToken;
      if (setupToken == null) {
        throw const BackendStartFailure(
          'The initial setup authorization could not be loaded. Restart the app and try again.',
        );
      }
      final sampleProducts = await SampleProductImporter.loadBundledProducts();
      await InitialAdminSetupApi(
        setupToken: setupToken,
        baseUrl: _apiBaseUrl,
      ).createInitialAdmin(username, password, sampleProducts);
      _needsInitialAdmin = false;
      if (mounted) setState(() => _isWorking = false);
      await _restoreSession();
    } on BackendStartFailure catch (error) {
      if (mounted) {
        setState(() {
          _backendError = error.message;
          _isWorking = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _backendError = 'Could not create the initial Admin account. Check the database and try again.';
          _isWorking = false;
        });
      }
    }
  }

  Future<void> _restoreSession() async {
    setState(() {
      _isLoading = true;
      _restoreError = null;
      _loadingMessage = 'Checking your sign-in...';
    });

    try {
      final token = await _authGateway.readToken();
      if (token == null || token.isEmpty) {
        _savedToken = null;
        _user = null;
      } else {
        _savedToken = token;
        try {
          _user = await _authGateway.currentUser(token);
          _scheduleSessionExpiry();
        } on AuthFailure catch (error) {
          if (error.statusCode == 401) {
            await _authGateway.clearToken();
            _savedToken = null;
            _user = null;
          } else {
            rethrow;
          }
        }
      }
    } on AuthFailure catch (error) {
      _restoreError = error.message;
    } catch (_) {
      _restoreError = 'Could not restore the saved sign-in. Please try again.';
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<AuthUser> _login(
    String username,
    String password,
    UserRole role,
  ) async {
    final user = await _authGateway.login(username, password, role);
    if (mounted) {
      setState(() {
        _user = user;
        _savedToken = null;
        _restoreError = null;
      });
      _scheduleSessionExpiry();
    }
    return user;
  }

  Future<void> _logout() async {
    _sessionExpiryTimer?.cancel();
    await _authGateway.clearToken();
    if (mounted) {
      setState(() {
        _user = null;
        _savedToken = null;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionExpiryTimer?.cancel();
    super.dispose();
  }

  Future<AuthUser> _createCashier(String username, String password) {
    return _authGateway.createCashier(username, password);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/thanigai_stores_logo.png',
                    width: 96,
                    height: 64,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Thanigai Stores',
                    style: TextStyle(
                      color: Color(0xFF20372C),
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _loadingMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF65736A),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const LinearProgressIndicator(),
                  if (widget.backendSupervisor != null) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'First startup can take a little longer. Please keep this window open.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF87948A), fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (widget.backendSupervisor != null &&
        (_needsDatabaseConfiguration || _needsInitialAdmin)) {
      return FirstRunSetupScreen(
        needsDatabaseConfiguration: _needsDatabaseConfiguration,
        needsInitialAdmin: _needsInitialAdmin,
        isWorking: _isWorking,
        onSaveDatabase: _saveDatabaseSettings,
        onCreateAdmin: _createInitialAdmin,
        allowManualDatabaseConfiguration: false,
        onRetryDatabaseSetup: _retryAutomaticDatabaseSetup,
        errorMessage: _backendError,
        savedSettings: _backendSettings,
      );
    }

    final user = _user;
    if (user != null) {
      return user.role == UserRole.admin
          ? AdminHomeScreen(
              user: user,
              onLogout: _logout,
              onCreateCashier: _createCashier,
              onChangePassword: _authGateway.changePassword,
              productGateway: _authGateway,
              billingGateway: _authGateway,
              reportsGateway: _authGateway,
            )
          : CashierHomeScreen(
              user: user,
              onLogout: _logout,
              onChangePassword: _authGateway.changePassword,
              productGateway: _authGateway,
              billingGateway: _authGateway,
              reportsGateway: _authGateway,
            );
    }

    if (_restoreError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _restoreError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _restoreSession,
                  child: const Text('Retry'),
                ),
                if (_savedToken != null) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _logout,
                    child: const Text('Clear saved sign-in'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return LoginScreen(onLogin: _login);
  }
}
