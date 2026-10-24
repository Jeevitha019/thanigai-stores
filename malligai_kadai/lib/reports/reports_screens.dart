import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'reports_gateway.dart';
import 'report_xlsx.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key, required this.gateway});

  final ReportsGateway gateway;

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  late Future<DashboardData> _dashboard = _load();

  Future<DashboardData> _load() => widget.gateway.dashboard(DateTime.now());

  void _reload() {
    setState(() => _dashboard = _load());
  }

  Future<void> _open(Widget screen) {
    return Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            key: const Key('refreshDashboardButton'),
            tooltip: 'Refresh dashboard',
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<DashboardData>(
        future: _dashboard,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _ErrorPanel(
              message: _failureMessage(snapshot.error),
              onRetry: _reload,
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final dashboard = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Today · ${dashboard.date}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  _MetricCard(
                    label: "Today's sales",
                    value: '₹ ${dashboard.totalSales}',
                    icon: Icons.currency_rupee_rounded,
                  ),
                  _MetricCard(
                    label: 'Invoices',
                    value: '${dashboard.invoiceCount}',
                    icon: Icons.receipt_long_outlined,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'Payment summary',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ...dashboard.paymentSummary.map(
                (payment) => ListTile(
                  leading: Icon(_paymentIcon(payment.method)),
                  title: Text(_paymentLabel(payment.method)),
                  subtitle: Text('${payment.invoiceCount} invoice(s)'),
                  trailing: Text('₹ ${payment.amount}'),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('openSalesReportButton'),
                onPressed: () =>
                    _open(SalesReportsScreen(gateway: widget.gateway)),
                icon: const Icon(Icons.bar_chart_rounded),
                label: const Text('Sales reports'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class SalesReportsScreen extends StatefulWidget {
  const SalesReportsScreen({super.key, required this.gateway});

  final ReportsGateway gateway;

  @override
  State<SalesReportsScreen> createState() => _SalesReportsScreenState();
}

class _SalesReportsScreenState extends State<SalesReportsScreen> {
  late final DateTime _today = DateTime.now();
  late DateTime _start = DateTime(_today.year, _today.month);
  late DateTime _end = _today;
  late Future<SalesReportData> _report = _load();
  String? _excelSavePath;
  bool _updatingMonthlyWorkbooks = false;

  Future<SalesReportData> _load() => widget.gateway.sales(_start, _end);

  Future<void> _selectDate({required bool start}) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: start ? _start : _end,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 366)),
      helpText: start ? 'Select start date' : 'Select end date',
    );
    if (selected == null || !mounted) return;
    final nextStart = start ? selected : _start;
    final nextEnd = start ? _end : selected;
    if (nextStart.isAfter(nextEnd)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Start date must be on or before end date.'),
        ),
      );
      return;
    }
    setState(() {
      _start = nextStart;
      _end = nextEnd;
      _report = widget.gateway.sales(_start, _end);
    });
  }

  Future<void> _refreshReport() async {
    if (_start.isAfter(_end)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Start date must be on or before end date.'),
        ),
      );
      return;
    }
    setState(() => _report = _load());
  }

  Future<void> _exportExcel(SalesReportData report) async {
    try {
      await _saveExcel(
        context,
        encodeSalesReportXlsx(report),
        'thanigai-sales-${report.startDate}-to-${report.endDate}.xlsx',
        selectedPath: _excelSavePath,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create the Excel report: $error')),
        );
      }
    }
  }

  Future<void> _chooseExcelSaveLocation() async {
    try {
      const group = XTypeGroup(label: 'Excel workbook', extensions: ['xlsx']);
      final target = await getSaveLocation(
        suggestedName:
            'thanigai-sales-${_start.year}-${_start.month.toString().padLeft(2, '0')}.xlsx',
        acceptedTypeGroups: [group],
      );
      if (target == null || !mounted) return;
      setState(() {
        _excelSavePath = target.path.toLowerCase().endsWith('.xlsx')
            ? target.path
            : '${target.path}.xlsx';
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not choose an Excel save location: $error'),
          ),
        );
      }
    }
  }

  Future<void> _updateMonthlyWorkbooks() async {
    if (_start.isAfter(_end)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Start date must be on or before end date.'),
        ),
      );
      return;
    }
    if (_excelSavePath == null) {
      await _chooseExcelSaveLocation();
      if (!mounted || _excelSavePath == null) return;
    }
    final folder = File(_excelSavePath!).parent;
    setState(() => _updatingMonthlyWorkbooks = true);
    try {
      var month = DateTime(_start.year, _start.month);
      final lastMonth = DateTime(_end.year, _end.month);
      var updated = 0;
      final savedPaths = <String>[];
      while (!month.isAfter(lastMonth)) {
        final monthStart = month;
        final monthEnd = DateTime(
          month.year,
          month.month + 1,
        ).subtract(const Duration(days: 1));
        final report = await widget.gateway.sales(monthStart, monthEnd);
        final fileName =
            'thanigai-sales-${month.year}-${month.month.toString().padLeft(2, '0')}.xlsx';
        final path = '${folder.path}${Platform.pathSeparator}$fileName';
        await File(path)
            .writeAsBytes(encodeSalesReportXlsx(report), flush: true);
        savedPaths.add(path);
        updated++;
        month = DateTime(month.year, month.month + 1);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Updated $updated monthly workbook(s):\n${savedPaths.join('\n')}',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update monthly workbooks: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _updatingMonthlyWorkbooks = false);
    }
  }

  Future<void> _print(SalesReportData report) async {
    try {
      final reportFont = await _loadWindowsReportFont();
      final document = pw.Document();
      document.addPage(
        pw.MultiPage(
          theme: pw.ThemeData.withFont(base: reportFont, bold: reportFont),
          build: (_) => [
            pw.Text(
              'Thanigai Stores · Sales report',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Text('Period: ${report.startDate} to ${report.endDate}'),
            pw.Text(
              'Total sales: ${_formatCurrency(report.totalSales)} · Invoices: ${report.invoiceCount}',
            ),
            pw.SizedBox(height: 12),
            pw.TableHelper.fromTextArray(
              headers: ['Payment', 'Invoices', 'Amount'],
              data: report.paymentSummary
                  .map(
                    (row) => [
                      _paymentLabel(row.method),
                      '${row.invoiceCount}',
                      _formatCurrency(row.amount),
                    ],
                  )
                  .toList(),
            ),
            pw.SizedBox(height: 12),
            pw.TableHelper.fromTextArray(
              headers: [
                'Invoice',
                'Date',
                'Cashier',
                'Subtotal',
                'Discount',
                'GST',
                'Total',
                'Payment',
              ],
              data: report.invoices
                  .map(
                    (invoice) => [
                      invoice.invoiceNumber,
                      invoice.createdAt,
                      invoice.cashierName,
                      _formatCurrency(invoice.subtotal),
                      _formatCurrency(invoice.discountAmount),
                      _formatCurrency(invoice.totalTax),
                      _formatCurrency(invoice.grandTotal),
                      _invoicePaymentLabel(invoice),
                    ],
                  )
                  .toList(),
            ),
          ],
        ),
      );
      await Printing.layoutPdf(onLayout: (_) => document.save());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not prepare the sales report for printing.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales reports'),
        actions: [
          FutureBuilder<SalesReportData>(
            future: _report,
            builder: (context, snapshot) => Row(
              children: [
                IconButton(
                  key: const Key('exportSalesExcelButton'),
                  tooltip: 'Export report to Excel',
                  onPressed: snapshot.hasData
                      ? () => _exportExcel(snapshot.data!)
                      : null,
                  icon: const Icon(Icons.download_outlined),
                ),
                IconButton(
                  key: const Key('printSalesReportButton'),
                  tooltip: 'Print report',
                  onPressed: snapshot.hasData
                      ? () => _print(snapshot.data!)
                      : null,
                  icon: const Icon(Icons.print_outlined),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const Key('salesStartDateButton'),
                  onPressed: () => _selectDate(start: true),
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text('From ${_formatDate(_start)}'),
                ),
                OutlinedButton.icon(
                  key: const Key('salesEndDateButton'),
                  onPressed: () => _selectDate(start: false),
                  icon: const Icon(Icons.event_outlined),
                  label: Text('To ${_formatDate(_end)}'),
                ),
                OutlinedButton.icon(
                  key: const Key('chooseExcelSaveLocationButton'),
                  onPressed: _chooseExcelSaveLocation,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Choose Excel Save Location'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('updateMonthlyWorkbooksButton'),
                  onPressed: _updatingMonthlyWorkbooks
                      ? null
                      : _updateMonthlyWorkbooks,
                  icon: _updatingMonthlyWorkbooks
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.update_rounded),
                  label: const Text('Update Monthly Workbooks'),
                ),
              ],
            ),
          ),
          if (_excelSavePath != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Excel save location: $_excelSavePath'),
              ),
            ),
          Expanded(
            child: FutureBuilder<SalesReportData>(
              future: _report,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _ErrorPanel(
                    message: _failureMessage(snapshot.error),
                    onRetry: _refreshReport,
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final report = snapshot.data!;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        _MetricCard(
                          label: 'Sales',
                          value: '₹ ${report.totalSales}',
                          icon: Icons.currency_rupee_rounded,
                        ),
                        _MetricCard(
                          label: 'Invoices',
                          value: '${report.invoiceCount}',
                          icon: Icons.receipt_long_outlined,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Payment-method breakdown',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    ...report.paymentSummary.map(
                      (payment) => ListTile(
                        leading: Icon(_paymentIcon(payment.method)),
                        title: Text(_paymentLabel(payment.method)),
                        subtitle: Text('${payment.invoiceCount} invoice(s)'),
                        trailing: Text('₹ ${payment.amount}'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Invoices',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (report.invoices.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No invoices in this date range.'),
                      ),
                    ...report.invoices.map(
                      (invoice) => Card(
                        child: ExpansionTile(
                          key: Key('reportInvoice${invoice.id}'),
                          title: Text(invoice.invoiceNumber),
                          subtitle: Text(
                            '${invoice.createdAt} · ${invoice.cashierName} · ${_invoicePaymentLabel(invoice)}',
                          ),
                          trailing: Text('₹ ${invoice.grandTotal}'),
                          children: [
                            ListTile(
                              title: Text('Subtotal ₹ ${invoice.subtotal}'),
                              subtitle: Text(
                                'Discount ₹ ${invoice.discountAmount} · '
                                'GST ₹ ${invoice.totalTax}',
                              ),
                            ),
                            ...invoice.items.map(
                              (item) => ListTile(
                                title: Text(item.productName),
                                subtitle: Text(
                                  '${item.quantity} × ₹ ${item.unitPrice} · ${item.sku}',
                                ),
                                trailing: Text('₹ ${item.lineTotal}'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class AdminBackupScreen extends StatefulWidget {
  const AdminBackupScreen({super.key, required this.gateway});

  final ReportsGateway gateway;

  @override
  State<AdminBackupScreen> createState() => _AdminBackupScreenState();
}

class _AdminBackupScreenState extends State<AdminBackupScreen> {
  late Future<List<DatabaseBackup>> _backups = widget.gateway.listBackups();
  bool _working = false;

  Future<void> _reload() async {
    setState(() => _backups = widget.gateway.listBackups());
  }

  Future<void> _createBackup() async {
    setState(() => _working = true);
    try {
      final backup = await widget.gateway.createBackup();
      if (!mounted) return;
      setState(() => _backups = widget.gateway.listBackups());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup created: ${backup.fileName}')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_failureMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restore(DatabaseBackup backup) async {
    final phrase = 'RESTORE ${backup.fileName}';
    final confirmation = await showDialog<String>(
      context: context,
      builder: (_) => _RestoreConfirmationDialog(fileName: backup.fileName),
    );
    if (confirmation == null || confirmation != phrase || !mounted) return;

    setState(() => _working = true);
    try {
      await widget.gateway.restoreBackup(backup, confirmation);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Database restore completed. Restart the backend if needed.',
          ),
        ),
      );
      setState(() => _backups = widget.gateway.listBackups());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_failureMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Database backups'),
      actions: [
        IconButton(
          tooltip: 'Refresh backups',
          onPressed: _working ? null : _reload,
          icon: const Icon(Icons.refresh_rounded),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            'Backups are saved outside the project folder in the current Windows user profile. Keep a second copy on separate secure storage.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            key: const Key('createDatabaseBackupButton'),
            onPressed: _working ? null : _createBackup,
            icon: const Icon(Icons.backup_outlined),
            label: Text(_working ? 'Working…' : 'Create database backup'),
          ),
        ),
        if (_working) const LinearProgressIndicator(),
        Expanded(
          child: FutureBuilder<List<DatabaseBackup>>(
            future: _backups,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return _ErrorPanel(
                  message: _failureMessage(snapshot.error),
                  onRetry: _reload,
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.data!.isEmpty) {
                return const Center(child: Text('No database backups yet.'));
              }
              return ListView(
                children: snapshot.data!
                    .map(
                      (backup) => Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: ListTile(
                          leading: const Icon(Icons.archive_outlined),
                          title: Text(backup.fileName),
                          subtitle: Text(
                            '${backup.createdAt} · ${_formatBytes(backup.sizeBytes)}',
                          ),
                          trailing: FilledButton.tonalIcon(
                            key: Key('restore${backup.fileName}'),
                            onPressed: _working ? null : () => _restore(backup),
                            icon: const Icon(Icons.restore_rounded),
                            label: const Text('Restore'),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 280,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  const SizedBox(height: 4),
                  Text(value, style: Theme.of(context).textTheme.headlineSmall),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RestoreConfirmationDialog extends StatefulWidget {
  const _RestoreConfirmationDialog({required this.fileName});

  final String fileName;

  @override
  State<_RestoreConfirmationDialog> createState() =>
      _RestoreConfirmationDialogState();
}

class _RestoreConfirmationDialogState
    extends State<_RestoreConfirmationDialog> {
  final _controller = TextEditingController();
  String? _errorMessage;

  String get _phrase => 'RESTORE ${widget.fileName}';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    if (_controller.text != _phrase) {
      setState(
        () => _errorMessage = 'Type the exact confirmation phrase to continue.',
      );
      return;
    }
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Restore database backup?'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This replaces the current database contents, including users, products, invoices, payments, and settings. Create a fresh backup first if you may need the current data.',
          ),
          const SizedBox(height: 16),
          SelectableText('Type exactly: $_phrase'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('restoreConfirmationField'),
            controller: _controller,
            decoration: InputDecoration(
              labelText: 'Restore confirmation',
              errorText: _errorMessage,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('confirmRestoreButton'),
        onPressed: _confirm,
        child: const Text('Restore database'),
      ),
    ],
  );
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 40),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _saveExcel(
  BuildContext context,
  Uint8List bytes,
  String fileName, {
  String? selectedPath,
}) async {
  var savePath = selectedPath ?? '';
  try {
    if (savePath.isEmpty) {
      const group = XTypeGroup(label: 'Excel workbook', extensions: ['xlsx']);
      final target = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: [group],
      );
      if (target == null) return;
      savePath = target.path;
    }
    savePath = savePath.toLowerCase().endsWith('.xlsx')
        ? savePath
        : '$savePath.xlsx';
    await File(savePath).writeAsBytes(bytes, flush: true);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel report saved to $savePath')),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savePath.isEmpty
                ? 'Could not choose an Excel save location: $error'
                : 'Could not save the Excel report to $savePath: $error',
          ),
        ),
      );
    }
  }
}

String _failureMessage(Object? error) => error is ReportsFailure
    ? error.message
    : 'The request failed. Check the local API and database, then try again.';

String _formatDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String _paymentLabel(String method) => switch (method) {
  'cash' => 'Cash',
  'upi' => 'UPI',
  'card' => 'Card',
  'split' => 'Split',
  'unrecorded' => 'Unrecorded (legacy)',
  _ => method,
};

IconData _paymentIcon(String method) => switch (method) {
  'cash' => Icons.payments_outlined,
  'upi' => Icons.qr_code_2_rounded,
  'card' => Icons.credit_card_outlined,
  'split' => Icons.call_split_rounded,
  _ => Icons.help_outline_rounded,
};

Future<pw.Font> _loadWindowsReportFont() async {
  final windowsDirectory = Platform.environment['WINDIR'] ?? r'C:\Windows';
  final fontFile = File(
    '$windowsDirectory${Platform.pathSeparator}Fonts'
    '${Platform.pathSeparator}segoeui.ttf',
  );
  if (!await fontFile.exists()) {
    throw const FileSystemException(
      'The Windows Segoe UI font is unavailable.',
    );
  }
  return pw.Font.ttf(ByteData.sublistView(await fontFile.readAsBytes()));
}

String _formatCurrency(String amount) {
  final match = RegExp(r'^(\d+)(?:\.(\d{0,2}))?$').firstMatch(amount);
  if (match == null) {
    throw FormatException('Invalid currency amount in report data.', amount);
  }
  return '₹ ${match.group(1)}.${(match.group(2) ?? '').padRight(2, '0')}';
}

String _invoicePaymentLabel(SalesInvoiceReport invoice) =>
    invoice.paymentMethods.isEmpty
    ? 'Unrecorded (legacy)'
    : invoice.paymentMethods
          .map(
            (payment) =>
                '${_paymentLabel(payment.method)} ${_formatCurrency(payment.amount)}',
          )
          .join(' + ');

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
