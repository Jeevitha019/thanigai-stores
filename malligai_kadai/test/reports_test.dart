import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:malligai_kadai/reports/report_csv.dart';
import 'package:malligai_kadai/reports/reports_gateway.dart';
import 'package:malligai_kadai/reports/report_xlsx.dart';
import 'package:malligai_kadai/reports/reports_screens.dart';

class FakeReportsGateway implements ReportsGateway {
  String? restoredFile;
  String? restoreConfirmation;
  int backupCreateCalls = 0;

  DatabaseBackup get backup => const DatabaseBackup(
    fileName: 'malligai-kadai_20261019_120000_123e4567-e89b-12d3-a456-426614174000.dump',
    createdAt: '2026-10-19T12:00:00.000Z',
    sizeBytes: 1024,
  );

  @override
  Future<DashboardData> dashboard(DateTime date) async => DashboardData(
    date: '2026-10-19',
    totalSales: '125.50',
    invoiceCount: 4,
    stockProductCount: 2,
    paymentSummary: const [
      PaymentSummary(method: 'cash', invoiceCount: 1, amount: '25.50'),
      PaymentSummary(method: 'upi', invoiceCount: 1, amount: '30.00'),
      PaymentSummary(method: 'card', invoiceCount: 0, amount: '0.00'),
      PaymentSummary(method: 'split', invoiceCount: 2, amount: '70.00'),
      PaymentSummary(method: 'unrecorded', invoiceCount: 0, amount: '0.00'),
    ],
  );

  @override
  Future<SalesReportData> sales(DateTime start, DateTime end) async =>
      SalesReportData(
        startDate: '2026-10-19',
        endDate: '2026-10-19',
        totalSales: '125.50',
        invoiceCount: 1,
        paymentSummary: const [
          PaymentSummary(method: 'cash', invoiceCount: 1, amount: '125.50'),
        ],
        invoices: const [
          SalesInvoiceReport(
            id: '1',
            invoiceNumber: 'INV-2026-00000001',
            cashierName: 'till',
            createdAt: '2026-10-19T12:00:00.000Z',
            paidAt: '2026-10-19T12:00:05.000Z',
            gstEnabled: true,
            subtotal: '125.50',
            discountAmount: '0.00',
            totalTax: '0.00',
            grandTotal: '125.50',
            paymentMethods: [(method: 'cash', amount: '125.50')],
            items: [
              ReportInvoiceItem(
                productName: 'Rice',
                sku: 'RICE-1',
                unit: 'kg',
                quantity: '1.000',
                unitPrice: '125.50',
                lineTotal: '125.50',
              ),
            ],
          ),
        ],
      );

  @override
  Future<List<DatabaseBackup>> listBackups() async => [backup];

  @override
  Future<DatabaseBackup> createBackup() async {
    backupCreateCalls++;
    return backup;
  }

  @override
  Future<void> restoreBackup(DatabaseBackup backup, String confirmation) async {
    restoredFile = backup.fileName;
    restoreConfirmation = confirmation;
  }
}

void main() {
  test('CSV export keeps UTF-8, quotes fields, and escapes formulas', () {
    final csv = encodeReportCsv([
      ['Currency', 'Product', 'Notes'],
      ['₹ 12.50', '=2+2', 'Rice, "premium"\r\nstock'],
    ]);

    expect(csv.startsWith('\uFEFF'), isTrue);
    final encoded = utf8.encode(csv);
    expect(encoded.take(3).toList(), [0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(encoded.skip(3).toList()), csv.substring(1));
    expect(csv, contains('"₹ 12.50","\'=2+2","Rice, ""premium""\r\nstock"'));
  });

  test(
    'Excel export creates a valid workbook with typed report cells',
    () async {
      final report = await FakeReportsGateway().sales(
        DateTime(2026, 10, 1),
        DateTime(2026, 10, 31),
      );
      final workbook = ZipDecoder().decodeBytes(encodeSalesReportXlsx(report));
      final files = workbook.files.where((file) => file.isFile).toList();
      expect(
        files.map((file) => file.name),
        containsAll([
          '[Content_Types].xml',
          'xl/workbook.xml',
          'xl/styles.xml',
          'xl/worksheets/sheet1.xml',
          'xl/worksheets/sheet2.xml',
        ]),
      );

      final workbookXml = XmlDocument.parse(
        utf8.decode(workbook.findFile('xl/workbook.xml')!.content),
      );
      expect(
        workbookXml
            .findAllElements('sheet')
            .map((sheet) => sheet.getAttribute('name')),
        ['Monthly Summary', 'Orders'],
      );
      final summary = XmlDocument.parse(
        utf8.decode(workbook.findFile('xl/worksheets/sheet1.xml')!.content),
      );
      expect(
        summary
            .findAllElements('c')
            .singleWhere((cell) => cell.getAttribute('r') == 'B3')
            .findElements('v')
            .single
            .innerText,
        '125.5',
      );
      final orders = XmlDocument.parse(
        utf8.decode(workbook.findFile('xl/worksheets/sheet2.xml')!.content),
      );
      expect(
        orders
            .findAllElements('c')
            .singleWhere((cell) => cell.getAttribute('r') == 'B2')
            .getAttribute('s'),
        '6',
      );
      expect(
        orders
            .findAllElements('c')
            .singleWhere((cell) => cell.getAttribute('r') == 'D2')
            .getAttribute('s'),
        '2',
      );
      expect(
        orders
            .findAllElements('c')
            .singleWhere((cell) => cell.getAttribute('r') == 'G2')
            .getAttribute('s'),
        '1',
      );
      final orderHeaders = orders
          .findAllElements('row')
          .first
          .findElements('c')
          .map(
            (cell) =>
                cell.findElements('is').first.findElements('t').first.innerText,
          )
          .toList();
      expect(orderHeaders, [
        'Order No',
        'Date',
        'Time',
        'Paid At',
        'Table',
        'Items',
        'Subtotal',
        'Discount',
        'GST',
        'GST Status',
        'Final Total',
        'Payment Method',
        'Cash',
        'UPI',
        'Card',
      ]);
      expect(orders.findAllElements('col'), hasLength(15));
      expect(orders.findAllElements('pane').single.getAttribute('ySplit'), '1');
      expect(
        orders.findAllElements('autoFilter').single.getAttribute('ref'),
        'A1:O2',
      );
      expect(
        orders
            .findAllElements('c')
            .firstWhere((cell) => cell.getAttribute('r') == 'A1')
            .getAttribute('s'),
        '5',
      );
      final styles = XmlDocument.parse(
        utf8.decode(workbook.findFile('xl/styles.xml')!.content),
      );
      expect(
        styles
            .findAllElements('fill')
            .any(
              (fill) => fill
                  .findAllElements('fgColor')
                  .any((color) => color.getAttribute('rgb') == 'FF1F4E78'),
            ),
        isTrue,
      );
      expect(
        styles
            .findAllElements('font')
            .any(
              (font) => font
                  .findAllElements('color')
                  .any((color) => color.getAttribute('rgb') == 'FFFFFFFF'),
            ),
        isTrue,
      );
      expect(
        orders
            .findAllElements('c')
            .firstWhere((cell) => cell.getAttribute('r') == 'D2')
            .getAttribute('s'),
        '2',
      );
      expect(
        orders
            .findAllElements('c')
            .firstWhere((cell) => cell.getAttribute('r') == 'F2')
            .findElements('is')
            .single
            .findElements('t')
            .single
            .innerText,
        'Rice × 1.000 kg',
      );
      expect(
        orders
            .findAllElements('c')
            .firstWhere((cell) => cell.getAttribute('r') == 'J2')
            .findElements('is')
            .single
            .findElements('t')
            .single
            .innerText,
        'ON',
      );
      expect(
        orders
            .findAllElements('c')
            .firstWhere((cell) => cell.getAttribute('r') == 'M2')
            .findElements('v')
            .single
            .innerText,
        '125.5',
      );
    },
  );

  testWidgets('dashboard displays daily sales, invoices, and payment summary', (
    tester,
  ) async {
    final gateway = FakeReportsGateway();
    await tester.pumpWidget(
      MaterialApp(home: AdminDashboardScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    expect(find.text("Today's sales"), findsOneWidget);
    expect(find.text('₹ 125.50'), findsOneWidget);
    expect(find.text('Invoices'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('Split'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('openSalesReportButton')),
      250,
    );
    expect(find.byKey(const Key('openSalesReportButton')), findsOneWidget);
  });

  testWidgets(
    'sales report displays saved invoice items and supports date filters',
    (tester) async {
      final gateway = FakeReportsGateway();
      await tester.pumpWidget(
        MaterialApp(home: SalesReportsScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('INV-2026-00000001'), 250);
      await tester.tap(find.text('INV-2026-00000001'));
      await tester.pumpAndSettle();
      expect(find.text('INV-2026-00000001'), findsOneWidget);
      expect(find.text('Rice'), findsOneWidget);
      expect(find.byKey(const Key('salesStartDateButton')), findsOneWidget);
      expect(find.byKey(const Key('runSalesReportButton')), findsNothing);
      expect(find.byKey(const Key('exportSalesExcelButton')), findsOneWidget);
      expect(
        find.byKey(const Key('chooseExcelSaveLocationButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('updateMonthlyWorkbooksButton')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('openInventoryReportButton')), findsNothing);
      await tester.tap(find.byKey(const Key('salesStartDateButton')));
      await tester.pumpAndSettle();
      expect(find.text('Select start date'), findsOneWidget);
    },
  );

  testWidgets('restore requires typing the exact explicit confirmation', (
    tester,
  ) async {
    final gateway = FakeReportsGateway();
    await tester.pumpWidget(
      MaterialApp(home: AdminBackupScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    final restoreButton = find.byKey(Key('restore${gateway.backup.fileName}'));
    await tester.tap(restoreButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmRestoreButton')));
    await tester.pumpAndSettle();
    expect(gateway.restoredFile, isNull);

    await tester.enterText(
      find.byKey(const Key('restoreConfirmationField')),
      'RESTORE ${gateway.backup.fileName}',
    );
    await tester.tap(find.byKey(const Key('confirmRestoreButton')));
    await tester.pumpAndSettle();
    expect(gateway.restoredFile, gateway.backup.fileName);
    expect(gateway.restoreConfirmation, 'RESTORE ${gateway.backup.fileName}');
  });
}
