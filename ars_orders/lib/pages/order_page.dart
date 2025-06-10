import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:ars_orders/models/notification.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/order.dart';
import '../services/api.dart';
import '../services/socket_service.dart';
import 'add_order_page.dart';
import 'orders_detail_page.dart';

class OrdersPage extends StatefulWidget {
  final VoidCallback onLogout;
  const OrdersPage({super.key, required this.onLogout});
  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  static const int _pageSize = 25;
  int _currentPage = 1, _totalPages = 1;
  String _searchQuery = '';
  String _sortedColumn = 'created';
  String _selectedStatus = 'all';
  bool? _isSortAscending = false;
  List<Order> _orders = [];

  final LayerLink _notifLink = LayerLink();
  static const double _kCardHeight = 400;
  bool _newNotificaiton = false;
  late final StreamSubscription<NotificationItem> _notifSub;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.text = _searchQuery;
    final socket = SocketService().socket;
    socket.off('ordersUpdated', _onSocketOrdersUpdated);
    socket.on('ordersUpdated', _onSocketOrdersUpdated);
    _loadOrders();

    _notifSub = SocketService().onNewNotificationStream.listen((notif) {
      if (!mounted) return;
      setState(() {
        _newNotificaiton = true;
      });
    });
  }

  @override
  void dispose() {
    final socket = SocketService().socket;
    socket.off('ordersUpdated', _onSocketOrdersUpdated);
    _searchController.dispose();
    _notifSub.cancel();
    super.dispose();
  }

  /// Peeks at the very top route on the root navigator without popping anything.
  String? _topRouteName(BuildContext context) {
    if (!mounted) return '';
    Route<dynamic>? top;
    Navigator.of(context, rootNavigator: true).popUntil((route) {
      top = route;
      return true; // immediately stop—no popping
    });
    return top?.settings.name;
  }

  void _onSocketOrdersUpdated(dynamic _) {
    if (!mounted) return;

    final current = _topRouteName(context);
    // only reload if we're *not* on the details page
    if (current != 'OrderDetailPage') {
      _loadOrders(page: _currentPage);
    }
  }

  Future<void> _loadOrders({int page = 1}) async {
    final uri = Uri.parse('${getBaseUrl()}/orders').replace(
      queryParameters: {
        'page': '$page',
        'limit': '$_pageSize',
        'search': _searchQuery,
        'status': _selectedStatus,
      },
    );

    // grab token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');

    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });
    if (resp.statusCode == 200) {
      final jsonBody = jsonDecode(resp.body);
      setState(() {
        _orders =
            (jsonBody['data'] as List).map((o) => Order.fromJson(o)).toList();
        _currentPage = jsonBody['page'];
        _totalPages = jsonBody['totalPages'];
        if (_sortedColumn == 'date') {
          _sortByDate();
        } else if (_sortedColumn == 'name') {
          _sortByName();
        } else if (_sortedColumn == 'created') {
          _sortByCreated();
        } else if (_sortedColumn == 'ETA') {
          _sortByEta();
        }
      });
    } else if (resp.statusCode == 401 || resp.statusCode == 403) {
      widget.onLogout(); // this flips _loggedIn=false in main.dart
    } else {
      throw Exception('Failed to load orders');
    }
  }

  void _showNotifications() {
    showDialog(
      barrierColor: Colors.transparent,
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        double dialogwidth =
            (MediaQuery.of(ctx).size.width * 0.7).clamp(200.0, 350.0);

        return Stack(
          children: [
            // ② Use CompositedTransformFollower to anchor to _notifLink:
            CompositedTransformFollower(
              link: _notifLink,
              showWhenUnlinked: false,
              offset: Offset(-dialogwidth + 65, 50),
              // 36 is roughly the height of the IconButton (plus some padding). Adjust as needed.
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: dialogwidth,
                  height: _kCardHeight,
                  child: const _NotificationSheetContent(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _onSearch(String q) {
    setState(() => _searchQuery = q);
    _loadOrders(page: 1);
  }

  void _sortByName() {
    setState(() {
      _orders.sort((a, b) {
        final cmp = a.customerName
            .toLowerCase()
            .compareTo(b.customerName.toLowerCase());
        return _isSortAscending! ? -cmp : cmp;
      });
    });
  }

  void _sortByCreated() {
    setState(() {
      _orders.sort((a, b) {
        final aHigh = (a.urgent == 1) &&
            a.status != 'Collected' &&
            a.status != 'Delivered';
        final bHigh = (b.urgent == 1) &&
            b.status != 'Collected' &&
            b.status != 'Delivered';

        // 1) if one is high-priority, it comes first
        if (aHigh && !bHigh) return -1;
        if (!aHigh && bHigh) return 1;

        // 2) otherwise fall back to  existing id/createdAt compare
        final cmp = (a.id ?? 0).compareTo(b.id ?? 0);
        return _isSortAscending! ? cmp : -cmp;
      });
    });
  }

  void _sortByDate() {
    setState(() {
      _orders.sort((a, b) {
        final da = DateFormat('dd/MM/yyyy').parse(a.dateOrdered);
        final db = DateFormat('dd/MM/yyyy').parse(b.dateOrdered);
        return _isSortAscending! ? da.compareTo(db) : db.compareTo(da);
      });
    });
  }

  void _sortByEta() {
    final formatter = DateFormat('dd/MM/yyyy HH:mm');
    setState(() {
      _orders.sort((a, b) {
        // 1) done‐status check
        final aDone = a.status == 'Collected' || a.status == 'Delivered';
        final bDone = b.status == 'Collected' || b.status == 'Delivered';
        if (aDone != bDone) {
          // aDone true → a goes below → return positive
          return aDone ? 1 : -1;
        }

        // 2) both same
        DateTime da;
        try {
          da = a.eta.isNotEmpty
              ? formatter.parse(a.eta)
              : DateTime.fromMillisecondsSinceEpoch(0);
        } catch (_) {
          da = DateTime.fromMillisecondsSinceEpoch(0);
        }

        DateTime db;
        try {
          db = b.eta.isNotEmpty
              ? formatter.parse(b.eta)
              : DateTime.fromMillisecondsSinceEpoch(0);
        } catch (_) {
          db = DateTime.fromMillisecondsSinceEpoch(0);
        }

        // 3) apply ascending/descending as before
        if (!_isSortAscending!) {
          return da.compareTo(db);
        } else {
          return db.compareTo(da);
        }
      });
    });
  }

  void _goToPage(int p) {
    if (p < 1 || p > _totalPages) return;
    _loadOrders(page: p);
  }

  void _navigateToAdd() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddOrderPage(onAddOrder: (_) => _loadOrders(page: 1)),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'Pending':
        return Colors.deepPurple;
      case 'Waiting':
        return Colors.blueAccent;
      case 'In Progress':
        return Colors.blue;
      case 'Awaiting Collection':
        return Colors.orange;
      case 'Awaiting Delivery':
        return Colors.orange;
      case 'Collected':
        return Colors.green;
      case 'Delivered':
        return Colors.green;
      case 'Cancelled':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final boxWidth = screenWidth < 390
        ? 100 // e.g. full‐width minus some padding
        : 155;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
            child: Column(
              children: [
                // Title
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Transform.scale(
                      scaleX: -1,
                      scaleY: 1,
                      child: IconButton(
                        icon: const Icon(
                          FontAwesomeIcons.rightToBracket,
                          size: 25,
                          color: Colors.deepPurple,
                        ),
                        tooltip: 'Logout',
                        onPressed: widget.onLogout,
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          FontAwesomeIcons.boxArchive,
                          size: 25,
                          color: Colors.deepPurple,
                        ),
                        const SizedBox(
                          width: 8,
                        ),
                        Text('Orders',
                            style: theme.textTheme.titleLarge!
                                .copyWith(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          CompositedTransformTarget(
                            link: _notifLink,
                            child: IconButton(
                              icon: Icon(
                                !_newNotificaiton
                                    ? Icons.notifications_outlined
                                    : Icons.notification_add_rounded,
                                size: 28,
                                color: Colors.deepPurple,
                              ),
                              onPressed: () {
                                _showNotifications();
                                setState(() {
                                  _newNotificaiton = false;
                                });
                              },
                            ),
                          ),
                          const SizedBox(
                            width: 4,
                          ),
                          const CircleAvatar(
                            radius: 25,
                            backgroundImage: AssetImage(
                              'images/arslogo.jpg',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // Search Bar

                LayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = 8.0;
                    const sortWidth = 155.0;
                    const buttonWidth = 140.0;
                    const minFlexWidth = 150.0;
                    const itemHeight = 35.0;

                    final maxWidth = constraints.maxWidth;
                    // space taken by the two fixed widgets + gaps around the two flex ones
                    const fixedTotal = sortWidth + buttonWidth + spacing * 3;
                    final available = maxWidth - fixedTotal;

                    double searchWidth, statusWidth;
                    if (available >= minFlexWidth * 2) {
                      // enough room: share the leftover equally
                      searchWidth = available / 2;
                      statusWidth = available / 2;
                    } else {
                      // not enough room: each takes its own full‐width run
                      searchWidth = maxWidth;
                      statusWidth = maxWidth;
                    }

                    return SizedBox(
                      width: double.infinity,
                      child: Wrap(
                        alignment: screenWidth > 400
                            ? WrapAlignment.end
                            : WrapAlignment.center,
                        spacing: spacing,
                        runSpacing: spacing,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          // 1) SEARCH BAR
                          SizedBox(
                            width: searchWidth,
                            height: itemHeight,
                            child: Card(
                              margin: EdgeInsets.zero,
                              color: Colors.white,
                              elevation: 1,
                              child: TextField(
                                controller: _searchController,
                                textAlignVertical: TextAlignVertical.center,
                                style: const TextStyle(height: 1.0),
                                decoration: InputDecoration(
                                  isCollapsed: true,
                                  contentPadding: EdgeInsets.zero,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(
                                        color: Colors.grey, width: 1),
                                  ),
                                  prefixIcon: const Icon(
                                      FontAwesomeIcons.magnifyingGlass,
                                      size: 20,
                                      color: Colors.deepPurple),
                                  prefixIconConstraints:
                                      const BoxConstraints.tightFor(
                                    width: itemHeight,
                                    height: itemHeight,
                                  ),
                                  hintText: 'Search orders…',
                                ),
                                onChanged: _onSearch,
                              ),
                            ),
                          ),

                          // 2) STATUS DROPDOWN
                          SizedBox(
                            width: statusWidth,
                            height: itemHeight,
                            child: Card(
                              margin: EdgeInsets.zero,
                              color: Colors.white,
                              elevation: 1,
                              child: Container(
                                padding:
                                    const EdgeInsets.only(left: 8, right: 8),
                                decoration: BoxDecoration(
                                  border:
                                      Border.all(color: Colors.grey, width: 1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(FontAwesomeIcons.sliders,
                                        size: 20, color: Colors.deepPurple),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: DropdownButton<String>(
                                        isExpanded: true,
                                        underline: const SizedBox(),
                                        borderRadius: BorderRadius.circular(8),
                                        isDense: true,
                                        focusColor: Colors.transparent,
                                        elevation: 1,
                                        value: _selectedStatus,
                                        alignment: Alignment.centerLeft,
                                        style: const TextStyle(fontSize: 14),
                                        items: <String>[
                                          'all',
                                          'Pending',
                                          'Waiting',
                                          'In Progress',
                                          'Awaiting Collection',
                                          'Cancelled',
                                          'Awaiting Delivery',
                                          'Collected',
                                          'Delivered',
                                        ]
                                            .map((s) => DropdownMenuItem(
                                                  value: s,
                                                  child: Text(
                                                    s[0].toUpperCase() +
                                                        s.substring(1),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ))
                                            .toList(),
                                        onChanged: (newStatus) {
                                          setState(() =>
                                              _selectedStatus = newStatus!);
                                          _loadOrders(page: 1);
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // 3) SORT ICON + DROPDOWN
                          SizedBox(
                            width: sortWidth,
                            height: itemHeight,
                            child: Card(
                              margin: EdgeInsets.zero,
                              color: Colors.white,
                              elevation: 1,
                              child: Container(
                                padding:
                                    const EdgeInsets.only(left: 0, right: 8),
                                decoration: BoxDecoration(
                                  border:
                                      Border.all(color: Colors.grey, width: 1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      highlightColor: Colors.transparent,
                                      hoverColor: Colors.transparent,
                                      padding: EdgeInsets.zero,
                                      icon: Icon(
                                        _isSortAscending!
                                            ? FontAwesomeIcons.arrowUpShortWide
                                            : FontAwesomeIcons
                                                .arrowDownShortWide,
                                        size: 20,
                                        color: Colors.deepPurple,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _isSortAscending = !_isSortAscending!;
                                          _loadOrders(page: _currentPage);
                                        });
                                      },
                                    ),
                                    Expanded(
                                      child: DropdownButton<String>(
                                        isExpanded: true,
                                        focusColor: Colors.transparent,
                                        underline: const SizedBox(),
                                        borderRadius: BorderRadius.circular(8),
                                        isDense: true,
                                        elevation: 1,
                                        value: _sortedColumn,
                                        alignment: Alignment.center,
                                        style: const TextStyle(fontSize: 14),
                                        items: <String>[
                                          'created',
                                          'name',
                                          'date',
                                          'ETA'
                                        ]
                                            .map((s) => DropdownMenuItem(
                                                  value: s,
                                                  child: Text(
                                                    s[0].toUpperCase() +
                                                        s.substring(1),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ))
                                            .toList(),
                                        onChanged: (sortType) {
                                          setState(
                                              () => _sortedColumn = sortType!);
                                          _loadOrders(page: _currentPage);
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // 4) CREATE ORDER BUTTON
                          SizedBox(
                            width: buttonWidth,
                            height: itemHeight,
                            child: Card(
                              margin: EdgeInsets.zero,
                              color: Colors.white,
                              elevation: 1,
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.only(left: 8),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  side: const BorderSide(
                                      color: Colors.grey, width: 1),
                                ),
                                onPressed: _navigateToAdd,
                                child: Row(
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    Icon(FontAwesomeIcons.folderPlus,
                                        size: 20,
                                        color: Colors.deepPurple.shade500),
                                    const SizedBox(width: 8),
                                    Text('Create Order',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                const SizedBox(
                  height: 16,
                ),
                // Orders List
                if (_orders.isNotEmpty)
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: _orders
                          .map((o) => GestureDetector(
                                onTap: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        settings: const RouteSettings(
                                            name: 'OrderDetailPage'),
                                        builder: (_) =>
                                            OrderDetailPage(order: o)),
                                  );
                                  // only runs when the detail page pops
                                  _loadOrders(page: _currentPage);
                                },
                                child: Card(
                                  margin: const EdgeInsets.all(8),
                                  color: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  elevation: 8,
                                  child: Column(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.only(
                                            top: 8, bottom: 8, right: 8),
                                        decoration: const BoxDecoration(
                                            borderRadius: BorderRadius.only(
                                                topLeft: Radius.circular(10),
                                                topRight: Radius.circular(10)),
                                            color: Colors.white),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.start,
                                          children: [
                                            const SizedBox(
                                              width: 8,
                                            ),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.all(8.0),
                                              child: Icon(
                                                FontAwesomeIcons.solidUser,
                                                size: 25,
                                                color:
                                                    Colors.deepPurple.shade500,
                                              ),
                                            ),
                                            Expanded(
                                              child: AutoSizeText(
                                                o.customerName.toUpperCase(),
                                                style: theme
                                                    .textTheme.titleMedium!
                                                    .copyWith(
                                                        fontWeight:
                                                            FontWeight.w600),
                                                maxLines:
                                                    2, // keep it on one line
                                                minFontSize:
                                                    8, // smallest font size
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.end,
                                              children: [
                                                if (o.urgent == 1)
                                                  const Padding(
                                                    padding: EdgeInsets.only(
                                                        right: 8.0, bottom: 4),
                                                    child: Card(
                                                      color: Colors.white,
                                                      elevation: 1,
                                                      child: Chip(
                                                          label: Text(
                                                        'URGENT',
                                                        style: TextStyle(
                                                            color: Colors.red),
                                                      )),
                                                    ),
                                                  ),
                                                Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.center,
                                                  children: [
                                                    const Icon(
                                                      FontAwesomeIcons
                                                          .calendarDay,
                                                      size: 25,
                                                      color: Colors.deepPurple,
                                                    ),
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              right: 8,
                                                              left: 8),
                                                      child: Text(
                                                        o.dateOrdered,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Divider(
                                        color: Colors.deepPurple,
                                        height: 1,
                                        thickness: 2,
                                        endIndent: 17,
                                        indent: 15,
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 12),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            // 🖼 Image
                                            (screenWidth >= 550)
                                                ? Row(
                                                    spacing: 4,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      o.images.isNotEmpty
                                                          ? Card(
                                                              color:
                                                                  Colors.white,
                                                              elevation: 8,
                                                              child: ClipRRect(
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8),
                                                                child:
                                                                    CachedNetworkImage(
                                                                  imageUrl:
                                                                      '${getBaseUrl()}/uploads/${o.images.first}',
                                                                  width: 100,
                                                                  height: 100,
                                                                  maxWidthDiskCache:
                                                                      200,
                                                                  fit: BoxFit
                                                                      .cover,
                                                                  errorWidget: (_,
                                                                          __,
                                                                          ___) =>
                                                                      const Icon(
                                                                    FontAwesomeIcons
                                                                        .solidImage,
                                                                    color: Colors
                                                                        .deepPurple,
                                                                  ),
                                                                ),
                                                              ),
                                                            )
                                                          : const Icon(
                                                              FontAwesomeIcons
                                                                  .solidImage,
                                                              size: 100,
                                                              color: Colors
                                                                  .deepPurple,
                                                            ),
                                                      const SizedBox(width: 12),
                                                      if (o
                                                          .documents.isNotEmpty)
                                                        SizedBox(
                                                          height: 100,
                                                          width: clampDouble(
                                                              screenWidth - 400,
                                                              100,
                                                              300),
                                                          child: ListView
                                                              .separated(
                                                            scrollDirection:
                                                                Axis.vertical,
                                                            shrinkWrap:
                                                                true, // ← allow it to size itself
                                                            physics:
                                                                const AlwaysScrollableScrollPhysics(),
                                                            itemCount: o
                                                                .documents
                                                                .length,
                                                            separatorBuilder: (_,
                                                                    __) =>
                                                                const SizedBox(
                                                                    height: 2),
                                                            itemBuilder:
                                                                (ctx, i) {
                                                              final doc = o
                                                                  .documents[i];
                                                              final url =
                                                                  '${getBaseUrl()}/uploads/${doc.filename}';
                                                              return GestureDetector(
                                                                onTap: () {
                                                                  final name = doc
                                                                      .originalName
                                                                      .toLowerCase();
                                                                  final ext = name
                                                                      .split(
                                                                          '.')
                                                                      .last;
                                                                  Uri target;

                                                                  if (ext ==
                                                                      'pdf') {
                                                                    Navigator
                                                                        .push(
                                                                      context,
                                                                      MaterialPageRoute(
                                                                        builder:
                                                                            (_) =>
                                                                                Scaffold(
                                                                          appBar: AppBar(
                                                                              backgroundColor: Colors.white,
                                                                              title: Center(child: Text(doc.originalName))),
                                                                          body:
                                                                              PdfViewer.uri(Uri.parse(url)),
                                                                        ),
                                                                      ),
                                                                    );
                                                                  } else if (ext ==
                                                                          'doc' ||
                                                                      ext ==
                                                                          'docx') {
                                                                    // Word docs go through Office Online viewer
                                                                    final encoded =
                                                                        Uri.encodeComponent(
                                                                            url);
                                                                    target = Uri
                                                                        .parse(
                                                                            'https://view.officeapps.live.com/op/view.aspx?src=$encoded');
                                                                    // Open in new tab (webOnlyWindowName only works on web)
                                                                    launchUrl(
                                                                        target,
                                                                        webOnlyWindowName:
                                                                            '_blank');
                                                                  }
                                                                },
                                                                child: SizedBox(
                                                                  height: 50,
                                                                  width: double
                                                                      .infinity,
                                                                  child: Card(
                                                                    elevation:
                                                                        4,
                                                                    margin:
                                                                        const EdgeInsets
                                                                            .all(
                                                                            4),
                                                                    child:
                                                                        Container(
                                                                      width: boxWidth
                                                                          as double,
                                                                      decoration: BoxDecoration(
                                                                          borderRadius: BorderRadius.circular(8),
                                                                          border: Border.all(
                                                                            color:
                                                                                Colors.grey,
                                                                            width:
                                                                                1,
                                                                          )),
                                                                      child:
                                                                          Row(
                                                                        children: [
                                                                          Padding(
                                                                            padding: const EdgeInsets.only(
                                                                                left: 8,
                                                                                top: 4,
                                                                                bottom: 4),
                                                                            child:
                                                                                Icon(doc.originalName.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf : FontAwesomeIcons.solidFileWord, color: doc.originalName.toLowerCase().endsWith('.pdf') ? Colors.redAccent : Colors.blueAccent),
                                                                          ),
                                                                          Flexible(
                                                                            child:
                                                                                Padding(
                                                                              padding: const EdgeInsets.all(8.0),
                                                                              child: Text(
                                                                                doc.originalName,
                                                                                maxLines: 1,
                                                                                overflow: TextOverflow.ellipsis,
                                                                                textAlign: TextAlign.center,
                                                                                style: const TextStyle(fontSize: 14),
                                                                              ),
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                        ),
                                                    ],
                                                  )
                                                : Column(
                                                    spacing: 4,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      o.images.isNotEmpty
                                                          ? Card(
                                                              color:
                                                                  Colors.white,
                                                              elevation: 8,
                                                              child: ClipRRect(
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8),
                                                                child:
                                                                    CachedNetworkImage(
                                                                  imageUrl:
                                                                      '${getBaseUrl()}/uploads/${o.images.first}',
                                                                  width: 100,
                                                                  height: 100,
                                                                  maxWidthDiskCache:
                                                                      200,
                                                                  fit: BoxFit
                                                                      .cover,
                                                                  errorWidget: (_,
                                                                          __,
                                                                          ___) =>
                                                                      const Icon(
                                                                    FontAwesomeIcons
                                                                        .solidImage,
                                                                    color: Colors
                                                                        .deepPurple,
                                                                  ),
                                                                ),
                                                              ),
                                                            )
                                                          : const Icon(
                                                              FontAwesomeIcons
                                                                  .solidImage,
                                                              size: 100,
                                                              color: Colors
                                                                  .deepPurple,
                                                            ),
                                                      const SizedBox(width: 12),
                                                      if (o
                                                          .documents.isNotEmpty)
                                                        SizedBox(
                                                          height: 100,
                                                          width: clampDouble(
                                                              screenWidth - 300,
                                                              100,
                                                              300),
                                                          child: ListView
                                                              .separated(
                                                            scrollDirection:
                                                                Axis.vertical,
                                                            shrinkWrap:
                                                                true, // ← allow it to size itself
                                                            physics:
                                                                const AlwaysScrollableScrollPhysics(),
                                                            itemCount: o
                                                                .documents
                                                                .length,
                                                            separatorBuilder: (_,
                                                                    __) =>
                                                                const SizedBox(
                                                                    height: 2),
                                                            itemBuilder:
                                                                (ctx, i) {
                                                              final doc = o
                                                                  .documents[i];
                                                              final url =
                                                                  '${getBaseUrl()}/uploads/${doc.filename}';
                                                              return GestureDetector(
                                                                onTap: () {
                                                                  final name = doc
                                                                      .originalName
                                                                      .toLowerCase();
                                                                  final ext = name
                                                                      .split(
                                                                          '.')
                                                                      .last;
                                                                  Uri target;

                                                                  if (ext ==
                                                                      'pdf') {
                                                                    Navigator
                                                                        .push(
                                                                      context,
                                                                      MaterialPageRoute(
                                                                        builder:
                                                                            (_) =>
                                                                                Scaffold(
                                                                          appBar: AppBar(
                                                                              backgroundColor: Colors.white,
                                                                              title: Center(child: Text(doc.originalName))),
                                                                          body:
                                                                              PdfViewer.uri(Uri.parse(url)),
                                                                        ),
                                                                      ),
                                                                    );
                                                                  } else if (ext ==
                                                                          'doc' ||
                                                                      ext ==
                                                                          'docx') {
                                                                    // Word docs go through Office Online viewer
                                                                    final encoded =
                                                                        Uri.encodeComponent(
                                                                            url);
                                                                    target = Uri
                                                                        .parse(
                                                                            'https://view.officeapps.live.com/op/view.aspx?src=$encoded');
                                                                    // Open in new tab (webOnlyWindowName only works on web)
                                                                    launchUrl(
                                                                        target,
                                                                        webOnlyWindowName:
                                                                            '_blank');
                                                                  }
                                                                },
                                                                child: SizedBox(
                                                                  height: 50,
                                                                  width: double
                                                                      .infinity,
                                                                  child: Card(
                                                                    elevation:
                                                                        4,
                                                                    margin:
                                                                        const EdgeInsets
                                                                            .all(
                                                                            4),
                                                                    child:
                                                                        Container(
                                                                      width: boxWidth
                                                                          as double,
                                                                      decoration: BoxDecoration(
                                                                          borderRadius: BorderRadius.circular(8),
                                                                          border: Border.all(
                                                                            color:
                                                                                Colors.grey,
                                                                            width:
                                                                                1,
                                                                          )),
                                                                      child:
                                                                          Row(
                                                                        children: [
                                                                          Padding(
                                                                            padding: const EdgeInsets.only(
                                                                                left: 8,
                                                                                top: 4,
                                                                                bottom: 4),
                                                                            child:
                                                                                Icon(doc.originalName.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf : FontAwesomeIcons.solidFileWord, color: doc.originalName.toLowerCase().endsWith('.pdf') ? Colors.redAccent : Colors.blueAccent),
                                                                          ),
                                                                          Flexible(
                                                                            child:
                                                                                Padding(
                                                                              padding: const EdgeInsets.all(8.0),
                                                                              child: Text(
                                                                                doc.originalName,
                                                                                maxLines: 1,
                                                                                overflow: TextOverflow.ellipsis,
                                                                                textAlign: TextAlign.center,
                                                                                style: const TextStyle(fontSize: 14),
                                                                              ),
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                        ),
                                                    ],
                                                  ),

                                            Expanded(child: Container()),
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    const Padding(
                                                      padding:
                                                          EdgeInsets.all(8.0),
                                                      child: Icon(
                                                        FontAwesomeIcons
                                                            .hashtag,
                                                        color:
                                                            Colors.deepPurple,
                                                      ),
                                                    ),
                                                    Card(
                                                      color: Colors.white,
                                                      elevation: 1,
                                                      child: Container(
                                                        width:
                                                            boxWidth as double,
                                                        decoration:
                                                            BoxDecoration(
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8),
                                                                border:
                                                                    Border.all(
                                                                  color: Colors
                                                                      .grey,
                                                                  width: 1,
                                                                )),
                                                        child: Center(
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .all(8.0),
                                                            child: AutoSizeText(
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              maxLines: 2,
                                                              o.jobId
                                                                  .toUpperCase(),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(
                                                  height: 5,
                                                ),
                                                Row(
                                                  children: [
                                                    const Padding(
                                                      padding:
                                                          EdgeInsets.all(8.0),
                                                      child: Icon(
                                                        FontAwesomeIcons.house,
                                                        size: 25,
                                                        color:
                                                            Colors.deepPurple,
                                                      ),
                                                    ),
                                                    Card(
                                                      color: Colors.white,
                                                      elevation: 1,
                                                      child: Container(
                                                        decoration:
                                                            BoxDecoration(
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8),
                                                                border:
                                                                    Border.all(
                                                                  color: Colors
                                                                      .grey,
                                                                  width: 1,
                                                                )),
                                                        width:
                                                            boxWidth as double,
                                                        child: Center(
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .all(8.0),
                                                            child: AutoSizeText(
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              maxLines: 2,
                                                              o.address!
                                                                  .toUpperCase(),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(
                                                  height: 5,
                                                ),
                                                Row(
                                                  children: [
                                                    const Padding(
                                                      padding:
                                                          EdgeInsets.all(8.0),
                                                      child: Icon(
                                                        FontAwesomeIcons
                                                            .circleInfo,
                                                        color:
                                                            Colors.deepPurple,
                                                      ),
                                                    ),
                                                    Card(
                                                      color: Colors.white,
                                                      elevation: 1,
                                                      child: Container(
                                                        decoration:
                                                            BoxDecoration(
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8),
                                                                border:
                                                                    Border.all(
                                                                  color: Colors
                                                                      .grey,
                                                                  width: 1,
                                                                )),
                                                        width:
                                                            boxWidth as double,
                                                        child: Center(
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .all(8.0),
                                                            child: AutoSizeText(
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              maxLines: 2,
                                                              style: TextStyle(
                                                                  color: _statusColor(
                                                                      o.status)),
                                                              o.status,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(
                                                  height: 5,
                                                ),
                                                Row(
                                                  children: [
                                                    const Padding(
                                                      padding:
                                                          EdgeInsets.all(8.0),
                                                      child: Icon(
                                                        FontAwesomeIcons
                                                            .solidClock,
                                                        color:
                                                            Colors.deepPurple,
                                                      ),
                                                    ),
                                                    Card(
                                                      color: Colors.white,
                                                      elevation: 1,
                                                      child: Container(
                                                        decoration:
                                                            BoxDecoration(
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8),
                                                                border:
                                                                    Border.all(
                                                                  color: Colors
                                                                      .grey,
                                                                  width: 1,
                                                                )),
                                                        width:
                                                            boxWidth as double,
                                                        child: Center(
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .all(8.0),
                                                            child: AutoSizeText(
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              maxLines: 2,
                                                              style: const TextStyle(
                                                                  color: Colors
                                                                      .black),
                                                              o.eta.isNotEmpty
                                                                  ? o.eta
                                                                  : 'NO ETA',
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      )
                                    ],
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                if (_orders.isEmpty) const Expanded(child: Text('No Results')),

                const SizedBox(height: 16),

                // Pagination
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Card(
                      color: Colors.white,
                      elevation: 1,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            side: const BorderSide(
                              color: Colors.grey,
                              width: 1,
                            )),
                        onPressed: _currentPage > 1
                            ? () => _goToPage(_currentPage - 1)
                            : null,
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('Prev'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                        'Page $_currentPage of ${_totalPages.clamp(1, double.infinity)}'),
                    const SizedBox(width: 16),
                    Card(
                      color: Colors.white,
                      elevation: 1,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            side: const BorderSide(
                              color: Colors.grey,
                              width: 1,
                            )),
                        onPressed: _currentPage < _totalPages
                            ? () => _goToPage(_currentPage + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                        label: const Text('Next'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationSheetContent extends StatefulWidget {
  const _NotificationSheetContent();
  @override
  State<_NotificationSheetContent> createState() =>
      _NotificationSheetContentState();
}

class _NotificationSheetContentState extends State<_NotificationSheetContent> {
  final List<NotificationItem> _notifications = [];
  int _offset = 0;
  final int _limit = 20;
  bool _isLoading = false;
  bool _hasMore = true;
  late final StreamSubscription<NotificationItem> _notifSub;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    // ② Load the first page of notifications
    _loadNotifications();

    // ③ Register to get real-time pushes
    _notifSub = SocketService().onNewNotificationStream.listen((notif) {
      if (!mounted) return;
      setState(() {
        _notifications.insert(0, notif);
      });
    });

    // ④ Pagination listener
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 100 &&
          !_isLoading &&
          _hasMore) {
        _loadNotifications();
      }
    });
  }

  @override
  void dispose() {
    // ⑤ Unregister the callback to avoid leaks
    _notifSub.cancel();
    _scrollController.dispose();

    super.dispose();
  }

  Future<void> _loadNotifications() async {
    if (_isLoading || !_hasMore) return;

    setState(() => _isLoading = true);

    try {
      final uri = Uri.parse(
        '${getBaseUrl()}/notifications?offset=$_offset&limit=$_limit',
      );
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt') ?? '';
      final resp = await http.get(uri, headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });

      if (resp.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(resp.body);
        final fetched = jsonList
            .map((e) => NotificationItem.fromJson(e as Map<String, dynamic>))
            .toList();

        setState(() {
          _notifications.addAll(fetched);
          _offset += _limit;
          if (fetched.length < _limit) _hasMore = false;
          _isLoading = false;
        });
      } else if (resp.statusCode == 403) {
        // handle unauthorized → logout, etc.
      } else {
        throw Exception('Failed to load notifications');
      }
    } catch (_) {
      setState(() => _isLoading = false);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                color: Colors.deepPurple,
                Icons.notifications,
                size: 25,
              ),
              SizedBox(
                width: 4,
              ),
              Text(
                'Notifications',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: (_notifications.isEmpty && _isLoading)
                ? const Center(child: CircularProgressIndicator())
                : (_notifications.isEmpty && !_isLoading)
                    ? const Center(child: Text('No Notifications'))
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: _notifications.length + (_hasMore ? 1 : 0),
                        itemBuilder: (ctx, idx) {
                          if (idx == _notifications.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          final notif = _notifications[idx];
                          return Card(
                            margin: const EdgeInsets.all(4),
                            clipBehavior: Clip.antiAlias,
                            elevation: 2,
                            child: ListTile(
                              title: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        DateFormat('dd/MM/yyyy HH:mm')
                                            .format(notif.createdAt.toLocal()),
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(
                                        width: 12,
                                      ),
                                      Flexible(
                                        child: AutoSizeText(
                                          maxLines: 2,
                                          minFontSize: 1,
                                          '${notif.senderId}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.only(top: 4, bottom: 4),
                                    child: Divider(
                                      height: 1,
                                      thickness: 2,
                                      color: Colors.deepPurple,
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                notif.message,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              onTap: () async {
                                if (notif.url == null) return;

                                // 1) Parse out the ID:
                                final parts = notif.url!.split('/');
                                final id = int.tryParse(parts.last);
                                if (id == null) return; // invalid URL

                                // 2) Capture NavigatorState and ScaffoldMessengerState now,
                                //    before any `await` so you never write `Navigator.of(context)`
                                //    after an async gap.
                                final navigator = Navigator.of(context);
                                final messenger = ScaffoldMessenger.of(context);

                                // 3) Do your async work (SharedPreferences + HTTP GET):
                                final prefs =
                                    await SharedPreferences.getInstance();
                                final token = prefs.getString('jwt') ?? '';
                                final uri =
                                    Uri.parse('${getBaseUrl()}/orders/$id');
                                final resp = await http.get(
                                  uri,
                                  headers: {
                                    'Authorization': 'Bearer $token',
                                    'Content-Type': 'application/json',
                                  },
                                );

                                // 4) Now branch on the response. Use the saved `navigator` / `messenger`.
                                if (resp.statusCode == 200) {
                                  final Map<String, dynamic> json =
                                      jsonDecode(resp.body);
                                  final fetchedOrder = Order.fromJson(json);

                                  // Pop the notification card, then push the detail page:
                                  navigator.pop();
                                  navigator.push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          OrderDetailPage(order: fetchedOrder),
                                    ),
                                  );
                                } else {
                                  // Show an error snackbar
                                  messenger.showSnackBar(
                                    SnackBar(
                                        content:
                                            Text('Could not load order #$id')),
                                  );
                                }
                              },
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
