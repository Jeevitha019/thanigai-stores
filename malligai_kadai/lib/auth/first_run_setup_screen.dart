import 'dart:convert';

import 'package:flutter/material.dart';

import 'local_backend_supervisor.dart';

class FirstRunSetupScreen extends StatefulWidget {
  const FirstRunSetupScreen({
    super.key,
    required this.needsDatabaseConfiguration,
    required this.needsInitialAdmin,
    required this.isWorking,
    required this.onSaveDatabase,
    required this.onCreateAdmin,
    this.allowManualDatabaseConfiguration = true,
    this.onRetryDatabaseSetup,
    this.errorMessage,
    this.savedSettings,
  });

  final bool needsDatabaseConfiguration;
  final bool needsInitialAdmin;
  final bool isWorking;
  final Future<void> Function({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
  })
  onSaveDatabase;
  final Future<void> Function(String username, String password) onCreateAdmin;
  final bool allowManualDatabaseConfiguration;
  final Future<void> Function()? onRetryDatabaseSetup;
  final String? errorMessage;
  final LocalBackendSettings? savedSettings;

  @override
  State<FirstRunSetupScreen> createState() => _FirstRunSetupScreenState();
}

class _FirstRunSetupScreenState extends State<FirstRunSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _databaseController = TextEditingController();
  final _databaseUserController = TextEditingController();
  final _databasePasswordController = TextEditingController();
  final _adminUsernameController = TextEditingController();
  final _adminPasswordController = TextEditingController();
  bool _adminPasswordVisible = false;

  @override
  void initState() {
    super.initState();
    _hostController.text = widget.savedSettings?.host ?? 'localhost';
    _portController.text = '${widget.savedSettings?.port ?? 5432}';
    _databaseController.text = widget.savedSettings?.database ?? '';
    _databaseUserController.text = widget.savedSettings?.username ?? '';
    _databasePasswordController.text = widget.savedSettings?.password ?? '';
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _databaseController.dispose();
    _databaseUserController.dispose();
    _databasePasswordController.dispose();
    _adminUsernameController.dispose();
    _adminPasswordController.dispose();
    super.dispose();
  }

  void _submitDatabase() {
    if (!_formKey.currentState!.validate()) return;
    widget.onSaveDatabase(
      host: _hostController.text.trim(),
      port: int.parse(_portController.text.trim()),
      database: _databaseController.text.trim(),
      username: _databaseUserController.text.trim(),
      password: _databasePasswordController.text,
    );
  }

  void _submitAdmin() {
    if (!_formKey.currentState!.validate()) return;
    widget.onCreateAdmin(
      _adminUsernameController.text.trim(),
      _adminPasswordController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final configuringDatabase = widget.needsDatabaseConfiguration;
    final manualDatabaseConfiguration =
        configuringDatabase && widget.allowManualDatabaseConfiguration;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/thanigai_stores_logo.png',
                        width: 88,
                        height: 88,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Thanigai Stores',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF20372C),
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        configuringDatabase
                            ? widget.allowManualDatabaseConfiguration
                                  ? 'Connect your shop database'
                                  : 'Preparing your local shop database'
                            : 'Create your first Admin account',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF627369),
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 23),
                      if (manualDatabaseConfiguration) ..._databaseFields(),
                      if (configuringDatabase &&
                          !widget.allowManualDatabaseConfiguration)
                        const Text(
                          'PostgreSQL is bundled with the app and initialized on this PC. No download, database details, or Administrator access is required.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF627369),
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      if (!configuringDatabase && widget.needsInitialAdmin)
                        ..._adminFields(),
                      if (widget.errorMessage != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF0EF),
                            border: Border.all(color: const Color(0xFFF3D1CC)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            widget.errorMessage!,
                            style: const TextStyle(
                              color: Color(0xFF8A3C34),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        key: const Key('firstRunSubmitButton'),
                        onPressed: widget.isWorking
                            ? null
                            : manualDatabaseConfiguration
                            ? _submitDatabase
                            : configuringDatabase
                            ? widget.onRetryDatabaseSetup
                            : _submitAdmin,
                        icon: widget.isWorking
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                manualDatabaseConfiguration
                                    ? Icons.cable_rounded
                                    : configuringDatabase
                                    ? Icons.refresh_rounded
                                    : Icons.person_add_alt_1_rounded,
                              ),
                        label: Text(
                          widget.isWorking
                              ? 'Please wait...'
                              : manualDatabaseConfiguration
                              ? 'Test connection and continue'
                              : configuringDatabase
                              ? 'Retry automatic setup'
                              : 'Create Admin account',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        manualDatabaseConfiguration
                            ? 'Credentials are stored in Windows secure storage. After PostgreSQL connects, pending safe migrations are applied. Thanigai Stores will not create, reset, or delete a database.'
                            : configuringDatabase
                            ? 'Select Retry to rerun local setup. No PostgreSQL download or Administrator access is needed. If it keeps failing, share %LOCALAPPDATA%\\Thanigai Stores\\database-setup.log and backend-startup.log with support. Existing shop data is preserved.'
                            : 'Choose a unique username and a strong password. Only a bcrypt password hash is saved.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF78867D),
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _databaseFields() => [
    TextFormField(
      key: const Key('dbHostField'),
      controller: _hostController,
      decoration: const InputDecoration(
        labelText: 'PostgreSQL host',
        border: OutlineInputBorder(),
      ),
      validator: (value) => value == null || value.trim().isEmpty
          ? 'Enter your PostgreSQL host.'
          : null,
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        Expanded(
          child: TextFormField(
            key: const Key('dbPortField'),
            controller: _portController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Port',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              final port = int.tryParse(value?.trim() ?? '');
              return port == null || port < 1 || port > 65535
                  ? 'Enter a valid port.'
                  : null;
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextFormField(
            key: const Key('dbNameField'),
            controller: _databaseController,
            decoration: const InputDecoration(
              labelText: 'Database name',
              border: OutlineInputBorder(),
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Enter the database name.'
                : null,
          ),
        ),
      ],
    ),
    const SizedBox(height: 12),
    TextFormField(
      key: const Key('dbUsernameField'),
      controller: _databaseUserController,
      decoration: const InputDecoration(
        labelText: 'PostgreSQL username',
        border: OutlineInputBorder(),
      ),
      validator: (value) => value == null || value.trim().isEmpty
          ? 'Enter the PostgreSQL username.'
          : null,
    ),
    const SizedBox(height: 12),
    TextFormField(
      key: const Key('dbPasswordField'),
      controller: _databasePasswordController,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(
        labelText: 'PostgreSQL password',
        border: OutlineInputBorder(),
      ),
      validator: (value) => value == null || value.isEmpty
          ? 'Enter the PostgreSQL password.'
          : null,
    ),
  ];

  List<Widget> _adminFields() => [
    TextFormField(
      key: const Key('initialAdminUsernameField'),
      controller: _adminUsernameController,
      autocorrect: false,
      textCapitalization: TextCapitalization.none,
      decoration: const InputDecoration(
        labelText: 'Admin username',
        helperText: '2–64 letters, numbers, dots, _ or -',
        border: OutlineInputBorder(),
      ),
      validator: (value) =>
          value == null ||
              !RegExp(r'^[A-Za-z0-9._-]{2,64}$').hasMatch(value.trim())
          ? 'Use 2–64 letters, numbers, dots, _ or -.'
          : null,
    ),
    const SizedBox(height: 12),
    TextFormField(
      key: const Key('initialAdminPasswordField'),
      controller: _adminPasswordController,
      obscureText: !_adminPasswordVisible,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: 'Admin password',
        helperText: 'Use at least 4 characters (maximum 72 UTF-8 bytes)',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _adminPasswordVisible ? 'Hide password' : 'Show password',
          onPressed: () =>
              setState(() => _adminPasswordVisible = !_adminPasswordVisible),
          icon: Icon(
            _adminPasswordVisible
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
          ),
        ),
      ),
      validator: (value) {
        final text = value ?? '';
        final bytes = utf8.encode(text).length;
        return text.runes.length < 4 || bytes > 72
            ? 'Use at least 4 characters and no more than 72 UTF-8 bytes.'
            : null;
      },
    ),
  ];
}
