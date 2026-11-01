import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ffi/ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'auth/auth_gate.dart';
import 'auth/auth_gateway.dart';
import 'auth/local_backend_supervisor.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final instanceLock = WindowsAppInstanceLock.tryAcquire();
  if (Platform.isWindows && instanceLock == null) {
    debugPrint('Thanigai Stores is already running for this Windows user.');
    exit(0);
  }
  await windowManager.ensureInitialized();
  runApp(MalligaiKadaiApp(instanceLock: instanceLock));
}

class MalligaiKadaiApp extends StatefulWidget {
  const MalligaiKadaiApp({super.key, this.authGateway, this.instanceLock});

  final AuthGateway? authGateway;
  final WindowsAppInstanceLock? instanceLock;

  @override
  State<MalligaiKadaiApp> createState() => _MalligaiKadaiAppState();
}

class _MalligaiKadaiAppState extends State<MalligaiKadaiApp>
    with WindowListener {
  LocalBackendSupervisor? _backendSupervisor;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    if (kReleaseMode && widget.authGateway == null) {
      _backendSupervisor = LocalBackendSupervisor();
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void onWindowClose() {
    unawaited(
      _closeWindow().catchError((Object error) {
        debugPrint('Thanigai Stores could not finish closing cleanly: $error');
      }),
    );
  }

  Future<void> _closeWindow() async {
    if (_isClosing) return;
    _isClosing = true;
    try {
      await _backendSupervisor?.stop(stopDatabase: false);
    } catch (error) {
      debugPrint('Thanigai Stores local services did not stop cleanly: $error');
    } finally {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }

  @override
  void dispose() {
    if (_backendSupervisor != null) {
      windowManager.removeListener(this);
      unawaited(
        _backendSupervisor!.stop(stopDatabase: false).catchError((
          Object error,
        ) {
          debugPrint(
            'Thanigai Stores local services did not stop cleanly: $error',
          );
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const brandColor = Color(0xFF245C45);

    return MaterialApp(
      title: 'Thanigai Stores',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandColor,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6F2),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF20372C),
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFFE3EAE4)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        useMaterial3: true,
      ),
      home: AuthGate(
        authGateway: widget.authGateway ?? HttpAuthGateway(),
        backendSupervisor: _backendSupervisor,
      ),
    );
  }
}

typedef _CreateMutexNative = Pointer<Void> Function(
  Pointer<Void>,
  Int32,
  Pointer<Utf16>,
);
typedef _CreateMutexDart = Pointer<Void> Function(
  Pointer<Void>,
  int,
  Pointer<Utf16>,
);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
typedef _SetLastErrorNative = Void Function(Uint32);
typedef _SetLastErrorDart = void Function(int);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);

class WindowsAppInstanceLock {
  WindowsAppInstanceLock._(this._handle, this._closeHandle);

  static const _errorAlreadyExists = 183;
  final Pointer<Void> _handle;
  final _CloseHandleDart _closeHandle;
  bool _released = false;

  static WindowsAppInstanceLock? tryAcquire() {
    if (!Platform.isWindows) return null;

    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createMutex = kernel32
        .lookupFunction<_CreateMutexNative, _CreateMutexDart>('CreateMutexW');
    final getLastError = kernel32
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
    final setLastError = kernel32
        .lookupFunction<_SetLastErrorNative, _SetLastErrorDart>('SetLastError');
    final closeHandle = kernel32
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    final username = Platform.environment['USERNAME'] ?? 'current-user';
    final domain = Platform.environment['USERDOMAIN'] ?? 'local';
    final name = 'Global\\ThanigaiStores.Desktop.$domain.$username'
        .toNativeUtf16();
    try {
      setLastError(0);
      final handle = createMutex(nullptr, 0, name);
      if (handle == nullptr) {
        throw StateError('Could not create the Thanigai Stores app mutex.');
      }
      if (getLastError() == _errorAlreadyExists) {
        closeHandle(handle);
        return null;
      }
      return WindowsAppInstanceLock._(handle, closeHandle);
    } finally {
      calloc.free(name);
    }
  }

  void release() {
    if (_released) return;
    _released = true;
    _closeHandle(_handle);
  }
}
