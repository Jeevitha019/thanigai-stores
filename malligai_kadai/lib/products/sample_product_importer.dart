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

class ProductImportData {
  const ProductImportData({required this.products, required this.rowErrors});

  final List<ProductDraft> products;
  final List<String> rowErrors;
}

class SampleProductImporter {
  static Future<List<ProductDraft>> loadBundledProducts() async {
    final data = await rootBundle.load('assets/sample_products.xlsx');
    return parse(data.buffer.asUint8List());
  }

  static List<ProductDraft> parse(List<int> bytes) {
    final result = parseWithValidation(bytes);
    if (result.rowErrors.isNotEmpty) {
      throw FormatException(result.rowErrors.join('\n'));
    }
    return result.products;
  }

  static ProductImportData parseWithValidation(List<int> bytes) {
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
    const sampleHeaders = [
      'Category (English)',
      'Category (Tamil)',
      'Product Name (English)',
      'Product Name (Tamil)',
      'Unit',
      'Purchase Price (₹)',
      'Market Selling Price (₹)',
      'GST Rate (%)',
    ];
    final isSampleFormat =
        headers.length >= sampleHeaders.length &&
        List.generate(
          sampleHeaders.length,
          (index) => headers[index] == sampleHeaders[index],
        ).every((matches) => matches);
    final columns = <String, int>{};
    if (isSampleFormat) {
      columns.addAll({
        'category': 0,
        'name': 2,
        'unit': 4,
        'purchasePrice': 5,
        'sellingPrice': 6,
        'gstRate': 7,
        'stock': 8,
      });
    } else {
      for (var index = 0; index < headers.length; index += 1) {
        final header = _normalizeHeader(headers[index]);
        if (const {
          'productname',
          'productnameenglish',
          'name',
        }.contains(header)) {
          columns.putIfAbsent('name', () => index);
        } else if (const {
          'category',
          'categoryenglish',
          'productcategory',
        }.contains(header)) {
          columns.putIfAbsent('category', () => index);
        } else if (const {
          'unit',
          'productunit',
          'sellingunit',
        }.contains(header)) {
          columns.putIfAbsent('unit', () => index);
        } else if (const {'purchaseprice', 'price'}.contains(header)) {
          columns.putIfAbsent('purchasePrice', () => index);
        } else if (const {
          'sellingprice',
          'marketsellingprice',
          'sales',
        }.contains(header)) {
          columns.putIfAbsent('sellingPrice', () => index);
        } else if (const {'mrp', 'maximumretailprice'}.contains(header)) {
          columns.putIfAbsent('mrp', () => index);
        } else if (const {
          'stockquantity',
          'openingstockquantity',
          'openingoldstockquantity',
          'availablequantity',
          'quantity',
          'qty',
          'stockqty',
        }.contains(header)) {
          columns.putIfAbsent('stock', () => index);
        } else if (header == 'per') {
          columns.putIfAbsent('per', () => index);
        } else if (const {
          'sellingquantity',
          'pricequantity',
        }.contains(header)) {
          columns.putIfAbsent('sellingQuantity', () => index);
        } else if (const {'productcode', 'sku'}.contains(header)) {
          columns.putIfAbsent('sku', () => index);
        } else if (const {'gstrate', 'gstratepercent'}.contains(header)) {
          columns.putIfAbsent('gstRate', () => index);
        }
      }
    }

    if (!columns.keys.toSet().containsAll({
      'name',
      'purchasePrice',
      'sellingPrice',
    })) {
      throw const FormatException(
        'The Excel sheet must include product name, purchase price, and selling price columns.',
      );
    }
    if (isSampleFormat &&
        ((headers.length > 8 &&
                headers[8].isNotEmpty &&
                headers[8] != 'Opening/Old Stock Quantity') ||
            (headers.length > 9 &&
                headers[9].isNotEmpty &&
                headers[9] != 'Stock Unit'))) {
      throw const FormatException(
        'The Products sheet columns do not match the supported sample format.',
      );
    }

    final products = <ProductDraft>[];
    final rowErrors = <String>[];
    for (final row in rows.skip(1)) {
      final values = _rowValues(row, sharedStrings);
      if (values.every((value) => value.trim().isEmpty)) continue;
      try {
        String value(String column) {
          final index = columns[column];
          return index == null || index >= values.length ? '' : values[index];
        }

        final category = value('category').trim();
        final name = value('name').trim();
        final perValue = value('per').trim();
        var unit = value('unit').trim().toLowerCase();
        if (unit.isEmpty && perValue.isNotEmpty) {
          unit = _unitFrom(perValue, row.getAttribute('r'));
        }
        if (unit.isEmpty && value('stock').trim().isNotEmpty) {
          unit = _unitFrom(value('stock'), row.getAttribute('r'));
        }
        if (unit.isEmpty) unit = 'piece';
        final purchasePrice = _price(
          value('purchasePrice'),
          'purchase price',
          allowZero: true,
          rowNumber: row.getAttribute('r'),
        );
        final sellingValue = value('sellingPrice').trim().isEmpty
            ? value('mrp')
            : value('sellingPrice');
        final sellingPrice = _price(
          sellingValue,
          'selling price',
          rowNumber: row.getAttribute('r'),
        );
        final gstValue = value('gstRate').trim();
        final gstRate = gstValue.isEmpty ? '0.00' : _gstRate(gstValue);
        if (name.isEmpty || name.length > 160 || category.length > 80) {
          throw FormatException(
            'Invalid product name or category on row ${row.getAttribute('r')}.',
          );
        }
        if (!productUnits.contains(unit)) {
          throw FormatException(
            'Unsupported unit "$unit" on row ${row.getAttribute('r')}.',
          );
        }
        final stockUnit = isSampleFormat && values.length > 9
            ? values[9].trim().toLowerCase()
            : '';
        if (stockUnit.isNotEmpty) {
          if (!productUnits.contains(stockUnit)) {
            throw FormatException(
              'Unsupported stock unit "$stockUnit" on row ${row.getAttribute('r')}.',
            );
          }
          unit = stockUnit;
        }

        products.add(
          ProductDraft(
            name: name,
            sku: value('sku').trim().isEmpty
                ? _productCode(name)
                : value('sku').trim(),
            category: category.isEmpty ? 'General' : category,
            unit: unit,
            purchasePrice: purchasePrice,
            sellingPrice: sellingPrice,
            sellingQuantity: value('sellingQuantity').trim().isNotEmpty
                ? _quantity(value('sellingQuantity'), row.getAttribute('r'))
                : perValue.isNotEmpty
                ? _quantity(
                    _leadingNumber(perValue, row.getAttribute('r')),
                    row.getAttribute('r'),
                  )
                : '1.000',
            openingStockQuantity: value('stock').trim().isEmpty
                ? '0.000'
                : _quantity(
                    _stockNumber(value('stock'), unit, row.getAttribute('r')),
                    row.getAttribute('r'),
                  ),
            mrp: value('mrp').trim().isEmpty
                ? null
                : _price(
                    value('mrp'),
                    'MRP',
                    allowZero: true,
                    rowNumber: row.getAttribute('r'),
                  ),
            gstRate: gstRate,
          ),
        );
      } on FormatException catch (error) {
        rowErrors.add(error.message);
      }
    }
    if (products.isEmpty && rowErrors.isEmpty) {
      throw const FormatException('The Products sheet contains no products.');
    }
    return ProductImportData(
      products: List.unmodifiable(products),
      rowErrors: List.unmodifiable(rowErrors),
    );
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
    final values = List<String>.filled(52, '');
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

  static String _normalizeHeader(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static String _leadingNumber(String value, String? rowNumber) {
    final match = RegExp(r'^\s*(\d+(?:\.\d{1,3})?)').firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid quantity "$value" on row $rowNumber.');
    }
    return match.group(1)!;
  }

  static String _unitFrom(String value, String? rowNumber) {
    final match = RegExp(
      r'(kg|g|litres?|ltrs?|ml|pcs?|pieces?|packets?|packs?|boxes|box|pai)',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) {
      throw FormatException('Unsupported unit in "$value" on row $rowNumber.');
    }
    final unit = match.group(1)!.toLowerCase();
    if (unit == 'kg' || unit == 'g' || unit == 'ml') return unit;
    if (unit.startsWith('litre') || unit.startsWith('ltr') || unit == 'l') {
      return 'litre';
    }
    if (unit.startsWith('pack') || unit.startsWith('box') || unit == 'pai') {
      return 'packet';
    }
    return 'piece';
  }

  static String _stockNumber(String value, String unit, String? rowNumber) {
    if (unit == 'piece') {
      final packCount = RegExp(
        r'\((\d+(?:\.\d{1,3})?)\s*(?:pcs?|pieces?)\)',
        caseSensitive: false,
      ).firstMatch(value);
      if (packCount != null) return packCount.group(1)!;
    }
    return _leadingNumber(value, rowNumber);
  }

  static String _normalizeMoney(String value) {
    var normalized = value.trim().replaceAll(',', '');
    if (normalized.contains('=')) {
      normalized = normalized.split('=').last.trim();
    }
    return normalized
        .replaceAll(RegExp(r'^(?:₹|rs\.?|inr)\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*(?:₹|rs\.?|inr)$', caseSensitive: false), '')
        .trim();
  }

  static String _price(
    String value,
    String label, {
    bool allowZero = false,
    String? rowNumber,
  }) {
    final normalized = _normalizeMoney(value);
    final price = double.tryParse(normalized);
    if (!RegExp(r'^\d{1,10}(?:\.\d{1,2})?$').hasMatch(normalized) ||
        price == null ||
        !price.isFinite ||
        (allowZero ? price < 0 : price <= 0) ||
        price > 9999999999.99) {
      throw FormatException(
        'Invalid $label "$normalized" on row $rowNumber in the Excel sheet.',
      );
    }
    return normalized;
  }

  static String _gstRate(String value) {
    final normalized = value.trim();
    final rate = double.tryParse(normalized);
    if (!RegExp(r'^\d{1,3}(?:\.\d{1,2})?$').hasMatch(normalized) ||
        rate == null ||
        !rate.isFinite ||
        rate < 0 ||
        rate > 100) {
      throw FormatException(
        'Unsupported GST rate "$normalized" in the Excel sheet.',
      );
    }

    return double.parse(normalized).toStringAsFixed(2);
  }

  static String _quantity(String value, String? rowNumber) {
    final normalized = value.trim();
    if (!RegExp(r'^\d+(?:\.\d{0,3})?$').hasMatch(normalized)) {
      throw FormatException(
        'Invalid opening stock quantity "$normalized" on row $rowNumber.',
      );
    }
    final quantity = double.tryParse(normalized);
    if (quantity == null || quantity < 0 || quantity > 999999999.999) {
      throw FormatException(
        'Invalid opening stock quantity "$normalized" on row $rowNumber.',
      );
    }
    return quantity.toStringAsFixed(3);
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
