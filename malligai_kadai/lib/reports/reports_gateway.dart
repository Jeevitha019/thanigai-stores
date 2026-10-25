import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class ReportsFailure implements Exception {
  const ReportsFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class PaymentSummary {
  const PaymentSummary({
    required this.method,
    required this.invoiceCount,
    required this.amount,
  });

  final String method;
  final int invoiceCount;
  final String amount;

  factory PaymentSummary.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['method'] is! String ||
        value['invoiceCount'] is! num ||
        value['amount'] == null) {
      throw const ReportsFailure('The API returned invalid payment totals.');
    }
    return PaymentSummary(
      method: value['method'] as String,
      invoiceCount: (value['invoiceCount'] as num).toInt(),
      amount: value['amount'].toString(),
    );
  }
}

class DashboardData {
  const DashboardData({
    required this.date,
    required this.totalSales,
    required this.invoiceCount,
    required this.stockProductCount,
    required this.paymentSummary,
  });

  final String date;
  final String totalSales;
  final int invoiceCount;
  final int stockProductCount;
  final List<PaymentSummary> paymentSummary;

  factory DashboardData.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['date'] is! String ||
        value['totalSales'] == null ||
        value['invoiceCount'] is! num ||
        value['stockProductCount'] is! num ||
        value['paymentSummary'] is! List) {
      throw const ReportsFailure('The API returned invalid dashboard totals.');
    }
    return DashboardData(
      date: value['date'] as String,
      totalSales: value['totalSales'].toString(),
      invoiceCount: (value['invoiceCount'] as num).toInt(),
      stockProductCount: (value['stockProductCount'] as num).toInt(),
      paymentSummary: (value['paymentSummary'] as List)
          .map(PaymentSummary.fromJson)
          .toList(growable: false),
    );
  }
}

class ReportInvoiceItem {
  const ReportInvoiceItem({
    required this.productName,
    required this.sku,
    this.unit = '',
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });

  final String productName;
  final String sku;
  final String unit;
  final String quantity;
  final String unitPrice;
  final String lineTotal;

  factory ReportInvoiceItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ReportsFailure('The API returned an invalid report item.');
    }
    String text(String key) {
      final item = value[key];
      if (item == null || item is Map || item is List) {
        throw const ReportsFailure('The API returned an invalid report item.');
      }
      return item.toString();
    }

    return ReportInvoiceItem(
      productName: text('productName'),
      sku: value['sku']?.toString() ?? '',
      unit: value['unit']?.toString() ?? '',
      quantity: text('quantity'),
      unitPrice: text('unitPrice'),
      lineTotal: text('lineTotal'),
    );
  }
}

class SalesInvoiceReport {
  const SalesInvoiceReport({
    required this.id,
    required this.invoiceNumber,
    required this.cashierName,
    required this.createdAt,
    this.paidAt = '',
    this.gstEnabled = false,
    required this.subtotal,
    this.discountAmount = '0.00',
    required this.totalTax,
    required this.grandTotal,
    required this.paymentMethods,
    required this.items,
  });

  final String id;
  final String invoiceNumber;
  final String cashierName;
  final String createdAt;
  final String paidAt;
  final bool gstEnabled;
  final String subtotal;
  final String discountAmount;
  final String totalTax;
  final String grandTotal;
  final List<({String method, String amount})> paymentMethods;
  final List<ReportInvoiceItem> items;

  factory SalesInvoiceReport.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['paymentMethods'] is! List ||
        value['items'] is! List) {
      throw const ReportsFailure('The API returned an invalid report invoice.');
    }
    String text(String key) {
      final item = value[key];
      if (item == null || item is Map || item is List) {
        throw const ReportsFailure(
          'The API returned an invalid report invoice.',
        );
      }
      return item.toString();
    }

    final payments = (value['paymentMethods'] as List)
        .map((payment) {
          if (payment is! Map<String, dynamic> ||
              payment['method'] is! String ||
              payment['amount'] == null) {
            throw const ReportsFailure(
              'The API returned an invalid report payment.',
            );
          }
          return (
            method: payment['method'] as String,
            amount: payment['amount'].toString(),
          );
        })
        .toList(growable: false);
    return SalesInvoiceReport(
      id: text('id'),
      invoiceNumber: text('invoiceNumber'),
      cashierName: text('cashierName'),
      createdAt: text('createdAt'),
      paidAt: value['paidAt']?.toString() ?? '',
      gstEnabled: value['gstEnabled'] == true,
      subtotal: text('subtotal'),
      discountAmount: value['discountAmount']?.toString() ?? '0.00',
      totalTax: text('totalTax'),
      grandTotal: text('grandTotal'),
      paymentMethods: payments,
      items: (value['items'] as List)
          .map(ReportInvoiceItem.fromJson)
          .toList(growable: false),
    );
  }
}

class SalesReportData {
  const SalesReportData({
    required this.startDate,
    required this.endDate,
    required this.totalSales,
    required this.invoiceCount,
    required this.paymentSummary,
    required this.invoices,
  });

  final String startDate;
  final String endDate;
  final String totalSales;
  final int invoiceCount;
  final List<PaymentSummary> paymentSummary;
  final List<SalesInvoiceReport> invoices;

  factory SalesReportData.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['startDate'] is! String ||
        value['endDate'] is! String ||
        value['totalSales'] == null ||
        value['invoiceCount'] is! num ||
        value['paymentSummary'] is! List ||
        value['invoices'] is! List) {
      throw const ReportsFailure('The API returned an invalid sales report.');
    }
    return SalesReportData(
      startDate: value['startDate'] as String,
      endDate: value['endDate'] as String,
      totalSales: value['totalSales'].toString(),
      invoiceCount: (value['invoiceCount'] as num).toInt(),
      paymentSummary: (value['paymentSummary'] as List)
          .map(PaymentSummary.fromJson)
          .toList(growable: false),
      invoices: (value['invoices'] as List)
          .map(SalesInvoiceReport.fromJson)
          .toList(growable: false),
    );
  }
}

class DatabaseBackup {
  const DatabaseBackup({
    required this.fileName,
    required this.createdAt,
    required this.sizeBytes,
  });

  final String fileName;
  final String createdAt;
  final int sizeBytes;

  factory DatabaseBackup.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['fileName'] is! String ||
        value['createdAt'] is! String ||
        value['sizeBytes'] is! num) {
      throw const ReportsFailure('The API returned invalid backup metadata.');
    }
    return DatabaseBackup(
      fileName: value['fileName'] as String,
      createdAt: value['createdAt'] as String,
      sizeBytes: (value['sizeBytes'] as num).toInt(),
    );
  }
}

abstract interface class ReportsGateway {
  Future<DashboardData> dashboard(DateTime date);
  Future<SalesReportData> sales(DateTime start, DateTime end);
  Future<List<DatabaseBackup>> listBackups();
  Future<DatabaseBackup> createBackup();
  Future<void> restoreBackup(DatabaseBackup backup, String confirmation);
}

class HttpReportsGateway implements ReportsGateway {
  HttpReportsGateway({
    String baseUrl = const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://127.0.0.1:3000',
    ),
    FlutterSecureStorage? secureStorage,
    http.Client? httpClient,
  }) : _baseUri = Uri.parse(baseUrl),
       _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _httpClient = httpClient ?? http.Client();

  static const _tokenKey = 'malligai_kadai_access_token';
  final Uri _baseUri;
  final FlutterSecureStorage _secureStorage;
  final http.Client _httpClient;

  @override
  Future<DashboardData> dashboard(DateTime date) async {
    final body = await _request('GET', '/admin/dashboard?date=${_date(date)}');
    return DashboardData.fromJson(body['dashboard']);
  }

  @override
  Future<SalesReportData> sales(DateTime start, DateTime end) async {
    final body = await _request(
      'GET',
      '/admin/reports/sales?startDate=${_date(start)}&endDate=${_date(end)}',
    );
    return SalesReportData.fromJson(body['report']);
  }

  @override
  Future<List<DatabaseBackup>> listBackups() async {
    final body = await _request('GET', '/admin/backups');
    if (body['backups'] is! List) {
      throw const ReportsFailure('The API returned an invalid backup list.');
    }
    return (body['backups'] as List)
        .map(DatabaseBackup.fromJson)
        .toList(growable: false);
  }

  @override
  Future<DatabaseBackup> createBackup() async {
    final body = await _request('POST', '/admin/backups');
    return DatabaseBackup.fromJson(body['backup']);
  }

  @override
  Future<void> restoreBackup(DatabaseBackup backup, String confirmation) async {
    await _request(
      'POST',
      '/admin/backups/restore',
      payload: {'fileName': backup.fileName, 'confirmation': confirmation},
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? payload,
  }) async {
    final token = await _readToken();
    final headers = {
      'Authorization': 'Bearer $token',
      if (payload != null) 'Content-Type': 'application/json',
    };
    late final http.Response response;
    try {
      final uri = _baseUri.resolve(path);
      final future = method == 'GET'
          ? _httpClient.get(uri, headers: headers)
          : _httpClient.post(uri, headers: headers, body: jsonEncode(payload));
      response = await future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const ReportsFailure(
        'The local API took too long. Check its status and try again.',
      );
    } on SocketException {
      throw const ReportsFailure(
        'Could not connect to the local API. Check that the backend is running.',
      );
    } on http.ClientException {
      throw const ReportsFailure(
        'Could not connect to the local API. Check that the backend is running.',
      );
    }

    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      body = decoded;
    } on FormatException {
      throw const ReportsFailure('The API returned an invalid response.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ReportsFailure(
        body['message'] as String? ?? 'The report request failed.',
      );
    }
    return body;
  }

  Future<String> _readToken() async {
    try {
      final token = await _secureStorage.read(key: _tokenKey);
      if (token == null || token.isEmpty) {
        throw const ReportsFailure('Sign in again to access Admin reports.');
      }
      return token;
    } catch (error) {
      if (error is ReportsFailure) rethrow;
      throw const ReportsFailure(
        'Could not read the saved sign-in from Windows secure storage.',
      );
    }
  }

  String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
