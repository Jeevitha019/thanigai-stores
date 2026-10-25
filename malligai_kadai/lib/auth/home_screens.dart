import 'dart:convert';

import 'package:flutter/material.dart';

import 'auth_gateway.dart';
import '../billing/billing_gateway.dart';
import '../billing/invoice_history_screen.dart';
import '../billing/receipt_printer.dart';
import '../billing/gst_settings_screen.dart';
import '../billing/billing_screen.dart';
import '../products/product_gateway.dart';
import '../products/product_screen.dart';
import '../reports/reports_gateway.dart';
import '../reports/reports_screens.dart';
import '../stocks/stock_management_screen.dart';

class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({
    super.key,
    required this.user,
    required this.onLogout,
    required this.onCreateCashier,
    required this.productGateway,
    required this.billingGateway,
    this.onChangePassword,
    this.receiptPrinterGateway,
    this.reportsGateway,
  });

  final AuthUser user;
  final Future<void> Function() onLogout;
  final Future<AuthUser> Function(String username, String password)
  onCreateCashier;
  final ProductGateway productGateway;
  final BillingGateway billingGateway;
  final Future<void> Function(String currentPassword, String newPassword)?
  onChangePassword;
  final ReceiptPrinterGateway? receiptPrinterGateway;
  final ReportsGateway? reportsGateway;

  @override
  Widget build(BuildContext context) => _RoleHomeScreen(
    user: user,
    onLogout: onLogout,
    onCreateCashier: onCreateCashier,
    productGateway: productGateway,
    billingGateway: billingGateway,
    onChangePassword: onChangePassword,
    receiptPrinterGateway: receiptPrinterGateway,
    reportsGateway: reportsGateway,
  );
}

class CashierHomeScreen extends StatelessWidget {
  const CashierHomeScreen({
    super.key,
    required this.user,
    required this.onLogout,
    required this.productGateway,
    required this.billingGateway,
    this.onChangePassword,
    this.receiptPrinterGateway,
    this.reportsGateway,
  });

  final AuthUser user;
  final Future<void> Function() onLogout;
  final ProductGateway productGateway;
  final BillingGateway billingGateway;
  final Future<void> Function(String currentPassword, String newPassword)?
  onChangePassword;
  final ReceiptPrinterGateway? receiptPrinterGateway;
  final ReportsGateway? reportsGateway;

  @override
  Widget build(BuildContext context) => _RoleHomeScreen(
    user: user,
    onLogout: onLogout,
    productGateway: productGateway,
    billingGateway: billingGateway,
    onChangePassword: onChangePassword,
    receiptPrinterGateway: receiptPrinterGateway,
    reportsGateway: reportsGateway,
  );
}

class _RoleHomeScreen extends StatefulWidget {
  const _RoleHomeScreen({
    required this.user,
    required this.onLogout,
    required this.productGateway,
    required this.billingGateway,
    this.onCreateCashier,
    this.onChangePassword,
    this.receiptPrinterGateway,
    this.reportsGateway,
  });

  final AuthUser user;
  final Future<void> Function() onLogout;
  final ProductGateway productGateway;
  final BillingGateway billingGateway;
  final Future<AuthUser> Function(String username, String password)?
  onCreateCashier;
  final Future<void> Function(String currentPassword, String newPassword)?
  onChangePassword;
  final ReceiptPrinterGateway? receiptPrinterGateway;
  final ReportsGateway? reportsGateway;

  @override
  State<_RoleHomeScreen> createState() => _RoleHomeScreenState();
}

class _RoleHomeScreenState extends State<_RoleHomeScreen> {
  late final ReceiptPrinterGateway _receiptPrinterGateway =
      widget.receiptPrinterGateway ?? WindowsReceiptPrinterGateway();
  late final ReportsGateway _reportsGateway =
      widget.reportsGateway ?? HttpReportsGateway();
  late Future<_AdminDashboardStats>? _dashboardFuture = _isAdmin
      ? _loadAdminDashboard()
      : null;
  bool _isLoggingOut = false;
  bool _isCreatingCashier = false;
  String? _errorMessage;

  bool get _isAdmin => widget.user.role == UserRole.admin;

  Future<_AdminDashboardStats> _loadAdminDashboard() async {
    final now = DateTime.now();
    return _AdminDashboardStats(
      dashboard: await _reportsGateway.dashboard(now),
    );
  }

  void _refreshDashboard() {
    setState(() => _dashboardFuture = _loadAdminDashboard());
  }

  Future<void> _showCreateCashierDialog() async {
    final createCashier = widget.onCreateCashier;
    if (createCashier == null) {
      return;
    }

    final credentials = await showDialog<_CashierCredentials>(
      context: context,
      builder: (context) => const _CreateCashierDialog(),
    );
    if (credentials == null || !mounted) {
      return;
    }

    setState(() {
      _isCreatingCashier = true;
      _errorMessage = null;
    });
    try {
      final cashier = await createCashier(
        credentials.username,
        credentials.password,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cashier login created for ${cashier.username}.'),
          ),
        );
      }
    } on AuthFailure catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not create the Cashier login.');
      }
    } finally {
      if (mounted) {
        setState(() => _isCreatingCashier = false);
      }
    }
  }

  Future<void> _logout() async {
    setState(() {
      _isLoggingOut = true;
      _errorMessage = null;
    });
    try {
      await widget.onLogout();
    } on AuthFailure catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.message);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoggingOut = false);
      }
    }
  }

  Future<void> _showChangePasswordDialog() async {
    final changePassword = widget.onChangePassword;
    if (changePassword == null) return;
    final passwordChange = await showDialog<_PasswordChange>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (passwordChange == null || !mounted) return;
    setState(() => _errorMessage = null);
    try {
      await changePassword(
        passwordChange.currentPassword,
        passwordChange.newPassword,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password changed successfully.')),
        );
      }
    } on AuthFailure catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not change the password.');
      }
    }
  }

  Future<void> _openProducts() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProductScreen(
          canManage: widget.onCreateCashier != null,
          gateway: widget.productGateway,
        ),
      ),
    );
  }

  Future<void> _openStocks() {
    final gateway = widget.productGateway;
    if (gateway is! StockGateway) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Stock management is unavailable.')),
      );
      return Future<void>.value();
    }
    final stockGateway = gateway as StockGateway;
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            StockManagementScreen(gateway: stockGateway, canManage: _isAdmin),
      ),
    );
  }

  Future<void> _openAddProduct() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProductScreen(
          canManage: _isAdmin,
          gateway: widget.productGateway,
          openAddForm: true,
        ),
      ),
    );
  }

  Future<void> _openBilling() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BillingScreen(
          productGateway: widget.productGateway,
          billingGateway: widget.billingGateway,
          receiptPrinterGateway: _receiptPrinterGateway,
        ),
      ),
    );
  }

  Future<void> _openInvoiceHistory() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InvoiceHistoryScreen(
          billingGateway: widget.billingGateway,
          printerGateway: _receiptPrinterGateway,
          canManage: _isAdmin,
        ),
      ),
    );
  }

  Future<void> _openGstSettings() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GstSettingsScreen(gateway: widget.billingGateway),
      ),
    );
  }

  List<_PosNavigationItem> get _navigationItems => [
    _PosNavigationItem(
      label: 'Dashboard',
      icon: Icons.dashboard_outlined,
      key: const Key('openDashboardButton'),
      onPressed: _isAdmin ? _refreshDashboard : null,
    ),
    _PosNavigationItem(
      label: 'Products',
      icon: Icons.local_mall_outlined,
      key: const Key('openProductsButton'),
      onPressed: _openProducts,
    ),
    _PosNavigationItem(
      label: 'New Bill',
      icon: Icons.point_of_sale_rounded,
      key: const Key('openBillingButton'),
      onPressed: _openBilling,
      primary: true,
    ),
    _PosNavigationItem(
      label: 'Saved Invoices',
      icon: Icons.receipt_long_outlined,
      key: const Key('openInvoiceHistoryButton'),
      onPressed: _openInvoiceHistory,
    ),
    if (_isAdmin) ...[
      _PosNavigationItem(
        label: 'Stocks',
        icon: Icons.inventory_2_outlined,
        key: const Key('openStocksButton'),
        onPressed: _openStocks,
      ),
      _PosNavigationItem(
        label: 'Reports',
        icon: Icons.query_stats_rounded,
        key: const Key('openReportsButton'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SalesReportsScreen(gateway: _reportsGateway),
          ),
        ),
      ),
      _PosNavigationItem(
        label: 'Settings',
        icon: Icons.percent_rounded,
        key: const Key('openSettingsButton'),
        onPressed: _openGstSettings,
      ),
      if (widget.onCreateCashier != null)
        _PosNavigationItem(
          label: 'Cashier Management',
          icon: Icons.manage_accounts_outlined,
          key: const Key('createCashierButton'),
          onPressed: _showCreateCashierDialog,
        ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobile = constraints.maxWidth < 720;
        final compact = constraints.maxWidth < 1050;
        return Scaffold(
          drawer: mobile
              ? Drawer(
                  width: 280,
                  child: _PosSidebar(
                    items: _navigationItems,
                    compact: false,
                    isAdmin: _isAdmin,
                    isDrawer: true,
                  ),
                )
              : null,
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(72),
            child: _PosTopBar(
              user: widget.user,
              isLoggingOut: _isLoggingOut,
              isMobile: mobile,
              onLogout: _logout,
              onChangePassword: widget.onChangePassword == null
                  ? null
                  : _showChangePasswordDialog,
            ),
          ),
          body: Row(
            children: [
              if (!mobile)
                _PosSidebar(
                  items: _navigationItems,
                  compact: compact,
                  isAdmin: _isAdmin,
                  isDrawer: false,
                ),
              Expanded(
                child: ColoredBox(
                  color: const Color(0xFFF3F6F3),
                  child: _DashboardContent(
                    user: widget.user,
                    isAdmin: _isAdmin,
                    dashboardFuture: _dashboardFuture,
                    isCreatingCashier: _isCreatingCashier,
                    errorMessage: _errorMessage,
                    onRefresh: _refreshDashboard,
                    onOpenBilling: _openBilling,
                    onOpenAddProduct: _openAddProduct,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AdminDashboardStats {
  const _AdminDashboardStats({required this.dashboard});

  final DashboardData dashboard;
}

class _PosNavigationItem {
  const _PosNavigationItem({
    required this.label,
    required this.icon,
    required this.key,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final Key key;
  final VoidCallback? onPressed;
  final bool primary;
}

class _PosSidebar extends StatelessWidget {
  const _PosSidebar({
    required this.items,
    required this.compact,
    required this.isAdmin,
    required this.isDrawer,
  });

  final List<_PosNavigationItem> items;
  final bool compact;
  final bool isAdmin;
  final bool isDrawer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? 80 : 252,
      color: const Color(0xFF173E32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 22, 12, 24),
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Image.asset(
                  'assets/thanigai_stores_logo.png',
                  width: 42,
                  height: 42,
                  fit: BoxFit.contain,
                ),
                if (!compact) ...[
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Thanigai Stores',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'GROCERY POS',
                          style: TextStyle(
                            color: Color(0xFFB4C8BB),
                            fontSize: 10,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 8 : 20, 0, 12, 9),
            child: compact
                ? const Divider(color: Color(0xFF456356), height: 1)
                : Text(
                    'WORKSPACE',
                    style: TextStyle(
                      color: const Color(0xFFB4C8BB)
                          .withAlpha((0.78 * 255).round()),
                      fontSize: 10,
                      letterSpacing: 1.3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 9 : 12,
                vertical: 4,
              ),
              itemCount: items.length,
              separatorBuilder: (context, index) =>
                  SizedBox(height: compact ? 5 : 4),
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = index == 0;
                return Tooltip(
                  message: compact ? item.label : '',
                  child: Material(
                    color: selected
                        ? const Color(0xFF2B644B)
                        : item.primary
                        ? const Color(0xFF255741)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      key: item.key,
                      onTap: item.onPressed == null
                          ? null
                          : () {
                              if (isDrawer) {
                                Navigator.of(context).pop();
                              }
                              item.onPressed!();
                            },
                      borderRadius: BorderRadius.circular(10),
                      hoverColor: Colors.white.withAlpha((0.09 * 255).round()),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 0 : 12,
                          vertical: compact ? 9 : 12,
                        ),
                        child: Row(
                          mainAxisAlignment: compact
                              ? MainAxisAlignment.center
                              : MainAxisAlignment.start,
                          children: [
                            Icon(
                              item.icon,
                              size: 20,
                              color: selected || item.primary
                                  ? Colors.white
                                  : const Color(0xFFD4E0D8),
                            ),
                            if (!compact) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: selected || item.primary
                                        ? Colors.white
                                        : const Color(0xFFD4E0D8),
                                    fontSize: 13,
                                    fontWeight: selected || item.primary
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (item.primary)
                                const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 16,
                                  color: Colors.white70,
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 12, 12, 18),
            child: compact
                ? Icon(
                    isAdmin
                        ? Icons.admin_panel_settings_outlined
                        : Icons.point_of_sale_outlined,
                    color: const Color(0xFFB4C8BB),
                    size: 20,
                  )
                : Row(
                    children: [
                      Icon(
                        isAdmin
                            ? Icons.admin_panel_settings_outlined
                            : Icons.point_of_sale_outlined,
                        color: const Color(0xFFB4C8BB),
                        size: 17,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isAdmin ? 'Admin workspace' : 'Cashier workspace',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(
                            color: Color(0xFFB4C8BB),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _PosTopBar extends StatelessWidget {
  const _PosTopBar({
    required this.user,
    required this.isLoggingOut,
    required this.isMobile,
    required this.onLogout,
    this.onChangePassword,
  });

  final AuthUser user;
  final bool isLoggingOut;
  final bool isMobile;
  final Future<void> Function() onLogout;
  final Future<void> Function()? onChangePassword;

  @override
  Widget build(BuildContext context) {
    final isAdmin = user.role == UserRole.admin;
    return Material(
      color: Colors.white,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFE4EAE5))),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: isMobile
            ? Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Builder(
                          builder: (context) => IconButton(
                            tooltip: 'Open navigation',
                            onPressed: () => Scaffold.of(context).openDrawer(),
                            icon: const Icon(Icons.menu_rounded),
                          ),
                        ),
                        const Spacer(),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 92),
                          child: Text(
                            user.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF263A30),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          isAdmin ? 'Admin' : 'Cashier',
                          style: const TextStyle(
                            color: Color(0xFF245C45),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (onChangePassword != null)
                          IconButton(
                            key: const Key('changePasswordButton'),
                            tooltip: 'Change password',
                            onPressed: onChangePassword,
                            icon: const Icon(Icons.key_outlined),
                          ),
                        IconButton(
                          key: const Key('logoutButton'),
                          tooltip: 'Log out',
                          onPressed: isLoggingOut ? null : onLogout,
                          icon: isLoggingOut
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.logout_rounded),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Thanigai Stores',
                    key: Key('mainStoreTitle'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF20372C),
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              )
            : SizedBox(
                height: 64,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Text(
                      'Thanigai Stores',
                      key: Key('mainStoreTitle'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF20372C),
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Row(
                      children: [
                        const Spacer(),
                        const Icon(
                          Icons.account_circle_outlined,
                          color: Color(0xFF64766A),
                          size: 21,
                        ),
                        const SizedBox(width: 9),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 170),
                          child: Text(
                            user.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF263A30),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 9),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8F1EA),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            isAdmin ? 'Admin' : 'Cashier',
                            style: const TextStyle(
                              color: Color(0xFF245C45),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const SizedBox(
                          height: 28,
                          child: VerticalDivider(
                            width: 1,
                            color: Color(0xFFE1E7E2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (onChangePassword != null)
                          IconButton(
                            key: const Key('changePasswordButton'),
                            tooltip: 'Change password',
                            onPressed: onChangePassword,
                            icon: const Icon(Icons.key_outlined),
                          ),
                        IconButton(
                          key: const Key('logoutButton'),
                          tooltip: 'Log out',
                          onPressed: isLoggingOut ? null : onLogout,
                          icon: isLoggingOut
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.logout_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.user,
    required this.isAdmin,
    required this.dashboardFuture,
    required this.isCreatingCashier,
    required this.errorMessage,
    required this.onRefresh,
    required this.onOpenBilling,
    required this.onOpenAddProduct,
  });

  final AuthUser user;
  final bool isAdmin;
  final Future<_AdminDashboardStats>? dashboardFuture;
  final bool isCreatingCashier;
  final String? errorMessage;
  final VoidCallback onRefresh;
  final VoidCallback onOpenBilling;
  final VoidCallback onOpenAddProduct;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth < 1200
            ? constraints.maxWidth
            : 1200.0;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: constraints.maxWidth < 640 ? 18 : 32,
            vertical: 28,
          ),
          child: Center(
            child: SizedBox(
              width: contentWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isAdmin ? 'Admin Home' : 'Cashier Home',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    color: const Color(0xFF20372C),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 24,
                                  ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              'Welcome, ${user.username}',
                              style: const TextStyle(
                                color: Color(0xFF6B7B70),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isAdmin)
                        IconButton(
                          key: const Key('refreshDashboardButton'),
                          tooltip: 'Refresh dashboard',
                          onPressed: onRefresh,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                    ],
                  ),
                  const SizedBox(height: 25),
                  if (isAdmin) ...[
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Today at a glance',
                            style: TextStyle(
                              color: Color(0xFF263A30),
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Text(
                          _todayLabel(),
                          style: const TextStyle(
                            color: Color(0xFF7B897F),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 13),
                    _AdminDashboardCards(
                      future: dashboardFuture,
                      onRetry: onRefresh,
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Quick actions',
                      style: TextStyle(
                        color: Color(0xFF263A30),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 13),
                    Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: [
                        _QuickActionCard(
                          title: 'New Bill',
                          subtitle: 'Start a customer checkout',
                          icon: Icons.point_of_sale_rounded,
                          primary: true,
                          buttonKey: const Key('quickNewBillButton'),
                          onPressed: onOpenBilling,
                        ),
                        _QuickActionCard(
                          title: 'Add Product',
                          subtitle: 'Create an item in your catalog',
                          icon: Icons.add_box_outlined,
                          buttonKey: const Key('quickAddProductButton'),
                          onPressed: onOpenAddProduct,
                        ),
                      ],
                    ),
                    const SizedBox(height: 25),
                    _TodayPaymentSummary(future: dashboardFuture),
                  ] else ...[
                    _CashierWelcomeCard(
                      username: user.username,
                      onNewBill: onOpenBilling,
                    ),
                    const SizedBox(height: 20),
                    const Row(
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          color: Color(0xFF47735B),
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Your workspace is ready. Start a new bill or use the sidebar to find products and saved invoices.',
                            style: TextStyle(
                              color: Color(0xFF68796D),
                              height: 1.45,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (isCreatingCashier || errorMessage != null) ...[
                    const SizedBox(height: 18),
                    if (isCreatingCashier)
                      const LinearProgressIndicator(
                        key: Key('cashierCreationProgress'),
                      ),
                    if (errorMessage != null)
                      _InlineErrorMessage(message: errorMessage!),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static String _todayLabel() {
    final now = DateTime.now();
    return '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/${now.year}';
  }
}

class _AdminDashboardCards extends StatelessWidget {
  const _AdminDashboardCards({required this.future, required this.onRetry});

  final Future<_AdminDashboardStats>? future;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => FutureBuilder<_AdminDashboardStats>(
        future: future,
        builder: (context, snapshot) {
          final cards = snapshot.hasData
              ? _statCards(snapshot.data!)
              : const <_DashboardStat>[
                  _DashboardStat(
                    title: "Today's Sales",
                    value: '',
                    detail: 'Sales recorded today',
                    icon: Icons.currency_rupee_rounded,
                    color: Color(0xFF2D7652),
                  ),
                  _DashboardStat(
                    title: 'Total Bills',
                    value: '',
                    detail: 'Invoices today',
                    icon: Icons.receipt_long_outlined,
                    color: Color(0xFF4274A4),
                  ),
                  _DashboardStat(
                    title: 'Stocks',
                    value: '',
                    detail: 'Products with available stock',
                    icon: Icons.inventory_2_outlined,
                    color: Color(0xFF9A6A32),
                  ),
                ];
          final columns = constraints.maxWidth > 1050
              ? 3
              : constraints.maxWidth > 530
              ? 2
              : 1;
          final gap = 13.0;
          final cardWidth =
              (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final card in cards)
                SizedBox(
                  width: cardWidth,
                  child: _DashboardStatCard(
                    stat: card,
                    isLoading:
                        snapshot.connectionState == ConnectionState.waiting,
                    hasError: snapshot.hasError,
                    onRetry: onRetry,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static List<_DashboardStat> _statCards(_AdminDashboardStats stats) {
    return [
      _DashboardStat(
        title: "Today's Sales",
        value: '₹ ${stats.dashboard.totalSales}',
        detail: 'Sales recorded today',
        icon: Icons.currency_rupee_rounded,
        color: const Color(0xFF2D7652),
      ),
      _DashboardStat(
        title: 'Total Bills',
        value: '${stats.dashboard.invoiceCount}',
        detail: 'Invoices today',
        icon: Icons.receipt_long_outlined,
        color: const Color(0xFF4274A4),
      ),
      _DashboardStat(
        title: 'Stocks',
        value: '${stats.dashboard.stockProductCount}',
        detail: 'Products with available stock',
        icon: Icons.inventory_2_outlined,
        color: const Color(0xFF9A6A32),
      ),
    ];
  }
}

class _DashboardStat {
  const _DashboardStat({
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;
}

class _DashboardStatCard extends StatelessWidget {
  const _DashboardStatCard({
    required this.stat,
    required this.isLoading,
    required this.hasError,
    required this.onRetry,
  });

  final _DashboardStat stat;
  final bool isLoading;
  final bool hasError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 132),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE3EAE4)),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  stat.title,
                  style: const TextStyle(
                    color: Color(0xFF64756A),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: stat.color.withAlpha((0.1 * 255).round()),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(stat.icon, color: stat.color, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 13),
          if (isLoading)
            const SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (hasError)
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Unavailable',
                    style: TextStyle(
                      color: Color(0xFF8A574F),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Retry loading dashboard',
                  visualDensity: VisualDensity.compact,
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
              ],
            )
          else
            Text(
              stat.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF20372C),
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          const SizedBox(height: 4),
          Text(
            hasError ? 'Check API connection' : stat.detail,
            style: const TextStyle(color: Color(0xFF89958C), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _TodayPaymentSummary extends StatelessWidget {
  const _TodayPaymentSummary({required this.future});

  final Future<_AdminDashboardStats>? future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AdminDashboardStats>(
      future: future,
      builder: (context, snapshot) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(19),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFE3EAE4)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    color: Color(0xFF47735B),
                    size: 19,
                  ),
                  SizedBox(width: 9),
                  Text(
                    "Today's payment summary",
                    style: TextStyle(
                      color: Color(0xFF263A30),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (snapshot.connectionState == ConnectionState.waiting)
                const LinearProgressIndicator()
              else if (snapshot.hasError)
                const Text(
                  'Payment totals are unavailable while the API is offline.',
                  style: TextStyle(color: Color(0xFF7B897F), fontSize: 12),
                )
              else if (snapshot.data!.dashboard.paymentSummary.isEmpty)
                const Text(
                  'No payments recorded today.',
                  style: TextStyle(color: Color(0xFF7B897F), fontSize: 12),
                )
              else
                Wrap(
                  spacing: 24,
                  runSpacing: 12,
                  children: [
                    for (final payment
                        in snapshot.data!.dashboard.paymentSummary)
                      _PaymentSummaryItem(payment: payment),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PaymentSummaryItem extends StatelessWidget {
  const _PaymentSummaryItem({required this.payment});

  final PaymentSummary payment;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            payment.method,
            style: const TextStyle(color: Color(0xFF7B897F), fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            '₹ ${payment.amount}',
            style: const TextStyle(
              color: Color(0xFF20372C),
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            '${payment.invoiceCount} ${payment.invoiceCount == 1 ? 'bill' : 'bills'}',
            style: const TextStyle(color: Color(0xFF87948A), fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.buttonKey,
    required this.onPressed,
    this.primary = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Key buttonKey;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final foreground = primary ? Colors.white : const Color(0xFF284236);
    return Material(
      color: primary ? const Color(0xFF245C45) : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: buttonKey,
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        hoverColor: primary
            ? Colors.white.withAlpha((0.08 * 255).round())
            : const Color(0xFFEDF4EF),
        child: Container(
          constraints: const BoxConstraints(minWidth: 240, maxWidth: 390),
          padding: const EdgeInsets.all(19),
          decoration: BoxDecoration(
            border: primary ? null : Border.all(color: const Color(0xFFE3EAE4)),
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [
              BoxShadow(
                color: Color(0x08000000),
                blurRadius: 12,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(icon, color: foreground, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: primary
                            ? Colors.white70
                            : const Color(0xFF75857A),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_rounded, color: foreground, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _CashierWelcomeCard extends StatelessWidget {
  const _CashierWelcomeCard({required this.username, required this.onNewBill});

  final String username;
  final VoidCallback onNewBill;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF245C45), Color(0xFF347557)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A173E32),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 24,
        runSpacing: 22,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'READY FOR YOUR NEXT SALE?',
                  style: TextStyle(
                    color: Color(0xFFCBE2D2),
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 11),
                Text(
                  'Hello, $username',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  'Create a bill, find products, or reopen a saved invoice.',
                  style: TextStyle(
                    color: Color(0xFFE0EEE4),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            key: const Key('cashierPrimaryNewBillButton'),
            onPressed: onNewBill,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF245C45),
              minimumSize: const Size(176, 48),
            ),
            icon: const Icon(Icons.point_of_sale_rounded),
            label: const Text('New Bill'),
          ),
        ],
      ),
    );
  }
}

class _InlineErrorMessage extends StatelessWidget {
  const _InlineErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF0EF),
      border: Border.all(color: const Color(0xFFF3D1CC)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      message,
      style: const TextStyle(color: Color(0xFF8A3C34), fontSize: 13),
    ),
  );
}

class _PasswordChange {
  const _PasswordChange(this.currentPassword, this.newPassword);

  final String currentPassword;
  final String newPassword;
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();

  @override
  void dispose() {
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Change password'),
    content: Form(
      key: _formKey,
      child: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('currentPasswordField'),
              controller: _currentPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Current password',
                border: OutlineInputBorder(),
              ),
              validator: (value) => value == null || value.isEmpty
                  ? 'Enter current password.'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('newPasswordField'),
              controller: _newPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password',
                border: OutlineInputBorder(),
              ),
              validator: (value) => value == null || value.length < 4
                  ? 'Use at least 4 characters.'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('confirmPasswordField'),
              controller: _confirmPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  value != _newPassword.text ? 'Passwords do not match.' : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('submitPasswordChangeButton'),
        onPressed: () {
          if (!_formKey.currentState!.validate()) return;
          Navigator.of(context)
              .pop(_PasswordChange(_currentPassword.text, _newPassword.text));
        },
        child: const Text('Change password'),
      ),
    ],
  );
}

class _CashierCredentials {
  const _CashierCredentials(this.username, this.password);

  final String username;
  final String password;
}

class _CreateCashierDialog extends StatefulWidget {
  const _CreateCashierDialog();

  @override
  State<_CreateCashierDialog> createState() => _CreateCashierDialogState();
}

class _CreateCashierDialogState extends State<_CreateCashierDialog> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _passwordVisible = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    Navigator.of(context).pop(
      _CashierCredentials(
        _usernameController.text.trim(),
        _passwordController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create cashier login'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('cashierUsernameField'),
                controller: _usernameController,
                autofocus: true,
                autocorrect: false,
                textCapitalization: TextCapitalization.none,
                decoration: const InputDecoration(
                  labelText: 'Cashier username',
                  helperText: '3–64 letters, numbers, dots, _ or -',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null ||
                      !RegExp(r'^[A-Za-z0-9._-]{3,64}$').hasMatch(value)) {
                    return 'Use 3–64 letters, numbers, dots, _ or -.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('cashierPasswordField'),
                controller: _passwordController,
                obscureText: !_passwordVisible,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Temporary password',
                  helperText:
                      'Use at least 4 characters (maximum 72 UTF-8 bytes)',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _passwordVisible
                        ? 'Hide password'
                        : 'Show password',
                    onPressed: () =>
                        setState(() => _passwordVisible = !_passwordVisible),
                    icon: Icon(
                      _passwordVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                validator: (value) {
                  final text = value ?? '';
                  final bytes = utf8.encode(text).length;
                  if (text.runes.length < 4 || bytes > 72) {
                    return 'Use at least 4 characters and no more than 72 UTF-8 bytes.';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('saveCashierButton'),
          onPressed: _submit,
          child: const Text('Create login'),
        ),
      ],
    );
  }
}
