import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:malligai_kadai/billing/billing_gateway.dart';
import 'package:malligai_kadai/billing/billing_screen.dart';
import 'package:malligai_kadai/billing/receipt_printer.dart';
import 'package:malligai_kadai/billing/receipt_preview_screen.dart';
import 'package:malligai_kadai/billing/invoice_history_screen.dart';
import 'package:malligai_kadai/auth/auth_gate.dart';
import 'package:malligai_kadai/auth/auth_gateway.dart';
import 'package:malligai_kadai/auth/login_screen.dart';
import 'package:malligai_kadai/auth/local_backend_supervisor.dart';
import 'package:malligai_kadai/main.dart';
import 'package:malligai_kadai/products/product_gateway.dart';
import 'package:malligai_kadai/products/product_screen.dart';
import 'package:malligai_kadai/reports/reports_gateway.dart';
import 'package:http/testing.dart';

class FakeAuthGateway implements AuthGateway {
  FakeAuthGateway({this.initialUser, this.loginError, this.currentUserError});

  AuthUser? initialUser;
  final AuthFailure? loginError;
  AuthFailure? currentUserError;
  String? token;
  AuthUser? signedInUser;
  bool gstEnabled = false;
  String gstRate = '0.00';
  String gstPriceMode = 'exclusive';
  String gstStateCode = '33';
  BillingFailure? invoiceListFailure;
  BillingFailure? voidInvoiceFailure;
  int invoiceListCalls = 0;
  List<InvoicePayment>? lastPayments;
  String? lastSaleStateCode;
  final createdCashiers = <String, String>{};
  final passwordChanges = <List<String>>[];
  final productItems = <ProductItem>[];
  final removedProductIds = <String>[];
  final savedInvoices = <String, SavedInvoice>{};
  final voidedInvoiceIds = <String>{};
  DashboardData? dashboardData;
  int dashboardCalls = 0;
  String? lastInvoiceKey;
  List<InvoiceCartItem> lastInvoiceItems = [];
  UserRole? lastSelectedRole;

  @override
  Future<AuthUser> currentUser(String token) async {
    if (currentUserError != null) throw currentUserError!;
    return initialUser ?? signedInUser!;
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    passwordChanges.add([currentPassword, newPassword]);
  }

  @override
  Future<AuthUser> createCashier(String username, String password) async {
    createdCashiers[username] = password;
    return AuthUser(id: '2', username: username, role: UserRole.cashier);
  }

  @override
  Future<List<ProductItem>> searchProducts(String search) async {
    final query = search.toLowerCase();
    return productItems
        .where(
          (product) =>
              query.isEmpty ||
              product.name.toLowerCase().contains(query) ||
              product.sku.toLowerCase().contains(query) ||
              product.category.toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  Future<ProductItem> createProduct(ProductDraft draft) async {
    final product = ProductItem(
      id: '10',
      name: draft.name,
      sku: draft.sku,
      category: draft.category,
      unit: draft.unit,
      purchasePrice: draft.purchasePrice,
      sellingPrice: draft.sellingPrice,
      mrp: draft.mrp,
      sellingQuantity: draft.sellingQuantity,
      openingStockQuantity: draft.openingStockQuantity,
      stockQuantity: draft.openingStockQuantity,
      gstRate: draft.gstRate,
    );
    productItems.add(product);
    return product;
  }

  @override
  Future<ProductItem> updateProduct(String id, ProductDraft draft) async {
    final product = ProductItem(
      id: id,
      name: draft.name,
      sku: draft.sku,
      category: draft.category,
      unit: draft.unit,
      purchasePrice: draft.purchasePrice,
      sellingPrice: draft.sellingPrice,
      mrp: draft.mrp,
      sellingQuantity: draft.sellingQuantity,
      openingStockQuantity: draft.openingStockQuantity,
      gstRate: draft.gstRate,
    );
    productItems.removeWhere((item) => item.id == id);
    productItems.add(product);
    return product;
  }

  @override
  Future<void> deleteProduct(String id) async {
    removedProductIds.add(id);
    productItems.removeWhere((item) => item.id == id);
  }

  @override
  Future<GstSettings> getGstSettings() async => GstSettings(
    gstEnabled: gstEnabled,
    gstRate: gstRate,
    priceMode: gstPriceMode,
    stateCode: gstStateCode,
    updatedAt: '',
  );

  @override
  Future<GstSettings> updateGstSettings({
    required bool gstEnabled,
    String gstRate = '0.00',
    required String priceMode,
    required String stateCode,
    String businessName = 'Thanigai Stores',
    String businessAddress = '',
    String businessPhone = '',
    String gstin = '',
  }) async => GstSettings(
    gstEnabled: this.gstEnabled = gstEnabled,
    gstRate: this.gstRate = gstRate,
    priceMode: gstPriceMode = priceMode,
    stateCode: gstStateCode = stateCode,
    updatedAt: '',
    businessName: businessName,
    businessAddress: businessAddress,
    businessPhone: businessPhone,
    gstin: gstin,
  );

  @override
  Future<SavedInvoice> createInvoice({
    required String idempotencyKey,
    required List<InvoiceCartItem> items,
    required String saleStateCode,
    String discountAmount = '0.00',
    String gstAmount = '0.00',
    required List<InvoicePayment> payments,
  }) async {
    lastInvoiceKey = idempotencyKey;
    lastInvoiceItems = items;
    lastPayments = payments;
    lastSaleStateCode = saleStateCode;
    final existing = savedInvoices[idempotencyKey];
    if (existing != null) {
      return SavedInvoice(
        id: existing.id,
        invoiceNumber: existing.invoiceNumber,
        cashierName: existing.cashierName,
        subtotal: existing.subtotal,
        grandTotal: existing.grandTotal,
        createdAt: existing.createdAt,
        items: existing.items,
        payments: existing.payments,
        replayed: true,
      );
    }
    final cents = items.fold<int>(0, (sum, item) {
      final product = productItems.firstWhere(
        (product) => product.id == item.productId,
      );
      final priceParts = item.unitPrice.split('.');
      final priceCents =
          int.parse(priceParts[0]) * 100 +
          int.parse(
            priceParts.length > 1 ? priceParts[1].padRight(2, '0') : '00',
          );
      final quantityParts = item.quantity.split('.');
      final quantityMilli =
          int.parse(quantityParts[0]) * 1000 +
          int.parse(
            quantityParts.length > 1
                ? quantityParts[1].padRight(3, '0')
                : '000',
          );
      final configuredParts = product.sellingQuantity.split('.');
      final configuredQuantityMilli =
          int.parse(configuredParts[0]) * 1000 +
          int.parse(
            configuredParts.length > 1
                ? configuredParts[1].padRight(3, '0')
                : '000',
          );
      return sum +
          (priceCents * quantityMilli + configuredQuantityMilli ~/ 2) ~/
              configuredQuantityMilli;
    });
    final discountParts = discountAmount.split('.');
    final discountCents =
        int.parse(discountParts[0]) * 100 +
        int.parse(
          discountParts.length > 1 ? discountParts[1].padRight(2, '0') : '00',
        );
    final amountAfterDiscountCents = cents - discountCents;
    final rateParts = gstRate.split('.');
    final rateHundredths =
        int.parse(rateParts[0]) * 100 +
        int.parse(rateParts.length > 1 ? rateParts[1].padRight(2, '0') : '00');
    final gstCents = !gstEnabled || rateHundredths == 0
        ? 0
        : gstPriceMode == 'inclusive'
        ? amountAfterDiscountCents -
              (amountAfterDiscountCents * 10000 +
                      (10000 + rateHundredths) ~/ 2) ~/
                  (10000 + rateHundredths)
        : (amountAfterDiscountCents * rateHundredths + 5000) ~/ 10000;
    final totalCents = gstPriceMode == 'inclusive'
        ? amountAfterDiscountCents
        : amountAfterDiscountCents + gstCents;
    final amount =
        '${totalCents ~/ 100}.${(totalCents % 100).toString().padLeft(2, '0')}';
    final subtotal =
        '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
    final invoice = SavedInvoice(
      id: '${savedInvoices.length + 1}',
      invoiceNumber: 'INV-TEST-0001',
      cashierName: 'till',
      subtotal: subtotal,
      grandTotal: amount,
      createdAt: DateTime.utc(2026).toIso8601String(),
      items: items.map((item) {
        final product = productItems.firstWhere(
          (product) => product.id == item.productId,
        );
        return SavedInvoiceItem(
          productName: product.name,
          sku: product.sku,
          unit: product.unit,
          unitPrice: item.unitPrice,
          quantity: item.quantity,
          lineTotal: amount,
        );
      }).toList(),
      payments: payments,
      replayed: false,
    );
    savedInvoices[idempotencyKey] = invoice;
    return invoice;
  }

  @override
  Future<List<SavedInvoice>> listInvoices({int limit = 50}) async {
    invoiceListCalls++;
    if (invoiceListFailure != null) throw invoiceListFailure!;
    return savedInvoices.values
        .where((invoice) => !voidedInvoiceIds.contains(invoice.id))
        .toList()
        .reversed
        .take(limit)
        .toList();
  }

  @override
  Future<SavedInvoice> findInvoiceById(String id) async =>
      savedInvoices.values.firstWhere((invoice) => invoice.id == id);

  @override
  Future<void> voidInvoice(String id) async {
    if (voidInvoiceFailure != null) throw voidInvoiceFailure!;
    await findInvoiceById(id);
    voidedInvoiceIds.add(id);
  }

  @override
  Future<DashboardData> dashboard(DateTime date) async {
    dashboardCalls++;
    return dashboardData ??
        DashboardData(
          date: date.toIso8601String().substring(0, 10),
          totalSales: '0.00',
          invoiceCount: savedInvoices.length,
          stockProductCount: 0,
          paymentSummary: const [],
        );
  }

  @override
  Future<SalesReportData> sales(DateTime start, DateTime end) async =>
      SalesReportData(
        startDate: start.toIso8601String().substring(0, 10),
        endDate: end.toIso8601String().substring(0, 10),
        totalSales: '0.00',
        invoiceCount: 0,
        paymentSummary: const [],
        invoices: const [],
      );

  @override
  Future<List<DatabaseBackup>> listBackups() async => [];

  @override
  Future<DatabaseBackup> createBackup() =>
      throw UnimplementedError('Backup is not used by this test gateway.');

  @override
  Future<void> restoreBackup(DatabaseBackup backup, String confirmation) =>
      throw UnimplementedError('Backup is not used by this test gateway.');

  @override
  Future<void> clearToken() async {
    token = null;
    signedInUser = null;
  }

  @override
  Future<AuthUser> login(
    String username,
    String password,
    UserRole selectedRole,
  ) async {
    lastSelectedRole = selectedRole;
    final error = loginError;
    if (error != null) {
      throw error;
    }
    signedInUser = AuthUser(id: '1', username: username, role: selectedRole);
    token = 'test-token';
    return signedInUser!;
  }

  @override
  Future<String?> readToken() async =>
      initialUser == null ? null : 'test-token';
}

class _FailingStartupSupervisor extends LocalBackendSupervisor {
  @override
  Future<LocalBackendSettings?> readSettings() async {
    await Future<void>.delayed(Duration.zero);
    throw const BackendStartFailure('Setup unavailable for test.');
  }
}

class FakeReceiptPrinterGateway implements ReceiptPrinterGateway {
  ReceiptPrinterSettings? printerSettings;
  final printedInvoices = <String>[];
  final builtPdfFormats =
      <({int widthMm, double printableWidthMm, bool isA4})>[];

  @override
  Future<Uint8List> buildPdf(
    SavedInvoice invoice, {
    required int paperWidthMm,
    double? printableWidthMm,
    bool testMode = false,
    bool a4Invoice = false,
  }) async {
    builtPdfFormats.add((
      widthMm: paperWidthMm,
      printableWidthMm: printableWidthMm ?? (paperWidthMm - 8).toDouble(),
      isA4: a4Invoice,
    ));
    return Uint8List(0);
  }

  @override
  Future<List<InstalledReceiptPrinter>> listPrinters() async => [];

  @override
  Future<ReceiptPrinterSettings?> loadSettings() async => printerSettings;

  @override
  Future<void> saveSettings(ReceiptPrinterSettings settings) async {}

  @override
  Future<bool> printReceipt(
    SavedInvoice invoice, {
    bool testMode = false,
    bool? a4Invoice,
    void Function(String notice)? onPrintNotice,
  }) async {
    printedInvoices.add(invoice.id);
    return true;
  }
}

void main() {
  testWidgets(
    'saved invoice history previews before printing and confirms safe void',
    (tester) async {
      final billing = FakeAuthGateway();
      billing.savedInvoices['existing'] = const SavedInvoice(
        id: '42',
        invoiceNumber: 'INV-TEST-0042',
        cashierName: 'till',
        subtotal: '25.00',
        grandTotal: '25.00',
        createdAt: '2026-10-19T12:00:00.000Z',
        items: [],
        replayed: false,
      );
      final printer = FakeReceiptPrinterGateway();

      await tester.pumpWidget(
        MaterialApp(
          home: InvoiceHistoryScreen(
            billingGateway: billing,
            printerGateway: printer,
            canManage: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('previewInvoice-42')), findsNothing);
      expect(find.byKey(const Key('printInvoice-42')), findsNothing);
      expect(find.byKey(const Key('printAgainInvoice-42')), findsOneWidget);
      await tester.tap(find.byKey(const Key('printAgainInvoice-42')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byKey(const Key('receiptPreviewDialog')), findsOneWidget);
      expect(find.byKey(const Key('printReceiptButton')), findsOneWidget);
      expect(
        find.byKey(const Key('closeReceiptPreviewButton')),
        findsOneWidget,
      );
      expect(printer.printedInvoices, isEmpty);
      await tester.tap(find.byKey(const Key('closeReceiptPreviewButton')));
      await tester.pumpAndSettle();
      expect(printer.printedInvoices, isEmpty);

      await tester.tap(find.byKey(const Key('printAgainInvoice-42')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('printReceiptButton')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('printReceiptButton')));
      await tester.pump();
      expect(printer.printedInvoices, ['42']);
      expect(
        billing.savedInvoices.values.single.invoiceNumber,
        'INV-TEST-0042',
      );
      await tester.tap(find.byKey(const Key('closeReceiptPreviewButton')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('deleteInvoice-42')));
      await tester.pumpAndSettle();
      expect(find.text('This action cannot be undone.'), findsNothing);
      expect(
        find.textContaining('It will be voided, not erased.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Keep invoice'));
      await tester.pumpAndSettle();
      expect(billing.voidedInvoiceIds, isEmpty);

      await tester.tap(find.byKey(const Key('deleteInvoice-42')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDeleteInvoiceButton-42')));
      await tester.pumpAndSettle();
      expect(billing.voidedInvoiceIds, {'42'});
      expect(
        billing.savedInvoices.values.single.invoiceNumber,
        'INV-TEST-0042',
      );
      expect(billing.invoiceListCalls, 2);
      expect(find.text('No saved invoices yet.'), findsOneWidget);
    },
  );

  testWidgets('shows invoice deletion errors and keeps the invoice listed', (
    tester,
  ) async {
    final billing = FakeAuthGateway()
      ..voidInvoiceFailure = const BillingFailure(
        'Database is unavailable.',
        statusCode: 503,
      );
    billing.savedInvoices['existing'] = const SavedInvoice(
      id: '42',
      invoiceNumber: 'INV-TEST-0042',
      cashierName: 'till',
      subtotal: '25.00',
      grandTotal: '25.00',
      createdAt: '2026-10-19T12:00:00Z',
      items: [],
      replayed: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InvoiceHistoryScreen(
          billingGateway: billing,
          printerGateway: FakeReceiptPrinterGateway(),
          canManage: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('deleteInvoice-42')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmDeleteInvoiceButton-42')));
    await tester.pumpAndSettle();

    expect(find.text('INV-TEST-0042'), findsOneWidget);
    expect(billing.voidedInvoiceIds, isEmpty);
    expect(find.text('Database is unavailable.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('deleteInvoice-42')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('shows live startup progress and a retryable client message', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AuthGate(
          authGateway: FakeAuthGateway(),
          backendSupervisor: _FailingStartupSupervisor(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Preparing your local shop database...'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.text('Setup unavailable for test.'), findsOneWidget);
    expect(find.byKey(const Key('firstRunSubmitButton')), findsOneWidget);
  });

  testWidgets('Admin and Cashier can change their own password in the app', (
    tester,
  ) async {
    for (final role in [UserRole.admin, UserRole.cashier]) {
      final gateway = FakeAuthGateway(
        initialUser: AuthUser(id: '1', username: 'staff', role: role),
      );
      await tester.pumpWidget(
        MalligaiKadaiApp(key: ValueKey(role), authGateway: gateway),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('changePasswordButton')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('currentPasswordField')),
        'current-password',
      );
      await tester.enterText(
        find.byKey(const Key('newPasswordField')),
        'new-password',
      );
      await tester.enterText(
        find.byKey(const Key('confirmPasswordField')),
        'new-password',
      );
      await tester.tap(find.byKey(const Key('submitPasswordChangeButton')));
      await tester.pumpAndSettle();

      expect(gateway.passwordChanges, [
        ['current-password', 'new-password'],
      ]);
      expect(find.text('Password changed successfully.'), findsOneWidget);
    }
  });

  test(
    'explains how to recover when the local API cannot be reached',
    () async {
      final gateway = HttpAuthGateway(
        httpClient: MockClient(
          (_) async => throw const SocketException('Connection refused'),
        ),
      );

      await expectLater(
        gateway.currentUser('saved-token'),
        throwsA(
          isA<AuthFailure>().having(
            (error) => error.message,
            'message',
            'Thanigai Stores could not connect to its local services. Select '
                'Retry, or close and reopen the app. Your shop data has not '
                'been deleted.',
          ),
        ),
      );
    },
  );

  testWidgets(
    'shows client-friendly recovery when a saved session is offline',
    (tester) async {
      final gateway = FakeAuthGateway(
        initialUser: const AuthUser(
          id: '1',
          username: 'admin',
          role: UserRole.admin,
        ),
        currentUserError: const AuthFailure(
          0,
          'Thanigai Stores could not connect to its local services. Select Retry, '
          'or close and reopen the app. Your shop data has not been deleted.',
        ),
      );

      await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('could not connect to its local services'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Clear saved sign-in'), findsOneWidget);
    },
  );

  testWidgets('shows a username and password login with hidden password', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _StandaloneLoginScreen()));

    expect(find.text('THANIGAI STORES'), findsOneWidget);
    expect(find.text('Grocery Billing System'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('passwordField')),
              matching: find.byType(EditableText),
            ),
          )
          .obscureText,
      isTrue,
    );
  });

  testWidgets('toggles password visibility', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _StandaloneLoginScreen()));

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('passwordField')),
              matching: find.byType(EditableText),
            ),
          )
          .obscureText,
      isFalse,
    );
  });

  testWidgets('routes an existing admin session and logs out', (tester) async {
    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '1',
        username: 'owner',
        role: UserRole.admin,
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();

    expect(find.text('Admin Home'), findsOneWidget);
    expect(find.text('Welcome, owner'), findsOneWidget);
    await tester.tap(find.byKey(const Key('logoutButton')));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('resume preserves a live session and clears an expired one', (
    tester,
  ) async {
    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '1',
        username: 'owner',
        role: UserRole.admin,
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Admin Home'), findsOneWidget);
    expect(find.byKey(const Key('openProductsButton')), findsOneWidget);

    gateway.currentUserError = const AuthFailure(401, 'Token expired.');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('admin can create a cashier login from the home screen', (
    tester,
  ) async {
    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '1',
        username: 'owner',
        role: UserRole.admin,
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('createCashierButton')));
    await tester.pumpAndSettle();
    expect(find.text('Create cashier login'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('cashierUsernameField')), 'a');
    await tester.enterText(
      find.byKey(const Key('cashierPasswordField')),
      'A-strong-cashier-password',
    );
    await tester.tap(find.byKey(const Key('saveCashierButton')));
    await tester.pumpAndSettle();
    expect(gateway.createdCashiers, isEmpty);
    expect(
      find.text('Use 2–64 letters, numbers, dots, _ or -.'),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const Key('cashierUsernameField')), 'ab');
    await tester.tap(find.byKey(const Key('saveCashierButton')));
    await tester.pumpAndSettle();

    expect(gateway.createdCashiers['ab'], 'A-strong-cashier-password');
    expect(find.text('Cashier login created for ab.'), findsOneWidget);
  });

  testWidgets('Admin can add a product and cashier can only view products', (
    tester,
  ) async {
    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '1',
        username: 'owner',
        role: UserRole.admin,
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('openProductsButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('addProductButton')), findsOneWidget);
    await tester.tap(find.byKey(const Key('addProductButton')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('productNameField')),
      'Basmati Rice',
    );
    expect(find.byKey(const Key('productSkuField')), findsNothing);
    expect(find.byKey(const Key('productCategoryField')), findsNothing);
    expect(find.byKey(const Key('productPurchasePriceField')), findsOneWidget);
    expect(find.text('Price per kg / litre (₹)'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('productQuantityField')),
      '100',
    );
    await tester.enterText(
      find.byKey(const Key('productPurchasePriceField')),
      '50.00',
    );
    await tester.enterText(
      find.byKey(const Key('productOpeningStockQuantityField')),
      '1000',
    );
    await tester.enterText(
      find.byKey(const Key('productSellingPriceField')),
      '8.00',
    );
    expect(find.byKey(const Key('productStockField')), findsNothing);
    expect(find.byKey(const Key('productThresholdField')), findsNothing);
    expect(find.byKey(const Key('productGstField')), findsNothing);
    await tester.tap(find.byKey(const Key('saveProductButton')));
    await tester.pumpAndSettle();

    expect(find.text('Basmati Rice'), findsOneWidget);
    expect(find.text('Sell ₹8.00 / 100 g'), findsOneWidget);
    expect(find.text('Buy ₹50.00'), findsOneWidget);
    expect(gateway.productItems.single.openingStockQuantity, '1000');

    await tester.tap(find.byKey(const Key('editProduct-10')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('productSellingPriceField')),
      '10.00',
    );
    await tester.tap(find.byKey(const Key('saveProductButton')));
    await tester.pumpAndSettle();
    expect(find.text('Sell ₹10.00 / 100 g'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    gateway.initialUser = const AuthUser(
      id: '2',
      username: 'till',
      role: UserRole.cashier,
    );
    await tester.pumpWidget(
      MalligaiKadaiApp(
        key: const ValueKey('cashierSession'),
        authGateway: gateway,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openProductsButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('addProductButton')), findsNothing);
    expect(find.byKey(const Key('editProduct-10')), findsNothing);
    expect(find.text('Basmati Rice'), findsOneWidget);
    expect(find.text('Buy ₹80.00'), findsNothing);
  });

  testWidgets('product page offers add, delete and Excel import actions', (
    tester,
  ) async {
    final gateway = FakeAuthGateway();
    await tester.pumpWidget(
      MaterialApp(home: ProductScreen(canManage: true, gateway: gateway)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('importProductsXlsxButton')), findsOneWidget);
    expect(find.text('Import from Excel'), findsOneWidget);
    expect(find.byKey(const Key('addProductButton')), findsOneWidget);
    expect(find.byKey(const Key('deleteProductButton')), findsOneWidget);
    expect(find.byKey(const Key('exportProductsXlsxButton')), findsOneWidget);
  });

  testWidgets('Admin can soft-delete a product from the product list', (
    tester,
  ) async {
    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '1',
        username: 'owner',
        role: UserRole.admin,
      ),
    );
    gateway.productItems.add(
      const ProductItem(
        id: '22',
        name: 'Green Gram',
        sku: 'DAL-022',
        category: 'Pulses',
        unit: 'kg',
        purchasePrice: '50.00',
        sellingPrice: '60.00',
        gstRate: '5.00',
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openProductsButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('deleteProductButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('selectProductToDelete-22')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Invoice and financial history will be preserved.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('confirmDeleteProductButton')));
    await tester.pumpAndSettle();

    expect(gateway.removedProductIds, contains('22'));
    expect(find.text('Green Gram'), findsNothing);
  });

  testWidgets(
    'Admin can edit a selling price without changing product details',
    (tester) async {
      final gateway = FakeAuthGateway(
        initialUser: const AuthUser(
          id: '1',
          username: 'owner',
          role: UserRole.admin,
        ),
      );
      gateway.productItems.add(
        const ProductItem(
          id: '23',
          name: 'Toor Dal',
          sku: '',
          category: 'Pulses',
          unit: 'kg',
          purchasePrice: '50.00',
          sellingPrice: '60.00',
          gstRate: '5.00',
        ),
      );
      await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('openProductsButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('editSellingPrice-23')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sellingPriceQuickEditField')),
        '72.50',
      );
      await tester.tap(find.byKey(const Key('saveSellingPriceButton')));
      await tester.pumpAndSettle();

      final updated = gateway.productItems.single;
      expect(updated.sellingPrice, '72.50');
      expect(updated.name, 'Toor Dal');
      expect(updated.sku, '');
    },
  );

  testWidgets('both roles can build a cart and save an invoice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '2',
        username: 'till',
        role: UserRole.cashier,
      ),
    );
    gateway.productItems.add(
      const ProductItem(
        id: '31',
        name: 'Red Apple',
        sku: 'FRUIT-31',
        category: 'Fruit',
        unit: 'kg',
        purchasePrice: null,
        sellingPrice: '2.50',
        gstRate: '0.00',
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openBillingButton')));
    await tester.pumpAndSettle();

    expect(find.text('Red Apple'), findsOneWidget);
    await tester.tap(find.byKey(const Key('addToCart-31')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('newQuantityUnit-31')),
          )
          .initialValue,
      'kg',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('newQuantityInput-31')))
          .controller!
          .text,
      '1',
    );
    await tester.enterText(find.byKey(const Key('newQuantityInput-31')), '0.1');
    await tester.tap(find.byKey(const Key('confirmProductQuantity-31')));
    await tester.pumpAndSettle();
    expect(find.text('₹2.50 / 1 kg'), findsOneWidget);
    expect(find.byKey(const Key('quantityInput-31-kg')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('summary-subtotal'))).data,
      '₹0.25',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('summary-finaltotal'))).data,
      '₹0.25',
    );
    await tester.enterText(find.byKey(const Key('quantityInput-31-kg')), '0.2');
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('summary-subtotal'))).data,
      '₹0.50',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('summary-finaltotal'))).data,
      '₹0.50',
    );

    await tester.tap(find.byKey(const Key('paymentModeField')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Split payment'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('payment-cash')), '0.20');
    await tester.enterText(find.byKey(const Key('payment-upi')), '0.20');
    await tester.tap(find.byKey(const Key('saveInvoiceButton')));
    await tester.pumpAndSettle();
    expect(find.text('Payment total must equal ₹0.50.'), findsOneWidget);
    expect(gateway.lastInvoiceKey, isNull);

    await tester.enterText(find.byKey(const Key('payment-upi')), '0.30');
    await tester.tap(find.byKey(const Key('saveInvoiceButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('INV-TEST-0001'), findsOneWidget);
    expect(find.byKey(const Key('printSavedInvoiceButton')), findsOneWidget);
    expect(find.byKey(const Key('previewSavedInvoiceButton')), findsOneWidget);
    expect(find.text('Print Invoice'), findsOneWidget);
    expect(find.text('Preview Invoice'), findsOneWidget);
    expect(find.text('Later'), findsNothing);
    expect(gateway.lastInvoiceKey, isNotNull);
    expect(gateway.lastInvoiceKey, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(gateway.lastSaleStateCode, '33');
    expect(gateway.lastPayments!.map((payment) => payment.method), [
      'cash',
      'upi',
    ]);
    expect(gateway.lastPayments!.map((payment) => payment.amount), [
      '0.20',
      '0.30',
    ]);
  });

  testWidgets('saved invoice dialog previews and prints without saving again', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final billing = FakeAuthGateway();
    billing.productItems.add(
      const ProductItem(
        id: '90',
        name: 'Tea',
        sku: 'TEA-90',
        category: 'Drinks',
        unit: 'piece',
        purchasePrice: '1.00',
        sellingPrice: '2.50',
        gstRate: '0.00',
      ),
    );
    final printer = FakeReceiptPrinterGateway()
      ..printerSettings = const ReceiptPrinterSettings(
        printerName: 'Thermal',
        printerUrl: 'windows:thermal',
        paperWidthMm: 80,
        printableWidthMm: 72,
      );

    await tester.pumpWidget(
      MaterialApp(
        home: BillingScreen(
          productGateway: billing,
          billingGateway: billing,
          receiptPrinterGateway: printer,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('billingSearchField')), 'Tea');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addToCart-90')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('newQuantityInput-90')), '1');
    await tester.tap(find.byKey(const Key('confirmProductQuantity-90')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveInvoiceButton')));
    await tester.pumpAndSettle();

    expect(billing.savedInvoices, hasLength(1));
    await tester.tap(find.byKey(const Key('previewSavedInvoiceButton')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(const Key('receiptPreviewDialog')), findsOneWidget);
    expect(find.byKey(const Key('printReceiptButton')), findsOneWidget);
    expect(find.byKey(const Key('closeReceiptPreviewButton')), findsOneWidget);
    expect(billing.savedInvoices, hasLength(1));
    expect(printer.printedInvoices, isEmpty);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('printReceiptButton')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('printReceiptButton')));
    await tester.pump();
    expect(printer.printedInvoices, ['1']);
    expect(billing.savedInvoices, hasLength(1));
  });

  testWidgets('weight quantities default by unit and use the kg price once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '2',
        username: 'till',
        role: UserRole.cashier,
      ),
    );
    gateway.productItems.add(
      const ProductItem(
        id: '34',
        name: 'Rice',
        sku: 'RICE-34',
        category: 'Grains',
        unit: 'kg',
        purchasePrice: null,
        sellingPrice: '80.00',
        gstRate: '0.00',
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openBillingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addToCart-34')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('newQuantityUnit-34')),
          )
          .initialValue,
      'kg',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('newQuantityInput-34')))
          .controller!
          .text,
      '1',
    );
    await tester.tap(find.byKey(const Key('newQuantityUnit-34')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('g').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('newQuantityInput-34')))
          .controller!
          .text,
      '100',
    );
    await tester.enterText(find.byKey(const Key('newQuantityInput-34')), '200');
    await tester.tap(find.byKey(const Key('confirmProductQuantity-34')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('lineTotal-34'))).data,
      '₹16.00',
    );

    await tester.tap(find.byKey(const Key('addToCart-34')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('newQuantityUnit-34')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('g').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('newQuantityInput-34')))
          .controller!
          .text,
      '100',
    );
    await tester.enterText(find.byKey(const Key('newQuantityInput-34')), '100');
    await tester.tap(find.byKey(const Key('confirmProductQuantity-34')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('lineTotal-34'))).data,
      '₹24.00',
    );

    await tester.tap(find.byKey(const Key('addToCart-34')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('newQuantityUnit-34')),
          )
          .initialValue,
      'kg',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('newQuantityInput-34')))
          .controller!
          .text,
      '1',
    );
    await tester.tap(find.byKey(const Key('confirmProductQuantity-34')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('summary-subtotal'))).data,
      '₹104.00',
    );
    await tester.tap(find.byKey(const Key('saveInvoiceButton')));
    await tester.pumpAndSettle();
    expect(gateway.lastInvoiceItems.single.quantity, '1.300');
  });

  testWidgets('configured selling quantity prices proportional weight sales', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '2',
        username: 'till',
        role: UserRole.cashier,
      ),
    );
    gateway.productItems.add(
      const ProductItem(
        id: '42',
        name: 'Rice',
        sku: '',
        category: 'General',
        unit: 'g',
        sellingPrice: '8.00',
        sellingQuantity: '100.000',
        gstRate: '0.00',
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openBillingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addToCart-42')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('newQuantityInput-42')), '250');
    await tester.tap(find.byKey(const Key('confirmProductQuantity-42')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('lineTotal-42'))).data,
      '₹20.00',
    );
    await tester.tap(find.byKey(const Key('saveInvoiceButton')));
    await tester.pumpAndSettle();
    expect(gateway.lastInvoiceItems.single.quantity, '250.000');
  });

  testWidgets('configured volume prices convert ml sales to litres', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '2',
        username: 'till',
        role: UserRole.cashier,
      ),
    );
    gateway.productItems.add(
      const ProductItem(
        id: '43',
        name: 'Oil',
        sku: '',
        category: 'General',
        unit: 'ml',
        sellingPrice: '60.00',
        sellingQuantity: '500.000',
        gstRate: '0.00',
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openBillingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addToCart-43')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('newQuantityInput-43')))
          .controller!
          .text,
      '100',
    );
    await tester.tap(find.byKey(const Key('newQuantityUnit-43')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('litre').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('newQuantityInput-43')), '1');
    await tester.tap(find.byKey(const Key('confirmProductQuantity-43')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('lineTotal-43'))).data,
      '₹120.00',
    );
    await tester.tap(find.byKey(const Key('saveInvoiceButton')));
    await tester.pumpAndSettle();
    expect(gateway.lastInvoiceItems.single.quantity, '1000.000');
  });

  testWidgets(
    'billing applies discount before Settings GST in inclusive mode',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final gateway = FakeAuthGateway(
        initialUser: const AuthUser(
          id: '2',
          username: 'till',
          role: UserRole.cashier,
        ),
      );
      gateway.gstEnabled = true;
      gateway.gstRate = '5.00';
      gateway.gstPriceMode = 'inclusive';
      gateway.productItems.add(
        const ProductItem(
          id: '32',
          name: 'GST Apple',
          sku: 'FRUIT-32',
          category: 'Fruit',
          unit: 'piece',
          purchasePrice: null,
          sellingPrice: '2.50',
          gstRate: '5.00',
        ),
      );
      await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('openBillingButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('addToCart-32')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('newQuantityInput-32')), '1');
      await tester.tap(find.byKey(const Key('confirmProductQuantity-32')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('manualGstAmountField')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('discountAmountField')),
        '0.50',
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('summary-subtotal'))).data,
        '₹2.50',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('summary-amountbeforegst')))
            .data,
        '₹1.90',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('summary-discount'))).data,
        '₹0.50',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('summary-gst'))).data,
        '₹0.10',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('summary-finaltotal'))).data,
        '₹2.00',
      );
    },
  );

  testWidgets('billing accepts fractional packet quantities', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '2',
        username: 'till',
        role: UserRole.cashier,
      ),
    );
    gateway.productItems.add(
      const ProductItem(
        id: '35',
        name: 'Papad Pack',
        sku: 'PAPAD-35',
        category: 'Snacks',
        unit: 'packet',
        purchasePrice: null,
        sellingPrice: '2.50',
        gstRate: '0.00',
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openBillingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addToCart-35')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('newQuantityInput-35')), '1.5');
    await tester.tap(find.byKey(const Key('confirmProductQuantity-35')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('lineTotal-35'))).data,
      '₹3.75',
    );

    await tester.tap(find.byKey(const Key('saveInvoiceButton')));
    await tester.pumpAndSettle();
    expect(gateway.lastInvoiceItems.single.quantity, '1.500');
    expect(find.textContaining('Not enough'), findsNothing);
  });

  testWidgets('billing calculates GST from the saved Settings rate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway =
        FakeAuthGateway(
            initialUser: const AuthUser(
              id: '2',
              username: 'till',
              role: UserRole.cashier,
            ),
          )
          ..gstEnabled = true
          ..gstRate = '5.00';
    gateway.productItems.add(
      const ProductItem(
        id: '33',
        name: 'GST Tea',
        sku: 'TEA-33',
        category: 'Drinks',
        unit: 'piece',
        purchasePrice: null,
        sellingPrice: '2.50',
        gstRate: '5.00',
      ),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openBillingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addToCart-33')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('newQuantityInput-33')), '1');
    await tester.tap(find.byKey(const Key('confirmProductQuantity-33')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('amount-33')), '10.00');
    expect(find.byKey(const Key('manualGstAmountField')), findsNothing);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('summary-amountbeforegst')))
          .data,
      '₹10.00',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('summary-finaltotal'))).data,
      '₹10.50',
    );
  });

  testWidgets('saved invoice preview uses the compact receipt-roll layout', (
    tester,
  ) async {
    const invoice = SavedInvoice(
      id: '91',
      invoiceNumber: 'INV-SAVED-00000091',
      cashierName: 'till',
      subtotal: '3.00',
      grandTotal: '3.00',
      createdAt: '2026-10-19T12:30:00.000Z',
      items: [],
      payments: [InvoicePayment(method: 'cash', amount: '3.00')],
      replayed: false,
    );
    final printer = FakeReceiptPrinterGateway();
    printer.printerSettings = const ReceiptPrinterSettings(
      printerName: 'Thermal',
      printerUrl: 'windows:thermal',
      paperWidthMm: 80,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReceiptPreviewScreen(invoice: invoice, printerGateway: printer),
      ),
    );
    await tester.pump();

    final dialog = tester.widget<Dialog>(
      find.byKey(const Key('receiptPreviewDialog')),
    );
    expect(dialog.backgroundColor, const Color(0xFFF1EEE8));
    expect(find.byKey(const Key('closeReceiptPreviewButton')), findsOneWidget);
    expect(find.byKey(const Key('saveInvoicePdfButton')), findsOneWidget);
    expect(find.byKey(const Key('printReceiptButton')), findsOneWidget);
    final preview = tester.widget<PdfPreview>(
      find.byKey(const Key('receiptPdfPreview')),
    );
    final initialFormat = preview.initialPageFormat;
    expect(initialFormat, isNotNull);
    expect(initialFormat!.width, closeTo(80 * PdfPageFormat.mm, 0.01));
    expect(preview.pageFormats.keys, ['80 mm roll / 72.0 mm target']);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      printer.builtPdfFormats,
      contains((widthMm: 80, printableWidthMm: 72, isA4: false)),
    );
    expect(printer.printedInvoices, isEmpty);
  });

  testWidgets('routes a cashier to the cashier home after login', (
    tester,
  ) async {
    final gateway = FakeAuthGateway();
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('usernameField')), 'cashier');
    await tester.enterText(
      find.byKey(const Key('passwordField')),
      'test-password',
    );
    await tester.tap(find.text('Cashier'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pumpAndSettle();

    expect(find.text('Cashier Home'), findsOneWidget);
    expect(find.text('Welcome, cashier'), findsOneWidget);
    expect(gateway.lastSelectedRole, UserRole.cashier);
    expect(
      find.byKey(const Key('cashierPrimaryNewBillButton')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('openProductsButton')), findsOneWidget);
    expect(find.byKey(const Key('openInvoiceHistoryButton')), findsOneWidget);
    expect(find.byKey(const Key('openSettingsButton')), findsNothing);
    expect(gateway.dashboardCalls, 0);
  });

  testWidgets('admin dashboard uses live reports and admin-only navigation', (
    tester,
  ) async {
    final gateway =
        FakeAuthGateway(
            initialUser: const AuthUser(
              id: '1',
              username: 'owner',
              role: UserRole.admin,
            ),
          )
          ..dashboardData = const DashboardData(
            date: '2026-05-12',
            totalSales: '1350.50',
            invoiceCount: 7,
            stockProductCount: 23,
            paymentSummary: [
              PaymentSummary(method: 'Cash', invoiceCount: 4, amount: '850.50'),
            ],
          );

    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();

    expect(find.text('₹ 1350.50'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('23'), findsOneWidget);
    expect(find.text('Stocks'), findsOneWidget);
    expect(find.text('₹ 850.50'), findsOneWidget);
    expect(find.byKey(const Key('openReportsButton')), findsOneWidget);
    expect(find.byKey(const Key('changePasswordButton')), findsOneWidget);
    expect(find.byKey(const Key('openDatabaseBackupButton')), findsNothing);
    expect(find.byKey(const Key('openSettingsButton')), findsOneWidget);
    expect(
      find.byKey(const Key('openReceiptPrinterSettingsButton')),
      findsNothing,
    );
    final storeTitle = tester.widget<Text>(
      find.byKey(const Key('mainStoreTitle')),
    );
    expect(storeTitle.textAlign, TextAlign.center);
    expect(
      tester.getCenter(find.byKey(const Key('mainStoreTitle'))).dx,
      closeTo(400, 1),
    );
    expect(gateway.dashboardCalls, 1);
    await tester.tap(find.byKey(const Key('openSettingsButton')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('gstEnabledSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsGstRateField')), findsOneWidget);
    expect(find.byKey(const Key('businessPhoneField')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('settingsGstRateField')), '18');
    await tester.ensureVisible(find.byKey(const Key('saveGstSettingsButton')));
    await tester.tap(find.byKey(const Key('saveGstSettingsButton')));
    await tester.pumpAndSettle();
    expect(gateway.gstRate, '18');
  });

  testWidgets('dashboard adapts between desktop sidebar and mobile drawer', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(
        id: '1',
        username: 'owner',
        role: UserRole.admin,
      ),
    );

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();
    expect(find.text('Cashier Management'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(600, 900);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Open navigation'), findsOneWidget);
    expect(find.text('Cashier Management'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Open navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Cashier Management'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows login errors without leaving the login screen', (
    tester,
  ) async {
    final gateway = FakeAuthGateway(
      loginError: const AuthFailure(401, 'Invalid username or password.'),
    );
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: gateway));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('usernameField')), 'owner');
    await tester.enterText(
      find.byKey(const Key('passwordField')),
      'wrong-password',
    );
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('loginError')), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}

class _StandaloneLoginScreen extends StatelessWidget {
  const _StandaloneLoginScreen();

  @override
  Widget build(BuildContext context) {
    return LoginScreen(
      onLogin: (username, _, role) async =>
          AuthUser(id: '1', username: username, role: role),
    );
  }
}
