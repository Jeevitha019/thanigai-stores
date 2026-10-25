import 'billing_gateway.dart';

class ReceiptFormatter {
  static const int a4Columns = 80;

  static List<String> format(
    SavedInvoice invoice, {
    required int paperWidthMm,
    double? printableWidthMm,
    bool testMode = false,
    bool includeFooter = true,
  }) {
    if (paperWidthMm != 58 && paperWidthMm != 80) {
      throw ArgumentError.value(paperWidthMm, 'paperWidthMm');
    }
    final contentWidthMm = printableWidthMm ?? (paperWidthMm - 8).toDouble();
    if (!contentWidthMm.isFinite ||
        contentWidthMm < 40 ||
        contentWidthMm > paperWidthMm) {
      throw ArgumentError.value(printableWidthMm, 'printableWidthMm');
    }
    final columns = (contentWidthMm * 0.6).ceil();
    return _format(
      invoice,
      columns: columns,
      testMode: testMode,
      includeFooter: includeFooter,
    );
  }

  static List<String> formatA4(
    SavedInvoice invoice, {
    bool testMode = false,
    bool includeFooter = true,
  }) => _format(
    invoice,
    columns: a4Columns,
    testMode: testMode,
    includeFooter: includeFooter,
    a4Layout: true,
  );

  static List<String> formatA4Footer(
    SavedInvoice invoice, {
    bool testMode = false,
  }) {
    final lines = <String>[];
    void centered(String value) {
      for (final line in _wrap(value, a4Columns)) {
        lines.add(line.padLeft((a4Columns + line.length) ~/ 2));
      }
    }

    lines.add('-' * a4Columns);
    centered(testMode ? 'PRINTER TEST ONLY' : 'THANK YOU! VISIT US AGAIN!');
    if (invoice.businessAddress.isNotEmpty) {
      centered(invoice.businessAddress);
    }
    if (invoice.businessPhone.isNotEmpty) {
      centered(invoice.businessPhone);
    }
    lines.add('');
    centered('Developed By ZEROPOINT LABS');
    centered('www.zeropointlabs.in');
    return List.unmodifiable(lines);
  }

  static List<String> _format(
    SavedInvoice invoice, {
    required int columns,
    required bool testMode,
    required bool includeFooter,
    bool a4Layout = false,
  }) {
    final lines = <String>[];

    void centered(String text) {
      for (final line in _wrap(text, columns)) {
        final left = ((columns - line.length) ~/ 2).clamp(0, columns);
        lines.add('${' ' * left}$line');
      }
    }

    void pair(String label, String value) {
      if (value.isEmpty) {
        lines.addAll(_wrap(label, columns));
      } else if (label.length + value.length + 2 <= columns) {
        lines.add(
          '$label${' ' * (columns - label.length - value.length)}$value',
        );
      } else {
        lines.addAll(_wrap(label, columns));
        lines.addAll(
          _wrap(value, columns).map((line) => line.padLeft(columns)),
        );
      }
    }

    void divider() => lines.add('-' * columns);

    centered(invoice.businessName.toUpperCase());
    if (invoice.gstin.isNotEmpty && !a4Layout) {
      centered('GSTIN ${invoice.gstin}');
    }
    if (testMode) centered('*** PRINTER TEST - NOT A SALE ***');
    divider();
    if (a4Layout) {
      pair(
        'Invoice No: ${invoice.invoiceNumber}',
        'Date: ${_formatDate(invoice.createdAt)}',
      );
      pair('Cashier: ${invoice.cashierName}', '');
      if (invoice.gstin.isNotEmpty) pair('GSTIN: ${invoice.gstin}', '');
      divider();

      const itemWidth = 42;
      const detailsWidth = 30;
      const amountWidth = a4Columns - itemWidth - detailsWidth;
      lines.add(
        'Item'.padRight(itemWidth) +
            'Qty / Unit Price'.padRight(detailsWidth) +
            'Amount'.padLeft(amountWidth),
      );
      divider();
      for (final item in invoice.items) {
        final names = _wrap(item.productName, itemWidth);
        final details = _wrap(
          '${item.quantity} ${item.unit} x ${_formatUnitPrice(item.unitPrice)}',
          detailsWidth,
        );
        final amounts = _wrap('₹${item.lineTotal}', amountWidth);
        final rowCount = [
          names.length,
          details.length,
          amounts.length,
        ].reduce((left, right) => left > right ? left : right);
        for (var index = 0; index < rowCount; index++) {
          final name = index < names.length ? names[index] : '';
          final detail = index < details.length ? details[index] : '';
          lines.add(
            name.padRight(itemWidth) +
                detail.padRight(detailsWidth) +
                (index < amounts.length ? amounts[index] : '').padLeft(
                  amountWidth,
                ),
          );
        }
      }
    } else {
      pair('Bill No', invoice.invoiceNumber);
      pair('Date', _formatDate(invoice.createdAt));
      pair('Cashier', invoice.cashierName);
      divider();
      final quantityWidth = columns == 30 ? 6 : 8;
      final priceWidth = columns == 30 ? 7 : 9;
      final amountWidth = columns == 30 ? 7 : 9;
      final itemWidth = columns - quantityWidth - priceWidth - amountWidth - 3;
      final widths = [itemWidth, quantityWidth, priceWidth, amountWidth];
      _appendTableRow(
        lines,
        ['Item', columns == 30 ? 'Q/Unit' : 'Qty/Unit', 'Price', 'Total'],
        widths,
        rightAligned: const [false, true, true, true],
      );
      divider();
      for (final item in invoice.items) {
        _appendTableRow(
          lines,
          [
            item.productName,
            item.unit.isEmpty
                ? _displayQuantity(item.quantity)
                : '${_displayQuantity(item.quantity)} ${item.unit}',
            _formatUnitPrice(item.unitPrice),
            _formatMoney(item.lineTotal),
          ],
          widths,
          rightAligned: const [false, true, true, true],
        );
      }
    }

    divider();
    pair('Subtotal', _formatMoney(invoice.subtotal));
    pair('Discount', _formatMoney(invoice.discountAmount));
    pair('Amount after discount', '₹${_amountAfterDiscount(invoice)}');
    pair(
      'GST',
      invoice.gstEnabled ? _formatMoney(invoice.totalTax) : 'Disabled',
    );
    divider();
    pair('TOTAL', _formatMoney(invoice.grandTotal));
    pair('Total Items', _displayQuantity(_itemCount(invoice)));
    final paymentMethod = invoice.payments.isEmpty
        ? 'Not recorded'
        : invoice.payments
              .map(
                (payment) =>
                    '${payment.method.toUpperCase()} ${_formatMoney(payment.amount)}',
              )
              .join(' + ');
    pair('Payment method', paymentMethod);
    if (includeFooter) {
      divider();
      centered(testMode ? 'PRINTER TEST ONLY' : 'THANK YOU! VISIT US AGAIN!');
      if (invoice.businessAddress.isNotEmpty) {
        centered(invoice.businessAddress);
      }
      if (invoice.businessPhone.isNotEmpty) {
        centered(invoice.businessPhone);
      }
      lines.add('');
      centered('Developed By ZEROPOINT LABS');
      centered('www.zeropointlabs.in');
    }
    return List.unmodifiable(lines);
  }

  static String _amountAfterDiscount(SavedInvoice invoice) {
    final subtotalCents = _toCents(invoice.subtotal);
    final discountCents = _toCents(invoice.discountAmount);
    final amountCents = subtotalCents - discountCents;
    final sign = amountCents < 0 ? '-' : '';
    final absoluteCents = amountCents.abs();
    return '$sign${absoluteCents ~/ 100}.${(absoluteCents % 100).toString().padLeft(2, '0')}';
  }

  static void _appendTableRow(
    List<String> lines,
    List<String> values,
    List<int> widths, {
    required List<bool> rightAligned,
  }) {
    final cells = [
      for (var index = 0; index < values.length; index++)
        _wrap(values[index], widths[index]),
    ];
    final rowCount = cells
        .map((cell) => cell.length)
        .fold<int>(0, (count, length) => count > length ? count : length);
    for (var row = 0; row < rowCount; row++) {
      lines.add(
        List.generate(values.length, (column) {
          final value = row < cells[column].length ? cells[column][row] : '';
          return rightAligned[column]
              ? value.padLeft(widths[column])
              : value.padRight(widths[column]);
        }).join(' '),
      );
    }
  }

  static String _itemCount(SavedInvoice invoice) {
    final thousandths = invoice.items.fold<int>(
      0,
      (sum, item) =>
          sum + ((double.tryParse(item.quantity) ?? 0) * 1000).round(),
    );
    final whole = thousandths ~/ 1000;
    final fraction = (thousandths % 1000).abs();
    if (fraction == 0) return '$whole';
    final fractionalText = fraction.toString().padLeft(3, '0');
    return '$whole.${fractionalText.replaceFirst(RegExp(r'0+$'), '')}';
  }

  static String _displayQuantity(String value) {
    final quantity = double.tryParse(value);
    if (quantity == null || !quantity.isFinite) return value;
    return quantity.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static String _formatMoney(String value) {
    final match = RegExp(r'^(-?)(\d+)(?:\.(\d{1,2}))?$').firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid currency amount in receipt.', value);
    }

    return '₹${match.group(1)}${match.group(2)}.'
        '${(match.group(3) ?? '').padRight(2, '0')}';
  }

  static String _formatUnitPrice(String value) {
    final match = RegExp(r'^(-?)(\d+)(?:\.(\d{1,6}))?$').firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid unit price in receipt.', value);
    }
    var fraction = (match.group(3) ?? '').padRight(2, '0');
    while (fraction.length > 2 && fraction.endsWith('0')) {
      fraction = fraction.substring(0, fraction.length - 1);
    }
    return '₹${match.group(1)}${match.group(2)}.$fraction';
  }

  static int _toCents(String value) =>
      ((double.tryParse(value) ?? 0) * 100).round();

  static String _formatDate(String value) {
    final date = DateTime.parse(value).toLocal();
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$day-$month-${date.year} $hour:$minute';
  }

  static List<String> _wrap(String value, int width) {
    final words = value.trim().split(RegExp(r'\s+'));
    final lines = <String>[];
    var line = '';
    for (final word in words) {
      if (word.length > width) {
        if (line.isNotEmpty) {
          lines.add(line);
          line = '';
        }
        for (var start = 0; start < word.length; start += width) {
          final end = start + width < word.length ? start + width : word.length;
          lines.add(word.substring(start, end));
        }
      } else if (line.isEmpty) {
        line = word;
      } else if (line.length + word.length + 1 <= width) {
        line = '$line $word';
      } else {
        lines.add(line);
        line = word;
      }
    }
    if (line.isNotEmpty) lines.add(line);
    return lines;
  }
}
