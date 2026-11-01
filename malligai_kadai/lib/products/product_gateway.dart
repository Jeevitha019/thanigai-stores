import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

const productUnits = ['g', 'kg', 'ml', 'litre', 'packet', 'piece'];

String formatSellingQuantity(String value) {
  final parts = value.split('.');
  if (parts.length < 2) return value;
  final fraction = parts[1].replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? parts[0] : '${parts[0]}.$fraction';
}

class ProductItem {
  const ProductItem({
    required this.id,
    required this.name,
    required this.sku,
    required this.category,
    required this.unit,
    this.purchasePrice,
    required this.sellingPrice,
    this.mrp,
    this.sellingQuantity = '1.000',
    this.openingStockQuantity = '0.000',
    this.stockQuantity = '0.000',
    required this.gstRate,
  });

  final String id;
  final String name;
  final String sku;
  final String category;
  final String unit;
  final String? purchasePrice;
  final String sellingPrice;
  final String? mrp;
  final String sellingQuantity;
  final String openingStockQuantity;
  final String stockQuantity;
  final String gstRate;

  factory ProductItem.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const ProductFailure('The API returned an invalid product.');
    }

    String text(String key) {
      final value = json[key];
      if (value == null || value is Map || value is List) {
        throw const ProductFailure('The API returned an invalid product.');
      }
      return value.toString();
    }

    return ProductItem(
      id: text('id'),
      name: text('name'),
      sku: json['sku']?.toString() ?? '',
      category: text('category'),
      unit: text('unit'),
      purchasePrice: json['purchasePrice'] == null
          ? null
          : text('purchasePrice'),
      sellingPrice: text('sellingPrice'),
      mrp: json['mrp'] == null ? null : text('mrp'),
      sellingQuantity: json['sellingQuantity'] == null
          ? '1.000'
          : text('sellingQuantity'),
      openingStockQuantity: json['openingStockQuantity'] == null
          ? '0.000'
          : text('openingStockQuantity'),
      stockQuantity: json['stockQuantity'] == null
          ? '0.000'
          : text('stockQuantity'),
      gstRate: text('gstRate'),
    );
  }
}

class ProductDraft {
  const ProductDraft({
    required this.name,
    required this.sku,
    required this.category,
    required this.unit,
    required this.purchasePrice,
    required this.sellingPrice,
    this.mrp,
    this.sellingQuantity = '1.000',
    this.openingStockQuantity = '0.000',
    required this.gstRate,
  });

  final String name;
  final String sku;
  final String category;
  final String unit;
  final String purchasePrice;
  final String sellingPrice;
  final String? mrp;
  final String sellingQuantity;
  final String openingStockQuantity;
  final String gstRate;

  Map<String, Object?> toJson() => {
    'name': name.trim(),
    'sku': sku.trim().isEmpty ? null : sku.trim(),
    'category': category.trim(),
    'unit': unit,
    'purchasePrice': purchasePrice.trim(),
    'sellingPrice': sellingPrice.trim(),
    'mrp': mrp?.trim().isEmpty == true ? null : mrp?.trim(),
    'sellingQuantity': sellingQuantity.trim(),
    'openingStockQuantity': openingStockQuantity.trim(),
    'gstRate': gstRate.trim(),
  };
}

class StockBatch {
  const StockBatch({
    required this.id,
    required this.quantity,
    required this.remainingQuantity,
    required this.purchasePrice,
    required this.purchaseDate,
  });

  final String id;
  final String quantity;
  final String remainingQuantity;
  final String purchasePrice;
  final String purchaseDate;

  factory StockBatch.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const ProductFailure('The API returned an invalid stock batch.');
    }
    String text(String key) {
      final value = json[key];
      if (value == null || value is Map || value is List) {
        throw const ProductFailure('The API returned an invalid stock batch.');
      }
      return value.toString();
    }

    return StockBatch(
      id: text('id'),
      quantity: text('quantity'),
      remainingQuantity: text('remainingQuantity'),
      purchasePrice: text('purchasePrice'),
      purchaseDate: text('purchaseDate'),
    );
  }
}

class StockProduct {
  const StockProduct({
    required this.productId,
    required this.name,
    required this.sku,
    required this.unit,
    required this.openingQuantity,
    required this.openingRemainingQuantity,
    required this.openingPurchasePrice,
    required this.totalQuantity,
    required this.purchases,
  });

  final String productId;
  final String name;
  final String? sku;
  final String unit;
  final String openingQuantity;
  final String openingRemainingQuantity;
  final String openingPurchasePrice;
  final String totalQuantity;
  final List<StockBatch> purchases;

  factory StockProduct.fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['purchases'] is! List) {
      throw const ProductFailure('The API returned an invalid stock product.');
    }
    String text(String key) {
      final value = json[key];
      if (value == null || value is Map || value is List) {
        throw const ProductFailure(
          'The API returned an invalid stock product.',
        );
      }
      return value.toString();
    }

    return StockProduct(
      productId: text('productId'),
      name: text('name'),
      sku: json['sku']?.toString(),
      unit: text('unit'),
      openingQuantity: text('openingQuantity'),
      openingRemainingQuantity: text('openingRemainingQuantity'),
      openingPurchasePrice: text('openingPurchasePrice'),
      totalQuantity: text('totalQuantity'),
      purchases: (json['purchases'] as List)
          .map(StockBatch.fromJson)
          .toList(growable: false),
    );
  }
}

abstract interface class StockGateway {
  Future<List<StockProduct>> loadStocks();
  Future<StockProduct> updateOpeningStock(
    String productId,
    String quantity,
    String purchasePrice,
  );
  Future<StockProduct> receiveStockPurchase(
    String productId,
    String quantity,
    String purchasePrice,
    String purchaseDate,
  );
}

class ProductFailure implements Exception {
  const ProductFailure(this.message, {this.statusCode = 0});

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

abstract interface class ProductGateway {
  Future<List<ProductItem>> searchProducts(String search);
  Future<ProductItem> createProduct(ProductDraft product);
  Future<ProductItem> updateProduct(String id, ProductDraft product);
  Future<void> deleteProduct(String id);
}

class HttpProductGateway implements ProductGateway, StockGateway {
  HttpProductGateway({
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

  Future<http.Response> _authorized(
    Future<http.Response> Function(String token) request,
  ) async {
    String? token;
    try {
      token = await _secureStorage.read(key: _tokenKey);
    } catch (_) {
      throw const ProductFailure(
        'Could not read the saved sign-in from Windows secure storage.',
      );
    }
    if (token == null || token.isEmpty) {
      throw const ProductFailure(
        'Sign in again to view or manage products.',
        statusCode: 401,
      );
    }

    try {
      return await request(token).timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw const ProductFailure(
        'The local API did not respond. Check that the backend is running.',
      );
    } on SocketException {
      throw const ProductFailure(
        'Could not connect to the local API. Check that the backend is running.',
      );
    } on http.ClientException {
      throw const ProductFailure(
        'Could not connect to the local API. Check that the backend is running.',
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final value = jsonDecode(response.body);
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      throw const ProductFailure('The API returned an invalid response.');
    }
    throw const ProductFailure('The API returned an invalid response.');
  }

  void _checkStatus(
    http.Response response,
    Map<String, dynamic> body,
    int expected,
  ) {
    if (response.statusCode != expected) {
      throw ProductFailure(
        body['message'] as String? ?? 'The product request failed.',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<List<ProductItem>> searchProducts(String search) async {
    final uri = _baseUri.replace(
      path: '/products',
      queryParameters: search.trim().isEmpty ? null : {'search': search.trim()},
    );
    final response = await _authorized(
      (token) =>
          _httpClient.get(uri, headers: {'Authorization': 'Bearer $token'}),
    );
    final body = _decode(response);
    _checkStatus(response, body, 200);
    final products = body['products'];
    if (products is! List) {
      throw const ProductFailure('The API returned an invalid product list.');
    }
    return products.map(ProductItem.fromJson).toList(growable: false);
  }

  @override
  Future<ProductItem> createProduct(ProductDraft product) async {
    final response = await _authorized(
      (token) => _httpClient.post(
        _baseUri.resolve('/products'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(product.toJson()),
      ),
    );
    final body = _decode(response);
    _checkStatus(response, body, 201);
    return ProductItem.fromJson(body['product']);
  }

  @override
  Future<ProductItem> updateProduct(String id, ProductDraft product) async {
    final response = await _authorized(
      (token) => _httpClient.put(
        _baseUri.resolve('/products/$id'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(product.toJson()),
      ),
    );
    final body = _decode(response);
    _checkStatus(response, body, 200);
    return ProductItem.fromJson(body['product']);
  }

  @override
  Future<void> deleteProduct(String id) async {
    final response = await _authorized(
      (token) => _httpClient.delete(
        _baseUri.resolve('/products/$id'),
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    if (response.statusCode != 204) {
      final body = _decode(response);
      _checkStatus(response, body, 204);
    }
  }

  @override
  Future<List<StockProduct>> loadStocks() async {
    final response = await _authorized(
      (token) => _httpClient.get(
        _baseUri.resolve('/stocks'),
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    final body = _decode(response);
    _checkStatus(response, body, 200);
    final products = body['products'];
    if (products is! List) {
      throw const ProductFailure('The API returned an invalid stock list.');
    }
    return products.map(StockProduct.fromJson).toList(growable: false);
  }

  @override
  Future<StockProduct> updateOpeningStock(
    String productId,
    String quantity,
    String purchasePrice,
  ) async {
    final response = await _authorized(
      (token) => _httpClient.put(
        _baseUri.resolve('/stocks/$productId/opening'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'quantity': quantity,
          'purchasePrice': purchasePrice,
        }),
      ),
    );
    final body = _decode(response);
    _checkStatus(response, body, 200);
    return StockProduct.fromJson(body['product']);
  }

  @override
  Future<StockProduct> receiveStockPurchase(
    String productId,
    String quantity,
    String purchasePrice,
    String purchaseDate,
  ) async {
    final response = await _authorized(
      (token) => _httpClient.post(
        _baseUri.resolve('/stocks/$productId/purchases'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'quantity': quantity,
          'purchasePrice': purchasePrice,
          'purchaseDate': purchaseDate,
        }),
      ),
    );
    final body = _decode(response);
    _checkStatus(response, body, 201);
    return StockProduct.fromJson(body['product']);
  }
}
