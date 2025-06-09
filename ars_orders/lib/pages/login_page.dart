import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api.dart';

class LoginPage extends StatefulWidget {
  final VoidCallback onSuccess;
  const LoginPage({super.key, required this.onSuccess});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final resp = await http.post(
      Uri.parse('${getBaseUrl()}/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': _userCtrl.text.trim(),
        'password': _passCtrl.text,
      }),
    );
    setState(() => _loading = false);

    if (resp.statusCode == 200) {
      final token = jsonDecode(resp.body)['token'];

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('jwt', token);

      widget.onSuccess();
    } else {
      setState(() => _error = 'Login failed');
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: Center(
                child: Card(
                  color: Colors.white,
                  elevation: 4,
                  margin: const EdgeInsets.all(24),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const CircleAvatar(
                            radius: 35,
                            backgroundImage: AssetImage(
                              'images/arslogo.jpg',
                            ),
                          ),
                          Row(
                            children: [
                              const Padding(
                                padding: EdgeInsets.all(8.0),
                                child: Icon(
                                  FontAwesomeIcons.unlock,
                                  size: 30,
                                  color: Colors.deepPurple,
                                ),
                              ),
                              Text(
                                'Login',
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                          const SizedBox(
                            width: 86,
                          ),
                        ],
                      ),
                      AutofillGroup(
                        child: Column(
                          children: [
                            TextField(
                              controller: _userCtrl,
                              decoration: const InputDecoration(
                                  labelText: 'Username',
                                  suffixIcon: Icon(
                                    FontAwesomeIcons.solidUser,
                                    color: Colors.deepPurple,
                                  )),
                              autofillHints: const [AutofillHints.username],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _passCtrl,
                              decoration: const InputDecoration(
                                  labelText: 'Password',
                                  suffixIcon: Icon(
                                    FontAwesomeIcons.key,
                                    color: Colors.deepPurple,
                                  )),
                              obscureText: true,
                              autofillHints: const [AutofillHints.password],
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) {
                                if (!_loading) _login(); // ← call login
                              },
                            ),
                          ],
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(_error!,
                            style: const TextStyle(color: Colors.red)),
                      ],
                      const SizedBox(height: 16),
                      Card(
                        color: Colors.white,
                        elevation: 4,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              side: const BorderSide(
                                color: Colors.grey,
                                width: 1,
                              )),
                          onPressed: _loading ? null : _login,
                          child: _loading
                              ? const CircularProgressIndicator()
                              : const Text('Login'),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
