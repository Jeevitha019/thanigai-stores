import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malligai_kadai/billing/billing_gateway.dart';
import 'package:malligai_kadai/billing/receipt_formatter.dart';
import 'package:malligai_kadai/billing/receipt_printer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const invoice = SavedInvoice(
    id: '17',
    invoiceNumber: 'INV-2026-00000017',
    cashierName: 'cashier-one',
    businessAddress: '12 Test Street, Chennai',
    businessPhone: '+91 98765 43210',
    subtotal: '10.00',
    grandTotal: '10.50',
    taxableAmount: '10.00',
    cgstAmount: '0.25',
    sgstAmount: '0.25',
    totalTax: '0.50',
    gstEnabled: true,
    priceMode: 'exclusive',
    shopStateCode: '33',
    saleStateCode: '33',
    createdAt: '2026-10-19T12:30:00.000Z',
    items: [
      SavedInvoiceItem(
        productName: 'Basmati Rice',
        sku: 'RICE-001',
        unit: 'kg',
        unitPrice: '10.00',
        quantity: '1',
        lineTotal: '10.50',
        gstRate: '5.00',
        taxableAmount: '10.00',
        cgstAmount: '0.25',
        sgstAmount: '0.25',
      ),
    ],
    payments: [
      InvoicePayment(method: 'cash', amount: '4.00'),
      InvoicePayment(method: 'upi', amount: '6.50'),
    ],
    replayed: false,
  );

  test('formats the receipt-roll layout, calculations, and branding', () {
    final lines = ReceiptFormatter.format(invoice, paperWidthMm: 80);
    final receipt = lines.join('\n');

    expect(receipt, contains('THANIGAI STORES'));
    for (final width in [58, 80]) {
      final header = ReceiptFormatter.format(
        invoice,
        paperWidthMm: width,
      ).first;
      expect(header.trim(), 'THANIGAI STORES');
      expect(
        header.indexOf('THANIGAI STORES'),
        ((width == 58 ? 30 : 44) - 'THANIGAI STORES'.length) ~/ 2,
      );
    }
    expect(receipt, contains('Bill No'));
    expect(receipt, contains('INV-2026-00000017'));
    expect(receipt, contains('cashier-one'));
    expect(receipt, contains('Item'));
    expect(receipt, contains('Qty'));
    expect(receipt, contains('Price'));
    expect(receipt, contains('Total'));
    expect(receipt, contains('Basmati Rice'));
    expect(receipt, contains('₹10.00'));
    expect(receipt, isNot(contains('Amount after discount')));
    expect(receipt, contains('GST'));
    expect(receipt, contains('₹0.50'));
    expect(receipt, isNot(contains('CGST')));
    expect(receipt, isNot(contains('SGST')));
    expect(receipt, contains('TOTAL'));
    expect(receipt, contains('₹10.50'));
    expect(receipt, contains('Total Items'));
    expect(receipt, contains('Payment method'));
    expect(receipt, contains('CASH ₹4.00 + UPI ₹6.50'));
    expect(receipt, isNot(contains('Discount')));
    expect(receipt, contains('TOTAL  ₹10.50'));
    expect(receipt, isNot(contains('1 kg')));
    expect(receipt, contains('THANK YOU! VISIT US AGAIN!!'));
    expect(receipt, contains('12 Test Street, Chennai'));
    expect(receipt, contains('+91 98765 43210'));
    expect(receipt, contains('Developed By ZEROPOINT LABS'));
    expect(receipt, contains('www.zeropointlabs.in'));
    expect(lines.every((line) => line.length <= 44), isTrue);
    final footerStart = lines.indexWhere(
      (line) => line.trim() == 'THANK YOU! VISIT US AGAIN!!',
    );
    expect(footerStart, greaterThan(0));
    expect(lines.skip(footerStart).map((line) => line.trim()).toList(), [
      'THANK YOU! VISIT US AGAIN!!',
      '12 Test Street, Chennai',
      '+91 98765 43210',
      '',
      'Developed By ZEROPOINT LABS',
      'www.zeropointlabs.in',
    ]);
  });

  test('formats proportional unit prices with enough precision', () {
    final lines = ReceiptFormatter.format(
      SavedInvoice(
        invoiceNumber: 'INV-PROPORTIONAL',
        subtotal: '1.00',
        grandTotal: '1.00',
        createdAt: '2026-10-19T12:30:00.000Z',
        items: const [
          SavedInvoiceItem(
            productName: 'Rice',
            sku: '',
            unit: 'g',
            unitPrice: '0.033333',
            quantity: '30',
            lineTotal: '1.00',
          ),
        ],
        payments: const [InvoicePayment(method: 'cash', amount: '1.00')],
        replayed: false,
      ),
      paperWidthMm: 80,
    );

    expect(lines.join('\n'), contains('₹0.033333'));
  });

  test('wraps long product names without shifting receipt amount columns', () {
    const longNameInvoice = SavedInvoice(
      invoiceNumber: 'INV-LONG-1',
      subtotal: '80.00',
      grandTotal: '80.00',
      createdAt: '2026-10-19T12:30:00.000Z',
      items: [
        SavedInvoiceItem(
          productName: 'Organic Traditional Appalam Papad Special Pack XL',
          sku: 'APPALAM-1',
          unit: 'kg',
          unitPrice: '80.00',
          quantity: '1',
          lineTotal: '80.00',
        ),
      ],
      payments: [InvoicePayment(method: 'cash', amount: '80.00')],
      replayed: false,
    );

    for (final width in [58, 80]) {
      final lines = ReceiptFormatter.format(
        longNameInvoice,
        paperWidthMm: width,
      );
      final columns = width == 58 ? 30 : 44;
      final itemIndex = lines.indexWhere(
        (line) => line.trimLeft().startsWith('Organic'),
      );
      expect(itemIndex, greaterThanOrEqualTo(0));
      final rowLines = lines
          .skip(itemIndex)
          .takeWhile((line) => !line.startsWith('-'));
      expect(rowLines.length, greaterThan(1));
      expect(rowLines.every((line) => line.length == columns), isTrue);
      expect(rowLines.first, contains('80.00'));
      expect(rowLines.first, contains('₹80.00'));
      expect(lines.any((line) => line.contains('THANIGAI STORES')), isTrue);
    }
  });

  test('formats an A4 receipt like the supplied bill example', () {
    final lines = ReceiptFormatter.formatA4(invoice);
    final receipt = lines.join('\n');

    expect(receipt, contains('THANIGAI STORES'));
    expect(receipt, contains('Invoice No: INV-2026-00000017'));
    expect(receipt, contains('Date:'));
    expect(receipt, contains('Cashier: cashier-one'));
    expect(receipt, contains('Qty / Unit Price'));
    expect(receipt, contains('Basmati Rice'));
    expect(receipt, contains('1 kg x ₹10.00'));
    expect(receipt, contains('Amount after discount'));
    expect(receipt, contains('Payment method'));
    expect(receipt, contains('CASH ₹4.00 + UPI ₹6.50'));
    expect(receipt, contains('Total Items'));
    expect(
      lines.every((line) => line.length <= ReceiptFormatter.a4Columns),
      isTrue,
    );
    final invoiceDateLine = lines.singleWhere(
      (line) => line.contains('Invoice No:'),
    );
    expect(invoiceDateLine, contains('Date:'));
    final columnHeader = lines.singleWhere(
      (line) => line.contains('Qty / Unit Price'),
    );
    expect(columnHeader.length, ReceiptFormatter.a4Columns);
    expect(columnHeader.indexOf('Qty / Unit Price'), 42);
    expect(columnHeader.indexOf('Amount'), 74);
    final itemLine = lines.singleWhere((line) => line.contains('Basmati Rice'));
    expect(itemLine.indexOf('Basmati Rice'), 0);
    expect(itemLine.indexOf('1 kg x ₹10.00'), 42);
    expect(itemLine.indexOf('₹10.50'), 74);
    expect(lines.where((line) => line.startsWith('-')).length, 6);
    expect(
      ReceiptFormatter.formatA4Footer(invoice).join('\n'),
      contains('THANK YOU! VISIT US AGAIN!!'),
    );
    expect(
      ReceiptFormatter.formatA4Footer(invoice).join('\n'),
      contains('Developed By ZEROPOINT LABS'),
    );
  });

  test('shows the amount after subtracting the saved discount', () {
    const discountedInvoice = SavedInvoice(
      invoiceNumber: 'INV-DISCOUNT-1',
      subtotal: '12.00',
      discountAmount: '2.00',
      grandTotal: '10.00',
      createdAt: '2026-10-19T12:30:00.000Z',
      items: [],
      replayed: false,
    );

    final thermalLines = ReceiptFormatter.format(
      discountedInvoice,
      paperWidthMm: 80,
      printableWidthMm: 72,
    );
    expect(thermalLines.join('\n'), contains('Discount'));
    expect(thermalLines.join('\n'), contains('TOTAL  ₹10.00'));
    expect(thermalLines.join('\n'), isNot(contains('Amount after discount')));

    final lines = ReceiptFormatter.formatA4(discountedInvoice);
    final amountAfterDiscount = lines.singleWhere(
      (line) => line.contains('Amount after discount'),
    );

    expect(amountAfterDiscount.trimRight(), endsWith('₹10.00'));
  });

  test('omits GST and discount when they do not apply to a receipt', () {
    const untaxed = SavedInvoice(
      invoiceNumber: 'INV-OLD-1',
      cashierName: 'legacy-cashier',
      subtotal: '4.00',
      grandTotal: '4.00',
      createdAt: '2026-10-19T12:30:00.000Z',
      items: [
        SavedInvoiceItem(
          productName: 'Tea',
          sku: 'TEA',
          unit: 'packet',
          unitPrice: '4.00',
          quantity: '1',
          lineTotal: '4.00',
        ),
      ],
      replayed: false,
    );

    final receipt = ReceiptFormatter.format(
      untaxed,
      paperWidthMm: 58,
    ).join('\n');

    expect(receipt, isNot(contains('GST')));
    expect(receipt, isNot(contains('Discount')));
    expect(receipt, isNot(contains('CGST')));
    expect(receipt, isNot(contains('SGST')));
    expect(receipt, isNot(contains('IGST')));
  });

  test(
    'uses a narrower line width for 58mm receipts and marks test prints',
    () {
      final narrow = ReceiptFormatter.format(
        invoice,
        paperWidthMm: 58,
        testMode: true,
      );
      final wide = ReceiptFormatter.format(invoice, paperWidthMm: 80);

      expect(narrow.every((line) => line.length <= 30), isTrue);
      expect(wide.every((line) => line.length <= 44), isTrue);
      expect(narrow.join('\n'), contains('THANIGAI STORES'));
      expect(wide.join('\n'), contains('THANIGAI STORES'));
      expect(narrow.join('\n'), contains('PRINTER TEST - NOT A SALE'));
      expect(wide.join('\n'), isNot(contains('PRINTER TEST - NOT A SALE')));
      expect(
        () => ReceiptFormatter.format(invoice, paperWidthMm: 60),
        throwsArgumentError,
      );
    },
  );

  test('uses 72mm as the printable layout target on an 80mm roll', () {
    final lines = ReceiptFormatter.format(
      invoice,
      paperWidthMm: 80,
      printableWidthMm: 72,
    );

    expect(lines.every((line) => line.length <= 44), isTrue);
    expect(lines.join('\n'), contains('THANIGAI STORES'));
    expect(
      () => ReceiptFormatter.format(
        invoice,
        paperWidthMm: 80,
        printableWidthMm: 80.1,
      ),
      throwsArgumentError,
    );
    expect(
      () => ReceiptFormatter.format(
        invoice,
        paperWidthMm: 80,
        printableWidthMm: 39.9,
      ),
      throwsArgumentError,
    );
  });

  test(
    'aligns units and money for short and wrapped multi-item rows',
    () async {
      const testInvoice = SavedInvoice(
        invoiceNumber: 'PRINTER-TEST',
        cashierName: 'Test mode',
        subtotal: '68.00',
        discountAmount: '5.00',
        taxableAmount: '63.00',
        cgstAmount: '1.58',
        sgstAmount: '1.57',
        totalTax: '3.15',
        gstEnabled: true,
        grandTotal: '66.15',
        createdAt: '2026-10-19T12:30:00.000Z',
        items: [
          SavedInvoiceItem(
            productName: 'Basmati Rice',
            sku: 'TEST-RICE',
            unit: 'kg',
            unitPrice: '25.00',
            quantity: '2',
            lineTotal: '50.00',
          ),
          SavedInvoiceItem(
            productName: 'Organic Traditional Appalam Papad Special Pack XL',
            sku: 'TEST-APPALAM',
            unit: 'pack',
            unitPrice: '12.00',
            quantity: '1',
            lineTotal: '12.00',
          ),
          SavedInvoiceItem(
            productName: 'Tea Powder',
            sku: 'TEST-TEA',
            unit: 'packet',
            unitPrice: '2.00',
            quantity: '3',
            lineTotal: '6.00',
          ),
        ],
        payments: [
          InvoicePayment(method: 'cash', amount: '20.00'),
          InvoicePayment(method: 'upi', amount: '46.15'),
        ],
        replayed: false,
      );

      for (final width in [58, 80]) {
        final columns = width == 58 ? 30 : 44;
        final lines = ReceiptFormatter.format(
          testInvoice,
          paperWidthMm: width,
          printableWidthMm: width == 58 ? 50 : 72,
          testMode: true,
        );
        final longNameIndex = lines.indexWhere(
          (line) => line.trimLeft().startsWith('Organic'),
        );
        final longNameRows = lines
            .skip(longNameIndex)
            .takeWhile((line) => !line.startsWith('-'));
        final riceRow = lines.singleWhere(
          (line) => line.contains('Basmati') && line.contains('₹50.00'),
        );
        final receipt = lines.join('\n');
        final pdfBytes = await WindowsReceiptPrinterGateway().buildPdf(
          testInvoice,
          paperWidthMm: width,
          printableWidthMm: width == 58 ? 50 : 72,
          testMode: true,
        );
        final mediaBox = RegExp(r'/MediaBox\s*\[0 0 ([\d.]+) ([\d.]+)\]')
            .firstMatch(String.fromCharCodes(pdfBytes));
        expect(longNameIndex, greaterThanOrEqualTo(0));
        expect(longNameRows.length, greaterThan(1));
        expect(longNameRows.every((line) => line.length == columns), isTrue);
        expect(riceRow, contains('  2 '));
        expect(riceRow, isNot(contains('kg')));
        expect(riceRow, contains('₹25.00'));
        expect(riceRow.trimRight(), endsWith('₹50.00'));
        expect(receipt, contains('₹5.00'));
        expect(receipt, contains('₹3.15'));
        expect(receipt, contains('₹66.15'));
        expect(receipt, contains('CASH ₹20.00 + UPI ₹46.15'));
        expect(lines.every((line) => line.length <= columns), isTrue);
        expect(mediaBox, isNotNull);
        expect(
          double.parse(mediaBox!.group(1)!),
          closeTo(width * 72 / 25.4, 0.01),
        );
        expect(double.parse(mediaBox.group(2)!), lessThan(300 * 72 / 25.4));
      }
    },
  );

  test('builds a PDF receipt for either thermal roll width', () async {
    final printer = WindowsReceiptPrinterGateway();
    for (final width in [58, 80]) {
      final printableWidth = width == 80 ? 72.0 : 50.0;
      final bytes = await printer.buildPdf(
        invoice,
        paperWidthMm: width,
        printableWidthMm: printableWidth,
      );
      expect(bytes.length, greaterThan(100));
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      final pdfText = String.fromCharCodes(bytes);
      final mediaBox = RegExp(r'/MediaBox\s*\[0 0 ([\d.]+) ([\d.]+)\]')
          .firstMatch(pdfText);
      expect(mediaBox, isNotNull);
      expect(
        double.parse(mediaBox!.group(1)!),
        closeTo(width * 72 / 25.4, 0.01),
      );
      expect(
        double.parse(mediaBox.group(2)!),
        lessThan(650),
        reason: 'The receipt PDF should end shortly after its contents.',
      );
    }
  });

  test(
    'preserves thermal logo transparency and colors in the receipt PDF',
    () async {
      final logoData = await rootBundle.load(
        'assets/thanigai_stores_receipt_logo_transparent.png',
      );
      final codec = await ui.instantiateImageCodec(
        logoData.buffer.asUint8List(),
      );
      final logo = (await codec.getNextFrame()).image;
      final rgba = (await logo.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int channel(int x, int y, int offset) =>
          rgba.getUint8((y * logo.width + x) * 4 + offset);

      expect(channel(0, 0, 3), 0);
      expect(channel(logo.width - 1, 0, 3), 0);
      expect(channel(0, logo.height - 1, 3), 0);
      expect(channel(150, 130, 0), 252);
      expect(channel(150, 130, 1), 239);
      expect(channel(150, 130, 2), 36);
      expect(channel(150, 130, 3), 255);
      logo.dispose();
      codec.dispose();

      final pdf = await WindowsReceiptPrinterGateway().buildPdf(
        invoice,
        paperWidthMm: 80,
        printableWidthMm: 72,
      );
      expect(String.fromCharCodes(pdf), contains('/SMask'));
    },
  );

  test('builds a separate A4 invoice PDF', () async {
    final bytes = await WindowsReceiptPrinterGateway().buildPdf(
      invoice,
      paperWidthMm: 80,
      a4Invoice: true,
    );

    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(
      String.fromCharCodes(bytes).contains(RegExp(r'/MediaBox\s*\[0 0 595')),
      isTrue,
    );
  });

  test('renders non-Latin item snapshots into the receipt PDF', () async {
    const tamilInvoice = SavedInvoice(
      invoiceNumber: 'INV-TAMIL-1',
      cashierName: 'cashier',
      subtotal: '2.00',
      grandTotal: '2.00',
      createdAt: '2026-10-19T12:30:00.000Z',
      items: [
        SavedInvoiceItem(
          productName: 'அரிசி',
          sku: 'RICE',
          unit: 'kg',
          unitPrice: '2.00',
          quantity: '1',
          lineTotal: '2.00',
        ),
      ],
      replayed: false,
    );

    final bytes = await WindowsReceiptPrinterGateway().buildPdf(
      tamilInvoice,
      paperWidthMm: 58,
    );

    expect(bytes.length, greaterThan(100));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });
}
