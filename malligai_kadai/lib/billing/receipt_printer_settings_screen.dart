import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'billing_gateway.dart';
import 'receipt_printer.dart';

class ReceiptPrinterSettingsScreen extends StatefulWidget {
  const ReceiptPrinterSettingsScreen({super.key, required this.gateway});

  final ReceiptPrinterGateway gateway;

  @override
  State<ReceiptPrinterSettingsScreen> createState() =>
      _ReceiptPrinterSettingsScreenState();
}

class _ReceiptPrinterSettingsScreenState
    extends State<ReceiptPrinterSettingsScreen> {
  List<InstalledReceiptPrinter> _printers = [];
  ReceiptPrinterSettings? _settings;
  String? _selectedUrl;
  int _paperWidthMm = ReceiptPrinterSettings.defaultPaperWidthMm;
  double _printableWidthMm =
      ReceiptPrinterSettings.defaultPrintableWidthMm;
  final TextEditingController _printableWidthController =
      TextEditingController(text: '72.0');
  bool _a4Invoices = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await widget.gateway.loadSettings();
      final printers = await widget.gateway.listPrinters();
      if (!mounted) return;
      final savedPrinterExists = printers.any(
        (printer) => printer.url == settings?.printerUrl,
      );
      final defaultPrinter = printers.where((printer) => printer.isDefault);
      final printerUrl = savedPrinterExists
          ? settings!.printerUrl
          : defaultPrinter.isNotEmpty
          ? defaultPrinter.first.url
          : printers.isNotEmpty
          ? printers.first.url
          : null;
      setState(() {
        _settings = settings;
        _printers = printers;
        _selectedUrl = printerUrl;
        _paperWidthMm = settings?.paperWidthMm ?? 80;
        _printableWidthMm =
            settings?.targetPrintableWidthMm ??
            ReceiptPrinterSettings.defaultPrintableWidthMm;
        _printableWidthController.text = _printableWidthMm.toStringAsFixed(1);
        _a4Invoices = settings?.a4Invoices ?? false;
        _loading = false;
      });
    } on ReceiptPrinterFailure catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not read installed Windows printers.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final printableWidthMm = double.tryParse(
      _printableWidthController.text.trim(),
    );
    if (printableWidthMm == null ||
        !printableWidthMm.isFinite ||
        printableWidthMm < ReceiptPrinterSettings.minimumPrintableWidthMm ||
        printableWidthMm > _paperWidthMm) {
      setState(
        () => _error =
            'Enter a printable target width from ${ReceiptPrinterSettings.minimumPrintableWidthMm.toStringAsFixed(0)} to $_paperWidthMm mm.',
      );
      return;
    }
    final selected = _printers.where((printer) => printer.url == _selectedUrl);
    if (selected.isEmpty) {
      setState(() => _error = 'Select an installed Windows printer.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final printer = selected.first;
      final settings = ReceiptPrinterSettings(
        printerName: printer.name,
        printerUrl: printer.url,
        paperWidthMm: _paperWidthMm,
        printableWidthMm: printableWidthMm,
        a4Invoices: _a4Invoices,
      );
      await widget.gateway.saveSettings(settings);
      if (mounted) {
        setState(() => _settings = settings);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Receipt printer settings saved locally.'),
          ),
        );
      }
    } on ReceiptPrinterFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save local printer settings.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _printableWidthController.dispose();
    super.dispose();
  }

  Future<void> _printTest() async {
    const testInvoice = SavedInvoice(
      invoiceNumber: 'PRINTER-TEST',
      cashierName: 'Test mode',
      subtotal: '1.00',
      taxableAmount: '1.00',
      grandTotal: '1.00',
      createdAt: '2026-01-01T12:00:00.000Z',
      items: [
        SavedInvoiceItem(
          productName: 'Printer test - not a sale',
          sku: 'TEST',
          unit: 'piece',
          unitPrice: '1.00',
          quantity: '1',
          lineTotal: '1.00',
        ),
      ],
      payments: [InvoicePayment(method: 'cash', amount: '1.00')],
      replayed: false,
    );
    try {
      final completed = await widget.gateway.printReceipt(
        testInvoice,
        testMode: true,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              completed
                  ? 'Test receipt sent. It is not a sale.'
                  : 'Test print was cancelled.',
            ),
          ),
        );
      }
    } on ReceiptPrinterFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not send the printer test receipt.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receipt printer settings'),
        actions: [
          IconButton(
            key: const Key('refreshReceiptPrintersButton'),
            tooltip: 'Refresh installed printers',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        const Text(
                          'Choose a printer installed in Windows. Printing uses its driver; no USB or ESC/POS protocol is assumed.',
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Paper roll size and printable layout width are separate. The 72 mm RTP-81 value is a target based on the advertised print width, not a verified Windows driver area. Adjust this target after installing the printer and checking its paper form.',
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          key: const Key('receiptPrinterDropdown'),
                          initialValue: _selectedUrl,
                          decoration: const InputDecoration(
                            labelText: 'Windows printer',
                            border: OutlineInputBorder(),
                          ),
                          items: _printers
                              .map(
                                (printer) => DropdownMenuItem(
                                  value: printer.url,
                                  child: Text(
                                    '${printer.name}'
                                    '${printer.isDefault ? ' (default)' : ''}'
                                    '${printer.isAvailable ? '' : ' (offline/unavailable)'}',
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _selectedUrl = value),
                        ),
                        if (_printers.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                              'No Windows printers were found. Install the manufacturer driver and refresh this list.',
                            ),
                          ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          key: const Key('receiptPaperWidthDropdown'),
                          initialValue: _paperWidthMm,
                          decoration: const InputDecoration(
                            labelText: 'Receipt paper roll size',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 58, child: Text('58 mm')),
                            DropdownMenuItem(value: 80, child: Text('80 mm')),
                          ],
                          onChanged: _saving
                              ? null
                              : (value) {
                                  if (value != null) {
                                    setState(() {
                                      _paperWidthMm = value;
                                      if (_printableWidthMm > value) {
                                        _printableWidthMm =
                                            value.toDouble() - 8;
                                        _printableWidthController.text =
                                            _printableWidthMm.toStringAsFixed(
                                              1,
                                            );
                                      }
                                    });
                                  }
                                },
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          key: const Key('receiptPrintableWidthField'),
                          controller: _printableWidthController,
                          enabled: !_saving,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d{0,2}(?:\.\d?)?$'),
                            ),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Printable layout target (mm)',
                            helperText:
                                'Default 72 mm is an advertised target, not measured driver printable width.',
                            suffixText: 'mm',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (value) {
                            final parsed = double.tryParse(value);
                            if (parsed != null && parsed.isFinite) {
                              setState(() => _printableWidthMm = parsed);
                            }
                          },
                        ),
                        SwitchListTile(
                          key: const Key('a4InvoicePrintingSwitch'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Print invoices on A4 paper'),
                          subtitle: const Text(
                            'Off keeps the selected thermal receipt roll format.',
                          ),
                          value: _a4Invoices,
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _a4Invoices = value),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _settings == null
                              ? 'Settings are stored on this Windows PC.'
                              : 'Selected: ${_settings!.printerName}, '
                                    '${_settings!.a4Invoices ? 'A4 invoices' : '${_settings!.paperWidthMm} mm roll / ${_settings!.targetPrintableWidthMm.toStringAsFixed(1)} mm printable target'}.',
                        ),
                        const SizedBox(height: 16),
                        if (_error != null) ...[
                          Text(
                            _error!,
                            key: const Key('receiptPrinterError'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        FilledButton(
                          key: const Key('saveReceiptPrinterSettingsButton'),
                          onPressed: _saving || _printers.isEmpty
                              ? null
                              : _save,
                          child: Text(
                            _saving ? 'Saving…' : 'Save printer settings',
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('printTestReceiptButton'),
                          onPressed: _saving || _settings == null
                              ? null
                              : _printTest,
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('Print test receipt'),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
