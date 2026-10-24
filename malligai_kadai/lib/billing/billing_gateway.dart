import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class InvoiceCartItem {
  const InvoiceCartItem({
    required this.productId,
    required this.quantity,
    required this.unitPrice,
  });

  final String productId;
  final String quantity;
  final String unitPrice;

  Map<String, String> toJson() => {
    'productId': productId,
    'quantity': quantity,
    'unitPrice': unitPrice,
  };
}

class InvoicePayment {
  const InvoicePayment({required this.method, required this.amount});

  final String method;
  final String amount;

  Map<String, String> toJson() => {'method': method, 'amount': amount};

  factory InvoicePayment.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['method'] is! String ||
        value['amount'] == null) {
      throw const BillingFailure(
        'The API returned an invalid invoice payment.',
      );
    }
    return InvoicePayment(
      method: value['method'] as String,
      amount: value['amount'].toString(),
    );
  }
}

class GstSettings {
  const GstSettings({
    required this.gstEnabled,
    this.gstRate = '0.00',
    required this.priceMode,
    required this.stateCode,
    required this.updatedAt,
    this.businessName = 'Thanigai Stores',
    this.businessAddress = '',
    this.businessPhone = '',
    this.gstin = '',
  });

  final bool gstEnabled;
  final String gstRate;
  final String priceMode;
  final String stateCode;
  final String updatedAt;
  final String businessName;
  final String businessAddress;
  final String businessPhone;
  final String gstin;

  factory GstSettings.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['gstEnabled'] is! bool ||
        (value['priceMode'] != 'inclusive' &&
            value['priceMode'] != 'exclusive') ||
        value['stateCode'] is! String ||
        value['updatedAt'] is! String) {
      throw const BillingFailure('The API returned invalid GST settings.');
    }
    return GstSettings(
      gstEnabled: value['gstEnabled'] as bool,
      gstRate: value['gstRate']?.toString() ?? '0.00',
      priceMode: value['priceMode'] as String,
      stateCode: value['stateCode'] as String,
      updatedAt: value['updatedAt'] as String,
      businessName: value['businessName'] as String? ?? 'Thanigai Stores',
      businessAddress: value['businessAddress'] as String? ?? '',
      businessPhone: value['businessPhone'] as String? ?? '',
      gstin: value['gstin'] as String? ?? '',
    );
  }
}

class SavedInvoiceItem {
  const SavedInvoiceItem({
    required this.productName,
    required this.sku,
    required this.unit,
    required this.unitPrice,
    required this.quantity,
    required this.lineTotal,
    this.gstRate = '0.00',
    this.taxableAmount = '0.00',
    this.cgstAmount = '0.00',
    this.sgstAmount = '0.00',
    this.igstAmount = '0.00',
  });

  final String productName;
  final String sku;
  final String unit;
  final String unitPrice;
  final String quantity;
  final String lineTotal;
  final String gstRate;
  final String taxableAmount;
  final String cgstAmount;
  final String sgstAmount;
  final String igstAmount;

  factory SavedInvoiceItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const BillingFailure('The API returned an invalid invoice item.');
    }
    String text(String key) {
      final field = value[key];
      if (field == null || field is Map || field is List) {
        throw const BillingFailure('The API returned an invalid invoice item.');
      }
      return field.toString();
    }

    return SavedInvoiceItem(
      productName: text('productName'),
      sku: text('sku'),
      unit: text('unit'),
      unitPrice: text('unitPrice'),
      quantity: text('quantity'),
      lineTotal: text('lineTotal'),
      gstRate: value['gstRate']?.toString() ?? '0.00',
      taxableAmount: value['taxableAmount']?.toString() ?? '0.00',
      cgstAmount: value['cgstAmount']?.toString() ?? '0.00',
      sgstAmount: value['sgstAmount']?.toString() ?? '0.00',
      igstAmount: value['igstAmount']?.toString() ?? '0.00',
    );
  }
}

class SavedInvoice {
  const SavedInvoice({
    this.id = '',
    required this.invoiceNumber,
    required this.subtotal,
    required this.grandTotal,
    required this.createdAt,
    required this.items,
    required this.replayed,
    this.payments = const [],
    this.cashierName = 'Unknown',
    this.gstEnabled = false,
    this.priceMode = 'exclusive',
    this.shopStateCode = '00',
    this.saleStateCode = '00',
    this.taxableAmount = '0.00',
    this.cgstAmount = '0.00',
    this.sgstAmount = '0.00',
    this.igstAmount = '0.00',
    this.totalTax = '0.00',
    this.discountAmount = '0.00',
    this.businessName = 'Thanigai Stores',
    this.businessAddress = '',
    this.businessPhone = '',
    this.gstin = '',
  });

  final String id;
  final String invoiceNumber;
  final String cashierName;
  final String subtotal;
  final String grandTotal;
  final String discountAmount;
  final String createdAt;
  final List<SavedInvoiceItem> items;
  final List<InvoicePayment> payments;
  final bool replayed;
  final bool gstEnabled;
  final String priceMode;
  final String shopStateCode;
  final String saleStateCode;
  final String taxableAmount;
  final String cgstAmount;
  final String sgstAmount;
  final String igstAmount;
  final String totalTax;
  final String businessName;
  final String businessAddress;
  final String businessPhone;
  final String gstin;

  factory SavedInvoice.fromJson(Object? value, {required bool replayed}) {
    if (value is! Map<String, dynamic> || value['items'] is! List) {
      throw const BillingFailure('The API returned an invalid invoice.');
    }
    final items = value['items'] as List;
    String text(String key) {
      final field = value[key];
      if (field == null || field is Map || field is List) {
        throw const BillingFailure('The API returned an invalid invoice.');
      }
      return field.toString();
    }

    return SavedInvoice(
      id: value['id']?.toString() ?? '',
      invoiceNumber: text('invoiceNumber'),
      cashierName: value['cashierName']?.toString() ?? 'Unknown',
      subtotal: text('subtotal'),
      grandTotal: text('grandTotal'),
      discountAmount: value['discountAmount']?.toString() ?? '0.00',
      createdAt: text('createdAt'),
      items: items.map(SavedInvoiceItem.fromJson).toList(growable: false),
      payments: value['payments'] is List
          ? (value['payments'] as List)
                .map(InvoicePayment.fromJson)
                .toList(growable: false)
          : const [],
      replayed: replayed,
      gstEnabled: value['gstEnabled'] == true,
      priceMode: value['priceMode']?.toString() ?? 'exclusive',
      shopStateCode: value['shopStateCode']?.toString() ?? '00',
      saleStateCode: value['saleStateCode']?.toString() ?? '00',
      taxableAmount: value['taxableAmount']?.toString() ?? '0.00',
      cgstAmount: value['cgstAmount']?.toString() ?? '0.00',
      sgstAmount: value['sgstAmount']?.toString() ?? '0.00',
      igstAmount: value['igstAmount']?.toString() ?? '0.00',
      totalTax: value['totalTax']?.toString() ?? '0.00',
      businessName: value['businessName']?.toString() ?? 'Thanigai Stores',
      businessAddress: value['businessAddress']?.toString() ?? '',
      businessPhone: value['businessPhone']?.toString() ?? '',
      gstin: value['gstin']?.toString() ?? '',
    );
  }
}

class BillingFailure implements Exception {
  const BillingFailure(this.message, {this.statusCode = 0});

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

abstract interface class BillingGateway {
  Future<GstSettings> getGstSettings();
  Future<GstSettings> updateGstSettings({
    required bool gstEnabled,
    String gstRate = '0.00',
    required String priceMode,
    required String stateCode,
    String businessName = 'Thanigai Stores',
    String businessAddress = '',
    String businessPhone = '',
    String gstin = '',
  });
  Future<SavedInvoice> createInvoice({
    required String idempotencyKey,
    required List<InvoiceCartItem> items,
    required String saleStateCode,
    String discountAmount = '0.00',
    String gstAmount = '0.00',
    required List<InvoicePayment> payments,
  });
  Future<List<SavedInvoice>> listInvoices({int limit = 50});
  Future<SavedInvoice> findInvoiceById(String id);
  Future<void> voidInvoice(String id);
}

class HttpBillingGateway implements BillingGateway {
  HttpBillingGateway({
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

  Future<String> _readToken() async {
    try {
      final token = await _secureStorage.read(key: _tokenKey);
      if (token == null || token.isEmpty) {
        throw const BillingFailure(
          'Sign in again before accessing billing settings.',
          statusCode: 401,
        );
      }
      return token;
    } catch (error) {
      if (error is BillingFailure) rethrow;
      throw const BillingFailure(
        'Could not read the saved sign-in from Windows secure storage.',
      );
    }
  }

  @override
  Future<GstSettings> getGstSettings() async {
    final token = await _readToken();
    final body = await _sendJson(
      _httpClient.get(
        _baseUri.resolve('/settings/gst'),
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    return GstSettings.fromJson(body['settings']);
  }

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
  }) async {
    final token = await _readToken();
    final body = await _sendJson(
      _httpClient.put(
        _baseUri.resolve('/admin/settings/gst'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'gstEnabled': gstEnabled,
          'gstRate': gstRate,
          'priceMode': priceMode,
          'stateCode': stateCode,
          'businessName': businessName,
          'businessAddress': businessAddress,
          'businessPhone': businessPhone,
          'gstin': gstin,
        }),
      ),
    );
    return GstSettings.fromJson(body['settings']);
  }

  @override
  Future<SavedInvoice> createInvoice({
    required String idempotencyKey,
    required List<InvoiceCartItem> items,
    required String saleStateCode,
    String discountAmount = '0.00',
    String gstAmount = '0.00',
    required List<InvoicePayment> payments,
  }) async {
    final token = await _readToken();
    final body = await _sendJson(
      _httpClient.post(
        _baseUri.resolve('/invoices'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'idempotencyKey': idempotencyKey,
          'items': items.map((item) => item.toJson()).toList(),
          'saleStateCode': saleStateCode,
          'discountAmount': discountAmount,
          'gstAmount': gstAmount,
          'payments': payments.map((payment) => payment.toJson()).toList(),
        }),
      ),
    );
    return SavedInvoice.fromJson(
      body['invoice'],
      replayed: body['replayed'] == true,
    );
  }

  @override
  Future<List<SavedInvoice>> listInvoices({int limit = 50}) async {
    final token = await _readToken();
    final body = await _sendJson(
      _httpClient.get(
        _baseUri.replace(
          path: '/invoices',
          queryParameters: {'limit': '$limit'},
        ),
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    final invoices = body['invoices'];
    if (invoices is! List) {
      throw const BillingFailure('The API returned an invalid invoice list.');
    }
    return invoices
        .map((invoice) => SavedInvoice.fromJson(invoice, replayed: false))
        .toList(growable: false);
  }

  @override
  Future<SavedInvoice> findInvoiceById(String id) async {
    if (!RegExp(r'^[1-9]\d*$').hasMatch(id)) {
      throw const BillingFailure('Invoice ID must be a positive integer.');
    }
    final token = await _readToken();
    final body = await _sendJson(
      _httpClient.get(
        _baseUri.resolve('/invoices/$id'),
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    return SavedInvoice.fromJson(body['invoice'], replayed: false);
  }

  @override
  Future<void> voidInvoice(String id) async {
    if (!RegExp(r'^[1-9]\d*$').hasMatch(id)) {
      throw const BillingFailure('Invoice ID must be a positive integer.');
    }
    final token = await _readToken();
    final response = await _send(
      _httpClient.delete(
        _baseUri.resolve('/admin/invoices/$id'),
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    if (response.statusCode != 204) {
      final body = _decode(response);
      throw BillingFailure(
        body['message'] as String? ?? 'Could not void the invoice.',
        statusCode: response.statusCode,
      );
    }
  }

  Future<http.Response> _send(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw const BillingFailure(
        'The local API did not respond. Please retry.',
      );
    } on SocketException {
      throw const BillingFailure(
        'Could not connect to the local API. Check that the backend is running.',
      );
    } on http.ClientException {
      throw const BillingFailure(
        'Could not connect to the local API. Check that the backend is running.',
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return decoded;
    } on FormatException {
      throw const BillingFailure('The API returned an invalid response.');
    }
  }

  Future<Map<String, dynamic>> _sendJson(Future<http.Response> request) async {
    final response = await _send(request);
    final body = _decode(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BillingFailure(
        body['message'] as String? ?? 'The request could not be completed.',
        statusCode: response.statusCode,
      );
    }
    return body;
  }
}
