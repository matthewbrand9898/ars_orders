import 'dart:js_interop';

import 'package:ars_orders/pages/login_page.dart';
import 'package:ars_orders/pages/order_page.dart';
import 'package:audioplayers/audioplayers.dart';

//import 'package:flutter/rendering.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

void main() {
  // visualize padding, borders, and the size of each RenderBox
  //debugPaintSizeEnabled = true;

  WidgetsFlutterBinding.ensureInitialized();

  runApp(const OrdersApp());
}

class OrdersApp extends StatefulWidget {
  const OrdersApp({super.key});
  @override
  State<OrdersApp> createState() => _OrdersAppState();
}

class _OrdersAppState extends State<OrdersApp> {
  bool _loggedIn = false;
  final AudioPlayer _unlockPlayer = AudioPlayer();
  bool _audioUnlocked = false;
  late JSFunction clickHandler;
  void _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt');
    setState(() => _loggedIn = false); // 👈 this makes it go back to LoginPage
  }

  @override
  void initState() {
    super.initState();
    _checkToken();
    clickHandler = ((JSAny? event) {
      if (_audioUnlocked) return;
      _audioUnlocked = true;

      _unlockPlayer
          .play(
            UrlSource('assets/sounds/notificationSound.wav'),
            volume: 0,
          )
          .then((_) => _unlockPlayer.stop())
          .catchError((_) {});

      // remove listener after first click
      web.document.onclick = null;
    }).toJS;

    web.document.onclick = clickHandler;
  }

  @override
  void dispose() {
    _unlockPlayer.dispose();
    super.dispose();
    web.document.onclick = null;
  }

  Future<void> _checkToken() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _loggedIn = prefs.getString('jwt') != null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        snackBarTheme: const SnackBarThemeData(
            backgroundColor: Colors.white,
            showCloseIcon: true,
            closeIconColor: Colors.redAccent,
            elevation: 8,
            contentTextStyle: TextStyle(color: Colors.black)),
        timePickerTheme: TimePickerThemeData(
          backgroundColor: Colors.white,

          dayPeriodColor: WidgetStateColor.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? Colors.deepPurple
                : Colors.white;
          }),

          // AM/PM button text
          dayPeriodTextColor: WidgetStateColor.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? Colors.white
                : Colors.black;
          }),
        ),
        datePickerTheme: const DatePickerThemeData(
          backgroundColor: Colors.white,

          // you can also set shape, inputDecorationTheme, etc.
        ),

        cardTheme: const CardTheme(
          margin: EdgeInsets.zero,
          color: Colors.white,
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,

        scaffoldBackgroundColor: Colors.white,
        canvasColor: Colors
            .white, // for Material widgets like Drawer, Card backgrounds, etc.
      ),
      title: 'Aluminium Roofing Solutions',
      debugShowCheckedModeBanner: false,
      home: _loggedIn
          ? OrdersPage(onLogout: _logout)
          : LoginPage(onSuccess: () {
              setState(() => _loggedIn = true);
            }),
    );
  }
}
