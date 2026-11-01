import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'product_gateway.dart';
import 'product_xlsx.dart';
import 'sample_product_importer.dart';

class ProductScreen extends StatefulWidget {
  const ProductScreen({
    super.key,
    required this.canManage,
    required this.gateway,
    this.openAddForm = false,
  });

  final bool canManage;
  final ProductGateway gateway;
  final bool openAddForm;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<ProductItem> _products = [];
  bool _isLoading = true;
  String? _error;
  int _loadGeneration = 0;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _loadProducts();
    if (widget.openAddForm && widget.canManage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _editProduct();
        }
      });
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    final generation = ++_loadGeneration;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final products = await widget.gateway.searchProducts(
        _searchController.text,
      );
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _products = products;
          _isLoading = false;
        });
      }
    } on ProductFailure catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _error = error.message;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _error = 'Could not load products. Please try again.';
          _isLoading = false;
        });
      }
    }
  }

  void _searchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), _loadProducts);
  }

  Future<void> _exportProducts() async {
    try {
      final products = await widget.gateway.searchProducts('');
      if (!mounted) return;
      const xlsxType = XTypeGroup(
        label: 'Excel workbook',
        extensions: ['xlsx'],
      );
      final target = await getSaveLocation(
        suggestedName: 'Thanigai-Stores-Products.xlsx',
        acceptedTypeGroups: const [xlsxType],
      );
      if (target == null) return;
      final savePath = target.path.toLowerCase().endsWith('.xlsx')
          ? target.path
          : '${target.path}.xlsx';
      await File(savePath)
          .writeAsBytes(encodeProductsXlsx(products), flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Product details saved to $savePath')),
        );
      }
    } on ProductFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save the Excel file: ${error.message}'),
          ),
        );
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not export products: ${error.message}'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not export product details.')),
        );
      }
    }
  }

  Future<void> _importProducts() async {
    try {
      const xlsxType = XTypeGroup(
        label: 'Excel workbook',
        extensions: ['xlsx'],
      );
      final file = await openFile(acceptedTypeGroups: const [xlsxType]);
      if (file == null || !mounted) return;
      final importData = SampleProductImporter.parseWithValidation(
        await file.readAsBytes(),
      );
      if (importData.products.isEmpty) {
        throw FormatException(
          importData.rowErrors.isEmpty
              ? 'The Excel file contains no valid product rows.'
              : importData.rowErrors.join('\n'),
        );
      }
      final existing = await widget.gateway.searchProducts('');
      final plan = SampleProductImporter.plan(importData.products, existing);
      if (!mounted) return;
      if (plan.products.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              plan.duplicateCount == 0
                  ? 'The Excel file contains no products to import.'
                  : 'No new products to import. Skipped ${plan.duplicateCount} duplicates and ${importData.rowErrors.length} invalid rows.',
            ),
          ),
        );
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _ProductImportPreviewDialog(
          plan: plan,
          rowErrors: importData.rowErrors,
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _isImporting = true);
      var importedCount = 0;
      try {
        for (final product in plan.products) {
          await widget.gateway.createProduct(product);
          importedCount += 1;
        }
      } catch (error) {
        if (mounted) {
          final message = error is ProductFailure
              ? error.message
              : 'An unexpected error occurred.';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                importedCount == 0
                    ? 'Import failed: $message'
                    : 'Imported $importedCount products before the import stopped: $message',
              ),
            ),
          );
          await _loadProducts();
        }
        return;
      } finally {
        if (mounted) setState(() => _isImporting = false);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Imported $importedCount products. Skipped ${plan.duplicateCount} duplicates and ${importData.rowErrors.length} invalid rows.',
            ),
          ),
        );
        await _loadProducts();
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Excel validation failed: ${error.message}')),
        );
      }
    } on ProductFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not read the Excel file: ${error.message}'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not import products: $error')),
        );
      }
    }
  }

  Future<void> _editProduct([ProductItem? product]) async {
    final draft = await showDialog<ProductDraft>(
      context: context,
      builder: (_) => _ProductEditorDialog(product: product),
    );
    if (draft == null || !mounted) return;

    try {
      if (product == null) {
        await widget.gateway.createProduct(draft);
      } else {
        await widget.gateway.updateProduct(product.id, draft);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              product == null ? 'Product added.' : 'Product updated.',
            ),
          ),
        );
        await _loadProducts();
      }
    } on ProductFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the product.')),
        );
      }
    }
  }

  Future<void> _editSellingPrice(ProductItem product) async {
    final sellingPrice = await showDialog<String>(
      context: context,
      builder: (_) => _SellingPriceDialog(
        initialPrice: product.sellingPrice,
        quantityLabel:
            '${formatSellingQuantity(product.sellingQuantity)} ${product.unit}',
      ),
    );
    if (sellingPrice == null || !mounted) return;

    try {
      await widget.gateway.updateProduct(
        product.id,
        ProductDraft(
          name: product.name,
          sku: product.sku,
          category: product.category,
          unit: product.unit,
          purchasePrice: product.purchasePrice ?? '0',
          sellingPrice: sellingPrice,
          mrp: product.mrp,
          sellingQuantity: product.sellingQuantity,
          gstRate: product.gstRate,
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Selling price updated.')));
        await _loadProducts();
      }
    } on ProductFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update the selling price.')),
        );
      }
    }
  }

  Future<void> _selectProductToDelete() async {
    late final List<ProductItem> products;
    try {
      products = await widget.gateway.searchProducts('');
    } on ProductFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
      return;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load products: $error')),
        );
      }
      return;
    }
    if (!mounted) return;
    if (products.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('There are no active products to delete.'),
        ),
      );
      return;
    }
    final product = await showDialog<ProductItem>(
      context: context,
      builder: (_) => _ProductSelectionDialog(products: products),
    );
    if (product == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm product deletion'),
        content: Text(
          'Product: ${product.name}\n'
          'Category: ${product.category}\n'
          'Code: ${product.sku.isEmpty ? '-' : product.sku}\n'
          'Unit: ${product.unit}\n'
          'Purchase price: ₹${product.purchasePrice ?? '-'}\n'
          'Selling price: ₹${product.sellingPrice}\n'
          'MRP: ${product.mrp == null ? '-' : '₹${product.mrp}'}\n\n'
          'This removes the product from active lists. Invoice and financial history will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirmDeleteProductButton'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.gateway.deleteProduct(product.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Product removed from the active list.'),
          ),
        );
        await _loadProducts();
      }
    } on ProductFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not remove the product.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Products'),
        actions: [
          if (widget.canManage)
            IconButton(
              key: const Key('exportProductsXlsxButton'),
              tooltip: 'Save product details to Excel',
              onPressed: _isLoading ? null : _exportProducts,
              icon: const Icon(Icons.table_view_outlined),
            ),
          IconButton(
            key: const Key('refreshProductsButton'),
            tooltip: 'Refresh products',
            onPressed: _loadProducts,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1050),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('productSearchField'),
                        controller: _searchController,
                        onChanged: _searchChanged,
                        decoration: InputDecoration(
                          hintText: 'Search product name or category',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchController.clear();
                              _loadProducts();
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                if (widget.canManage) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const Key('addProductButton'),
                        onPressed: _isImporting ? null : () => _editProduct(),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add product'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('deleteProductButton'),
                        onPressed: _isImporting ? null : _selectProductToDelete,
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('Delete product'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('importProductsXlsxButton'),
                        onPressed: _isImporting ? null : _importProducts,
                        icon: const Icon(Icons.upload_file_rounded),
                        label: const Text('Import from Excel'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (_isLoading)
                  const Expanded(
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _loadProducts,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (_products.isEmpty)
                  const Expanded(
                    child: Center(child: Text('No products found.')),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      itemCount: _products.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) =>
                          _productCard(_products[index]),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _productCard(ProductItem product) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF2EC),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.local_mall_outlined,
                color: Color(0xFF245C45),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      product.category,
                      if (product.sku.isNotEmpty) product.sku,
                      '${formatSellingQuantity(product.sellingQuantity)} ${product.unit}',
                    ].join(' · '),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Sell ₹${product.sellingPrice} / ${formatSellingQuantity(product.sellingQuantity)} ${product.unit}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (widget.canManage)
                    Text('Buy ₹${product.purchasePrice ?? '-'}'),
                  const SizedBox(height: 4),
                ],
              ),
            ),
            if (widget.canManage) ...[
              IconButton(
                key: Key('editSellingPrice-${product.id}'),
                tooltip: 'Edit selling price for ${product.name}',
                onPressed: () => _editSellingPrice(product),
                icon: const Icon(Icons.sell_outlined),
              ),
              IconButton(
                key: Key('editProduct-${product.id}'),
                tooltip: 'Edit ${product.name}',
                onPressed: () => _editProduct(product),
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProductSelectionDialog extends StatefulWidget {
  const _ProductSelectionDialog({required this.products});

  final List<ProductItem> products;

  @override
  State<_ProductSelectionDialog> createState() =>
      _ProductSelectionDialogState();
}

class _ProductSelectionDialogState extends State<_ProductSelectionDialog> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final products = widget.products
        .where((product) {
          return product.name.toLowerCase().contains(query) ||
              product.category.toLowerCase().contains(query) ||
              product.sku.toLowerCase().contains(query);
        })
        .toList(growable: false);
    return AlertDialog(
      title: const Text('Select a product to delete'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const Key('deleteProductSearchField'),
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Search name, category or code',
                prefixIcon: Icon(Icons.search_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: products.isEmpty
                  ? const Center(child: Text('No matching products.'))
                  : ListView.builder(
                      itemCount: products.length,
                      itemBuilder: (context, index) {
                        final product = products[index];
                        return ListTile(
                          key: Key('selectProductToDelete-${product.id}'),
                          title: Text(product.name),
                          subtitle: Text(
                            '${product.category} · ${product.sku.isEmpty ? 'No code' : product.sku}',
                          ),
                          onTap: () => Navigator.pop(context, product),
                        );
                      },
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
      ],
    );
  }
}

class _ProductImportPreviewDialog extends StatelessWidget {
  const _ProductImportPreviewDialog({
    required this.plan,
    required this.rowErrors,
  });

  final ProductImportPlan plan;
  final List<String> rowErrors;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Review Excel import'),
    content: SizedBox(
      width: 560,
      height: 400,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${plan.products.length} new products will be added.'
            '${plan.duplicateCount > 0 ? ' ${plan.duplicateCount} duplicate rows will be skipped.' : ''}'
            '${rowErrors.isNotEmpty ? ' ${rowErrors.length} invalid rows will be skipped.' : ''}',
          ),
          if (rowErrors.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 76),
              child: SingleChildScrollView(
                child: Text(
                  rowErrors.join('\n'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: plan.products.length,
              itemBuilder: (context, index) {
                final product = plan.products[index];
                return ListTile(
                  title: Text(product.name),
                  subtitle: Text(
                    '${product.category} · ${product.unit} · '
                    'Buy ₹${product.purchasePrice} · Sell ₹${product.sellingPrice}'
                    '${product.mrp == null ? '' : ' · MRP ₹${product.mrp}'}'
                    ' · Stock ${product.openingStockQuantity}',
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('confirmProductImportButton'),
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Import products'),
      ),
    ],
  );
}

class _SellingPriceDialog extends StatefulWidget {
  const _SellingPriceDialog({
    required this.initialPrice,
    required this.quantityLabel,
  });

  final String initialPrice;
  final String quantityLabel;

  @override
  State<_SellingPriceDialog> createState() => _SellingPriceDialogState();
}

class _SellingPriceDialogState extends State<_SellingPriceDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialPrice);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    final price = double.tryParse(value);
    if (price == null ||
        !price.isFinite ||
        price <= 0 ||
        !RegExp(r'^\d+(?:\.\d{0,2})?$').hasMatch(value)) {
      setState(() => _error = 'Enter a valid price with up to 2 decimals.');
      return;
    }
    Navigator.pop(context, price.toStringAsFixed(2));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit price for ${widget.quantityLabel}'),
      content: TextField(
        key: const Key('sellingPriceQuickEditField'),
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Selling price (₹)',
          prefixText: '₹ ',
          errorText: _error,
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('saveSellingPriceButton'),
          onPressed: _save,
          child: const Text('Save price'),
        ),
      ],
    );
  }
}

class _ProductEditorDialog extends StatefulWidget {
  const _ProductEditorDialog({this.product});

  final ProductItem? product;

  @override
  State<_ProductEditorDialog> createState() => _ProductEditorDialogState();
}

class _ProductEditorDialogState extends State<_ProductEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers;
  late String _unit;

  @override
  void initState() {
    super.initState();
    final product = widget.product;
    _controllers = {
      'name': TextEditingController(text: product?.name ?? ''),
      'purchasePrice': TextEditingController(
        text: product?.purchasePrice ?? '0.00',
      ),
      'sellingPrice': TextEditingController(text: product?.sellingPrice ?? ''),
      'mrp': TextEditingController(text: product?.mrp ?? ''),
      'sellingQuantity': TextEditingController(
        text: product?.sellingQuantity ?? '1',
      ),
      'openingStockQuantity': TextEditingController(
        text: product?.openingStockQuantity ?? '0',
      ),
    };
    _unit = product?.unit ?? 'g';
    if (product == null) {
      _controllers['sellingQuantity']!.text = _defaultQuantity(_unit);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _required(String? value, String label, int maxLength) {
    if (value == null || value.trim().isEmpty) return '$label is required.';
    if (value.trim().length > maxLength) {
      return '$label must be $maxLength characters or fewer.';
    }
    return null;
  }

  String? _decimal(
    String? value, {
    required String label,
    required int scale,
    required double minimum,
    required double maximum,
  }) {
    if (value == null ||
        !RegExp(r'^\d+(?:\.\d{0,' + scale.toString() + r'})?$')
            .hasMatch(value.trim())) {
      return '$label must be a valid non-negative number.';
    }
    final numericValue = double.tryParse(value);
    final parts = value.trim().split('.');
    final fraction = parts.length > 1 ? parts[1] : '';
    if (numericValue == null ||
        numericValue < minimum ||
        numericValue > maximum ||
        fraction.length > scale) {
      return '$label must be between $minimum and $maximum with at most $scale decimal places.';
    }
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      ProductDraft(
        name: _controllers['name']!.text,
        unit: _unit,
        purchasePrice: _controllers['purchasePrice']!.text,
        sellingPrice: _controllers['sellingPrice']!.text,
        mrp: _controllers['mrp']!.text,
        sellingQuantity: _controllers['sellingQuantity']!.text,
        openingStockQuantity: _controllers['openingStockQuantity']!.text,
        gstRate: widget.product?.gstRate ?? '0',
        category: widget.product?.category ?? 'General',
        sku: widget.product?.sku ?? '',
      ),
    );
  }

  String _defaultQuantity(String unit) =>
      unit == 'g' || unit == 'ml' ? '100' : '1';

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.product != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit product' : 'Add product'),
      content: SizedBox(
        width: 600,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _textField(
                  'name',
                  'Product name',
                  key: 'productNameField',
                  validator: (value) => _required(value, 'Product name', 160),
                ),
                DropdownButtonFormField<String>(
                  key: const Key('productUnitField'),
                  initialValue: _unit,
                  decoration: const InputDecoration(
                    labelText: 'Selling unit',
                    border: OutlineInputBorder(),
                  ),
                  items: productUnits
                      .map(
                        (unit) =>
                            DropdownMenuItem(value: unit, child: Text(unit)),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _unit = value;
                        _controllers['sellingQuantity']!.text =
                            _defaultQuantity(value);
                      });
                    }
                  },
                ),
                const SizedBox(height: 14),
                _numberField(
                  'sellingQuantity',
                  'Quantity',
                  'productQuantityField',
                  scale: 3,
                  minimum: 0.001,
                  maximum: 999999999.999,
                  suffix: _unit,
                ),
                _numberField(
                  'purchasePrice',
                  'Purchase price (₹)',
                  'productPurchasePriceField',
                  scale: 2,
                  minimum: 0,
                  maximum: 9999999999.99,
                ),
                _numberField(
                  'mrp',
                  'MRP (₹)',
                  'productMrpField',
                  scale: 2,
                  minimum: 0,
                  maximum: 9999999999.99,
                  optional: true,
                ),
                if (!isEditing)
                  _numberField(
                    'openingStockQuantity',
                    'Opening / old stock quantity',
                    'productOpeningStockQuantityField',
                    scale: 3,
                    minimum: 0,
                    maximum: 999999999.999,
                    suffix: _unit,
                  ),
                Row(
                  children: [
                    Expanded(
                      child: _numberField(
                        'sellingPrice',
                        'Selling price (₹)',
                        'productSellingPriceField',
                        scale: 2,
                        minimum: 0.01,
                        maximum: 9999999999.99,
                        helperText:
                            'Price for ${_controllers['sellingQuantity']!.text} $_unit',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('saveProductButton'),
          onPressed: _submit,
          child: Text(isEditing ? 'Save changes' : 'Add product'),
        ),
      ],
    );
  }

  Widget _textField(
    String field,
    String label, {
    required String key,
    required String? Function(String?) validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        key: Key(key),
        controller: _controllers[field],
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        validator: validator,
      ),
    );
  }

  Widget _numberField(
    String field,
    String label,
    String key, {
    required int scale,
    required double minimum,
    required double maximum,
    String? suffix,
    String? helperText,
    bool optional = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        key: Key(key),
        controller: _controllers[field],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixText: suffix,
          helperText: helperText,
        ),
        validator: (value) {
          if (optional && (value == null || value.trim().isEmpty)) return null;
          return _decimal(
            value,
            label: label,
            scale: scale,
            minimum: minimum,
            maximum: maximum,
          );
        },
      ),
    );
  }
}
