import 'package:flutter/material.dart';

import 'billing_gateway.dart';
import 'receipt_preview_screen.dart';
import 'receipt_printer.dart';

class InvoiceHistoryScreen extends StatefulWidget {
  const InvoiceHistoryScreen({
    super.key,
    required this.billingGateway,
    required this.printerGateway,
    this.canManage = false,
  });

  final BillingGateway billingGateway;
  final ReceiptPrinterGateway printerGateway;
  final bool canManage;

  @override
  State<InvoiceHistoryScreen> createState() => _InvoiceHistoryScreenState();
}

class _InvoiceHistoryScreenState extends State<InvoiceHistoryScreen> {
  List<SavedInvoice> _invoices = [];
  bool _loading = true;
  String? _error;
  final Set<String> _busyInvoiceIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final invoices = await widget.billingGateway.listInvoices();
      if (mounted) {
        setState(() {
          _invoices = invoices;
          _loading = false;
        });
      }
    } on BillingFailure catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not load saved invoices.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _printAgain(SavedInvoice listedInvoice) async {
    try {
      final invoice = await widget.billingGateway.findInvoiceById(
        listedInvoice.id,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => ReceiptPreviewScreen(
          invoice: invoice,
          printerGateway: widget.printerGateway,
        ),
      );
    } on BillingFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the saved invoice.')),
        );
      }
    }
  }

  Future<void> _deleteInvoice(SavedInvoice invoice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete invoice?'),
        content: Text(
          'Delete ${invoice.invoiceNumber}? It will be voided, not erased. '
          'The invoice and paid payment records remain in audit history, but '
          'it is removed from invoice history and excluded from sales and '
          'payment reports. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep invoice'),
          ),
          FilledButton(
            key: Key('confirmDeleteInvoiceButton-${invoice.id}'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete and void'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyInvoiceIds.add(invoice.id));
    try {
      await widget.billingGateway.voidInvoice(invoice.id);
      if (!mounted) return;
      setState(() => _busyInvoiceIds.remove(invoice.id));
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Invoice voided. It remains in audit history and is excluded from reports.',
          ),
        ),
      );
    } on BillingFailure catch (error) {
      if (mounted) {
        setState(() => _busyInvoiceIds.remove(invoice.id));
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busyInvoiceIds.remove(invoice.id));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not void the invoice.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved invoices'),
        actions: [
          IconButton(
            key: const Key('refreshInvoiceHistoryButton'),
            tooltip: 'Refresh invoices',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  TextButton(onPressed: _load, child: const Text('Try again')),
                ],
              ),
            )
          : _invoices.isEmpty
          ? const Center(child: Text('No saved invoices yet.'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _invoices.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final invoice = _invoices[index];
                return Card(
                  child: ListTile(
                    key: Key('savedInvoice-${invoice.id}'),
                    title: Text(invoice.invoiceNumber),
                    subtitle: Text(
                      '${invoice.cashierName} · ${invoice.createdAt}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('₹ ${invoice.grandTotal}'),
                        if (widget.canManage)
                          IconButton(
                            key: Key('deleteInvoice-${invoice.id}'),
                            tooltip: 'Delete ${invoice.invoiceNumber}',
                            onPressed: _busyInvoiceIds.contains(invoice.id)
                                ? null
                                : () => _deleteInvoice(invoice),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        IconButton(
                          key: Key('printAgainInvoice-${invoice.id}'),
                          tooltip: 'Print Again ${invoice.invoiceNumber}',
                          onPressed: _busyInvoiceIds.contains(invoice.id)
                              ? null
                              : () => _printAgain(invoice),
                          icon: const Icon(Icons.print_outlined),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
