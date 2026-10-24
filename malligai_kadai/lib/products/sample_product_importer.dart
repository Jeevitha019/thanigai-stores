import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import 'product_gateway.dart';

class ProductImportPlan {
  const ProductImportPlan({
    required this.products,
    required this.duplicateCount,
  });

  final List<ProductDraft> products;
  final int duplicateCount;
}

class SampleProductImporter {
  static Future<List<ProductDraft>> loadBundledProducts() async {
    final data = await rootBundle.load('assets/sample_products.xlsx');
    return parse(data.buffer.asUint8List());
  }

  static List<ProductDraft> parse(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final worksheet = archive.findFile('xl/worksheets/sheet1.xml');
    if (worksheet == null) {
      throw const FormatException('The Excel workbook has no Products sheet.');
    }

    final document = XmlDocument.parse(utf8.decode(worksheet.content));
    final sharedStringsFile = archive.findFile('xl/sharedStrings.xml');
    final sharedStrings = sharedStringsFile == null
        ? const <String>[]
        : _parseSharedStrings(sharedStringsFile);
    final rows = document.findAllElements('row').toList();
    if (rows.length < 2) {
      throw const FormatException('The Products sheet contains no products.');
    }

    final headers = _rowValues(rows.first, sharedStrings);
    const requiredHeaders = [
      'Category (English)',
      'Category (Tamil)',
      'Product Name (English)',
      'Product Name (Tamil)',
      'Unit',
      'Purchase Price (₹)',
      'Market Selling Price (₹)',
      'GST Rate (%)',
    ];
    for (var index = 0; index < requiredHeaders.length; index += 1) {
      if (headers[index] != requiredHeaders[index]) {
        throw const FormatException(
          'The Products sheet columns do not match the supported sample format.',
        );
      }
    }

    final products = <ProductDraft>[];
    for (final row in rows.skip(1)) {
      final values = _rowValues(row, sharedStrings);
      if (values.every((value) => value.trim().isEmpty)) continue;
      final category = values[0].trim();
      final name = values[2].trim();
      final unit = values[4].trim().toLowerCase();
      final purchasePrice = _price(
        values[5],
        'purchase price',
        allowZero: true,
      );
      final sellingPrice = _price(values[6], 'selling price');
      final gstRate = _gstRate(values[7]);
      if (category.isEmpty || name.isEmpty || name.length > 160) {
        throw FormatException(
          'Invalid product name or category on row ${row.getAttribute('r')}.',
        );
      }
      if (!productUnits.contains(unit)) {
        throw FormatException(
          'Unsupported unit "$unit" on row ${row.getAttribute('r')}.',
        );
      }

      products.add(
        ProductDraft(
          name: name,
          sku: _productCode(name),
          category: category,
          unit: unit,
          purchasePrice: purchasePrice,
          sellingPrice: sellingPrice,
          gstRate: gstRate,
        ),
      );
    }
    if (products.isEmpty) {
      throw const FormatException('The Products sheet contains no products.');
    }
    return List.unmodifiable(products);
  }

  static ProductImportPlan plan(
    List<ProductDraft> products,
    List<ProductItem> existing,
  ) {
    final existingCodes = existing
        .map((product) => product.sku.trim().toLowerCase())
        .where((sku) => sku.isNotEmpty)
        .toSet();
    final existingNames = existing.map(_productIdentity).toSet();
    final seenCodes = <String>{};
    final seenNames = <String>{};
    final additions = <ProductDraft>[];
    var duplicates = 0;

    for (final product in products) {
      final code = product.sku.toLowerCase();
      final identity = _draftIdentity(product);
      if (existingCodes.contains(code) ||
          existingNames.contains(identity) ||
          !seenCodes.add(code) ||
          !seenNames.add(identity)) {
        duplicates += 1;
        continue;
      }
      additions.add(product);
    }
    return ProductImportPlan(
      products: List.unmodifiable(additions),
      duplicateCount: duplicates,
    );
  }

  static List<String> _parseSharedStrings(ArchiveFile file) {
    final document = XmlDocument.parse(utf8.decode(file.content));
    return document
        .findAllElements('si')
        .map(
          (item) =>
              item.findAllElements('t').map((text) => text.innerText).join(),
        )
        .toList(growable: false);
  }

  static List<String> _rowValues(XmlElement row, List<String> sharedStrings) {
    final values = List<String>.filled(8, '');
    for (final cell in row.findElements('c')) {
      final reference = cell.getAttribute('r');
      if (reference == null) continue;
      final column = RegExp(r'^[A-Z]+').firstMatch(reference)?.group(0);
      if (column == null) continue;
      final index = _columnIndex(column);
      if (index < 0 || index >= values.length) continue;

      final type = cell.getAttribute('t');
      if (type == 'inlineStr') {
        values[index] = cell
            .findAllElements('t')
            .map((text) => text.innerText)
            .join();
      } else {
        final value = cell.findElements('v').toList();
        if (value.isEmpty) continue;
        final raw = value.first.innerText;
        if (type == 's') {
          final stringIndex = int.tryParse(raw);
          if (stringIndex == null ||
              stringIndex < 0 ||
              stringIndex >= sharedStrings.length) {
            throw const FormatException(
              'The Excel workbook has invalid shared strings.',
            );
          }
          values[index] = sharedStrings[stringIndex];
        } else {
          values[index] = raw;
        }
      }
    }
    return values;
  }

  static int _columnIndex(String column) {
    var index = 0;
    for (final codeUnit in column.codeUnits) {
      index = index * 26 + codeUnit - 64;
    }
    return index - 1;
  }

  static String _price(String value, String label, {bool allowZero = false}) {
    final normalized = value.trim();
    final price = double.tryParse(normalized);
    if (!RegExp(r'^\d{1,10}(?:\.\d{1,2})?$').hasMatch(normalized) ||
        price == null ||
        !price.isFinite ||
        (allowZero ? price < 0 : price <= 0) ||
        price > 9999999999.99) {
      throw FormatException('Invalid $label "$normalized" in the Excel sheet.');
    }
    return normalized;
  }

  static String _gstRate(String value) {
    final normalized = value.trim();
    if (!const {
      '0',
      '0.00',
      '5',
      '5.00',
      '12',
      '12.00',
      '18',
      '18.00',
      '28',
      '28.00',
    }.contains(normalized)) {
      throw FormatException(
        'Unsupported GST rate "$normalized" in the Excel sheet.',
      );
    }
    return double.parse(normalized).toStringAsFixed(2);
  }

  static String _productCode(String name) {
    final slug = name
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) {
      throw const FormatException(
        'A sample product is missing an English name.',
      );
    }
    return 'TS-${slug.substring(0, slug.length > 61 ? 61 : slug.length)}';
  }

  static String _productIdentity(ProductItem product) =>
      '${product.name.trim().toLowerCase()}|${product.category.trim().toLowerCase()}';

  static String _draftIdentity(ProductDraft product) =>
      '${product.name.trim().toLowerCase()}|${product.category.trim().toLowerCase()}';
}
