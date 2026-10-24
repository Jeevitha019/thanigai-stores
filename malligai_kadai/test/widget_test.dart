import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:malligai_kadai/billing/billing_gateway.dart';
import 'package:malligai_kadai/auth/auth_gateway.dart';
import 'package:malligai_kadai/main.dart';
import 'package:malligai_kadai/products/product_gateway.dart';
import 'package:malligai_kadai/reports/reports_gateway.dart';

void main() {
  testWidgets('shows the login screen when there is no saved session', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(MalligaiKadaiApp(authGateway: _EmptyAuthGateway()));
    await tester.pumpAndSettle();

    expect(find.text('THANIGAI STORES'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/thanigai_stores_logo.png',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.text('THANIGAI STORES')).textAlign,
      TextAlign.center,
    );
    expect(find.text('Grocery Billing System'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}

class _EmptyAuthGateway implements AuthGateway {
  @override
  Future<GstSettings> getGstSettings() async => GstSettings(
    gstEnabled: false,
    priceMode: 'exclusive',
    stateCode: '00',
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
    gstEnabled: gstEnabled,
    gstRate: gstRate,
    priceMode: priceMode,
    stateCode: stateCode,
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
    throw const BillingFailure('Not authorized.');
  }

  @override
  Future<List<SavedInvoice>> listInvoices({int limit = 50}) async => [];

  @override
  Future<SavedInvoice> findInvoiceById(String id) async {
    throw const BillingFailure('Invoice not found.', statusCode: 404);
  }

  @override
  Future<void> voidInvoice(String id) async {
    throw const BillingFailure('Not authorized.', statusCode: 403);
  }

  @override
  Future<List<ProductItem>> searchProducts(String search) async => [];

  @override
  Future<ProductItem> createProduct(ProductDraft product) async {
    throw const ProductFailure('Not authorized.');
  }

  @override
  Future<ProductItem> updateProduct(String id, ProductDraft product) async {
    throw const ProductFailure('Not authorized.');
  }

  @override
  Future<void> deleteProduct(String id) async {
    throw const ProductFailure('Not authorized.');
  }

  @override
  Future<DashboardData> dashboard(DateTime date) async =>
      throw UnimplementedError('Dashboard is not used in this test.');

  @override
  Future<SalesReportData> sales(DateTime start, DateTime end) async =>
      throw UnimplementedError('Reports are not used in this test.');

  @override
  Future<List<DatabaseBackup>> listBackups() async =>
      throw UnimplementedError('Backups are not used in this test.');

  @override
  Future<DatabaseBackup> createBackup() async =>
      throw UnimplementedError('Backups are not used in this test.');

  @override
  Future<void> restoreBackup(
    DatabaseBackup backup,
    String confirmation,
  ) async => throw UnimplementedError('Backups are not used in this test.');

  @override
  Future<AuthUser> currentUser(String token) async {
    throw const AuthFailure(401, 'Authentication required.');
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {}

  @override
  Future<AuthUser> createCashier(String username, String password) async {
    throw const AuthFailure(403, 'Only an Admin can create a Cashier login.');
  }

  @override
  Future<void> clearToken() async {}

  @override
  Future<AuthUser> login(
    String username,
    String password,
    UserRole role,
  ) async {
    throw const AuthFailure(401, 'Invalid username or password.');
  }

  @override
  Future<String?> readToken() async => null;
}
