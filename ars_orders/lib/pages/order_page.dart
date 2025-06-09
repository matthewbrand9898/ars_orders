import 'dart:convert';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

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

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.text = _searchQuery;
    final socket = SocketService().socket;
    socket.off('ordersUpdated', _onSocketOrdersUpdated);
    socket.on('ordersUpdated', _onSocketOrdersUpdated);
    _loadOrders();
  }

  @override
  void dispose() {
    final socket = SocketService().socket;
    socket.off('ordersUpdated', _onSocketOrdersUpdated);
    _searchController.dispose();
    super.dispose();
  }

  void _onSocketOrdersUpdated(dynamic _) {
    if (!mounted) return;
    // only reload if this route is still the one on top
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      if (!mounted) return;
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
        // parse a.eta, fallback to epoch if empty/invalid
        DateTime da;
        try {
          da = a.eta.isNotEmpty
              ? formatter.parse(a.eta)
              : DateTime.fromMillisecondsSinceEpoch(0);
        } catch (_) {
          da = DateTime.fromMillisecondsSinceEpoch(0);
        }

        // parse b.eta the same way
        DateTime db;
        try {
          db = b.eta.isNotEmpty
              ? formatter.parse(b.eta)
              : DateTime.fromMillisecondsSinceEpoch(0);
        } catch (_) {
          db = DateTime.fromMillisecondsSinceEpoch(0);
        }

        return !_isSortAscending! ? da.compareTo(db) : db.compareTo(da);
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
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: CircleAvatar(
                        radius: 25,
                        backgroundImage: AssetImage(
                          'images/arslogo.jpg',
                        ),
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
                                            o.images.isNotEmpty
                                                ? Card(
                                                    color: Colors.white,
                                                    elevation: 8,
                                                    child: ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8),
                                                      child: CachedNetworkImage(
                                                        imageUrl:
                                                            '${getBaseUrl()}/uploads/${o.images.first}',
                                                        width: 100,
                                                        height: 100,
                                                        maxWidthDiskCache: 200,
                                                        fit: BoxFit.cover,
                                                        errorWidget:
                                                            (_, __, ___) =>
                                                                const Icon(
                                                          FontAwesomeIcons
                                                              .solidImage,
                                                          color:
                                                              Colors.deepPurple,
                                                        ),
                                                      ),
                                                    ),
                                                  )
                                                : const Icon(
                                                    FontAwesomeIcons.solidImage,
                                                    size: 100,
                                                    color: Colors.deepPurple,
                                                  ),

                                            const SizedBox(width: 12),
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
