import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../billing/billing_gateway.dart';
import '../products/product_gateway.dart';
import '../reports/reports_gateway.dart';

const _localApiUnavailableMessage =
    'Thanigai Stores could not connect to its local services. Select Retry, or close and reopen the app. Your shop data has not been deleted.';

enum UserRole { admin, cashier }

class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.role,
  });

  final String id;
  final String username;
  final UserRole role;

  factory AuthUser.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['id'] == null ||
        json['username'] is! String ||
        (json['role'] != 'admin' && json['role'] != 'cashier')) {
      throw const AuthFailure(
        0,
        'The API returned an invalid account response.',
      );
    }

    return AuthUser(
      id: json['id'].toString(),
      username: json['username'] as String,
      role: json['role'] == 'admin' ? UserRole.admin : UserRole.cashier,
    );
  }
}

class AuthFailure implements Exception {
  const AuthFailure(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

abstract interface class AuthGateway
    implements ProductGateway, BillingGateway, ReportsGateway {
  Future<String?> readToken();
  Future<AuthUser> login(String username, String password, UserRole role);
  Future<void> changePassword(String currentPassword, String newPassword);
  Future<AuthUser> currentUser(String token);
  Future<AuthUser> createCashier(String username, String password);
  Future<void> clearToken();
}

class HttpAuthGateway implements AuthGateway, StockGateway {
  HttpAuthGateway({
    String baseUrl = const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://127.0.0.1:3000',
    ),
    FlutterSecureStorage? secureStorage,
    http.Client? httpClient,
  }) : _baseUri = Uri.parse(baseUrl),
       _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _httpClient = httpClient ?? http.Client(),
       _products = HttpProductGateway(
         baseUrl: baseUrl,
         secureStorage: secureStorage,
         httpClient: httpClient,
       ),
       _billing = HttpBillingGateway(
         baseUrl: baseUrl,
         secureStorage: secureStorage,
         httpClient: httpClient,
       ),
       _reports = HttpReportsGateway(
         baseUrl: baseUrl,
         secureStorage: secureStorage,
         httpClient: httpClient,
       );

  static const _tokenKey = 'malligai_kadai_access_token';

  final Uri _baseUri;
  final FlutterSecureStorage _secureStorage;
  final http.Client _httpClient;
  final HttpProductGateway _products;
  final BillingGateway _billing;
  final ReportsGateway _reports;

  @override
  Future<String?> readToken() async {
    try {
      return await _secureStorage.read(key: _tokenKey);
    } catch (_) {
      throw const AuthFailure(
        0,
        'Could not read the saved sign-in from Windows secure storage.',
      );
    }
  }

  @override
  Future<void> clearToken() async {
    try {
      await _secureStorage.delete(key: _tokenKey);
    } catch (_) {
      throw const AuthFailure(
        0,
        'Could not clear the saved sign-in from Windows secure storage.',
      );
    }
  }

  @override
  Future<AuthUser> login(
    String username,
    String password,
    UserRole role,
  ) async {
    final response = await _send(
      _httpClient.post(
        _baseUri.resolve('/auth/login'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'role': role.name,
        }),
      ),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      throw AuthFailure(
        response.statusCode,
        body['message'] as String? ?? 'Sign-in failed. Please try again.',
      );
    }

    final token = body['token'];
    if (token is! String || token.isEmpty) {
      throw const AuthFailure(
        0,
        'The API did not return a valid sign-in token.',
      );
    }

    final user = AuthUser.fromJson(body['user']);
    try {
      await _secureStorage.write(key: _tokenKey, value: token);
    } catch (_) {
      throw const AuthFailure(
        0,
        'Sign-in succeeded, but this device could not securely save the session.',
      );
    }
    return user;
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    final token = await readToken();
    if (token == null || token.isEmpty) {
      throw const AuthFailure(401, 'Sign in again to change your password.');
    }
    final response = await _send(
      _httpClient.post(
        _baseUri.resolve('/auth/password'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'currentPassword': currentPassword,
          'newPassword': newPassword,
        }),
      ),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      throw AuthFailure(
        response.statusCode,
        body['message'] as String? ?? 'Could not change the password.',
      );
    }
  }

  @override
  Future<AuthUser> currentUser(String token) async {
    final response = await _send(
      _httpClient.get(
        _baseUri.resolve('/auth/me'),
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      throw AuthFailure(
        response.statusCode,
        body['message'] as String? ?? 'Your saved sign-in is no longer valid.',
      );
    }
    return AuthUser.fromJson(body['user']);
  }

  @override
  Future<AuthUser> createCashier(String username, String password) async {
    final token = await readToken();
    if (token == null || token.isEmpty) {
      throw const AuthFailure(401, 'Sign in as an Admin to create a Cashier.');
    }

    final response = await _send(
      _httpClient.post(
        _baseUri.resolve('/admin/cashiers'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'username': username, 'password': password}),
      ),
    );
    final body = _decode(response);
    if (response.statusCode != 201) {
      throw AuthFailure(
        response.statusCode,
        body['message'] as String? ?? 'Could not create the Cashier login.',
      );
    }

    return AuthUser.fromJson(body['user']);
  }

  @override
  Future<List<ProductItem>> searchProducts(String search) {
    return _products.searchProducts(search);
  }

  @override
  Future<ProductItem> createProduct(ProductDraft product) {
    return _products.createProduct(product);
  }

  @override
  Future<ProductItem> updateProduct(String id, ProductDraft product) {
    return _products.updateProduct(id, product);
  }

  @override
  Future<void> deleteProduct(String id) {
    return _products.deleteProduct(id);
  }

  @override
  Future<List<StockProduct>> loadStocks() => _products.loadStocks();

  @override
  Future<StockProduct> updateOpeningStock(
    String productId,
    String quantity,
    String purchasePrice,
  ) => _products.updateOpeningStock(productId, quantity, purchasePrice);

  @override
  Future<StockProduct> receiveStockPurchase(
    String productId,
    String quantity,
    String purchasePrice,
    String purchaseDate,
  ) => _products.receiveStockPurchase(
    productId,
    quantity,
    purchasePrice,
    purchaseDate,
  );

  @override
  Future<GstSettings> getGstSettings() => _billing.getGstSettings();

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
  }) => _billing.updateGstSettings(
    gstEnabled: gstEnabled,
    gstRate: gstRate,
    priceMode: priceMode,
    stateCode: stateCode,
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
  }) {
    return _billing.createInvoice(
      idempotencyKey: idempotencyKey,
      items: items,
      saleStateCode: saleStateCode,
      discountAmount: discountAmount,
      gstAmount: gstAmount,
      payments: payments,
    );
  }

  @override
  Future<List<SavedInvoice>> listInvoices({int limit = 50}) =>
      _billing.listInvoices(limit: limit);

  @override
  Future<SavedInvoice> findInvoiceById(String id) =>
      _billing.findInvoiceById(id);

  @override
  Future<void> voidInvoice(String id) => _billing.voidInvoice(id);

  @override
  Future<DashboardData> dashboard(DateTime date) => _reports.dashboard(date);

  @override
  Future<SalesReportData> sales(DateTime start, DateTime end) =>
      _reports.sales(start, end);

  @override
  Future<List<DatabaseBackup>> listBackups() => _reports.listBackups();

  @override
  Future<DatabaseBackup> createBackup() => _reports.createBackup();

  @override
  Future<void> restoreBackup(DatabaseBackup backup, String confirmation) =>
      _reports.restoreBackup(backup, confirmation);

  Future<http.Response> _send(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw const AuthFailure(0, _localApiUnavailableMessage);
    } on SocketException {
      throw const AuthFailure(0, _localApiUnavailableMessage);
    } on http.ClientException {
      throw const AuthFailure(0, _localApiUnavailableMessage);
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      throw const AuthFailure(0, 'The API returned an invalid response.');
    }
    throw const AuthFailure(0, 'The API returned an invalid response.');
  }
}
