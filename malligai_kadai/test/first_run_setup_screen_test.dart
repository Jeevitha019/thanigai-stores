import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malligai_kadai/auth/first_run_setup_screen.dart';

void main() {
  testWidgets('packaged setup never asks the owner for PostgreSQL details', (
    tester,
  ) async {
    var retryCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupScreen(
          needsDatabaseConfiguration: true,
          needsInitialAdmin: false,
          isWorking: false,
          errorMessage: 'Port 3000 is already in use.',
          allowManualDatabaseConfiguration: false,
          onSaveDatabase: ({
            required String host,
            required int port,
            required String database,
            required String username,
            required String password,
          }) async {},
          onRetryDatabaseSetup: () async => retryCount++,
          onCreateAdmin: (_, _) async {},
        ),
      ),
    );

    expect(find.text('PostgreSQL host'), findsNothing);
    expect(find.text('Port'), findsNothing);
    expect(find.text('Database name'), findsNothing);
    expect(find.text('PostgreSQL username'), findsNothing);
    expect(find.text('PostgreSQL password'), findsNothing);
    expect(find.textContaining('bundled with the app'), findsOneWidget);
    expect(find.textContaining('%LOCALAPPDATA%'), findsOneWidget);
    expect(find.textContaining('administrator permission'), findsNothing);

    await tester.tap(find.byKey(const Key('firstRunSubmitButton')));
    await tester.pump();

    expect(retryCount, 1);
  });

  testWidgets(
    'collects PostgreSQL configuration without assuming the database',
    (tester) async {
      Map<String, Object?>? submitted;
      await tester.pumpWidget(
        MaterialApp(
          home: FirstRunSetupScreen(
            needsDatabaseConfiguration: true,
            needsInitialAdmin: false,
            isWorking: false,
            onSaveDatabase:
                ({
                  required String host,
                  required int port,
                  required String database,
                  required String username,
                  required String password,
                }) async {
                  submitted = {
                    'host': host,
                    'port': port,
                    'database': database,
                    'username': username,
                    'password': password,
                  };
                },
            onCreateAdmin: (_, _) async {},
          ),
        ),
      );

      expect(find.text('Database name'), findsOneWidget);
      expect(find.text('PostgreSQL username'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('dbNameField')), 'shop_db');
      await tester.enterText(
        find.byKey(const Key('dbUsernameField')),
        'shop_user',
      );
      await tester.enterText(
        find.byKey(const Key('dbPasswordField')),
        'local-secret',
      );
      await tester.tap(find.byKey(const Key('firstRunSubmitButton')));
      await tester.pump();

      expect(submitted, {
        'host': 'localhost',
        'port': 5432,
        'database': 'shop_db',
        'username': 'shop_user',
        'password': 'local-secret',
      });
    },
  );

  testWidgets('validates database connection fields before submitting', (
    tester,
  ) async {
    var submitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupScreen(
          needsDatabaseConfiguration: true,
          needsInitialAdmin: false,
          isWorking: false,
          onSaveDatabase:
              ({
                required String host,
                required int port,
                required String database,
                required String username,
                required String password,
              }) async {
                submitCount++;
              },
          onCreateAdmin: (_, _) async {},
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('dbPortField')), '99999');
    await tester.tap(find.byKey(const Key('firstRunSubmitButton')));
    await tester.pumpAndSettle();

    expect(submitCount, 0);
    expect(find.text('Enter a valid port.'), findsOneWidget);
  });
}
