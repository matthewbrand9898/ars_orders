import 'dart:convert';

import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:http_parser/http_parser.dart';
import 'package:ars_orders/services/api.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:js/js_util.dart' as js_util;
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart' as printpackage;
import 'package:intl/intl.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:signature/signature.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web/web.dart' as web;
import '../models/order.dart';
import '../models/order_update.dart';
import '../services/socket_service.dart';
import 'dart:js_interop';

extension StringCasingExtension on String {
  String toTitleCase() {
    return split(' ').map((word) {
      if (word.isEmpty) return word;
      final lower = word.toLowerCase();
      return lower[0].toUpperCase() + lower.substring(1);
    }).join(' ');
  }
}

Future<Uint8List?> _exportCroppedSignatureAsPng(
  SignatureController controller, {
  double scale = 3.0,
  double padding = 10.0,
}) async {
  final points = controller.points.map((p) => p.offset).toList();

  if (points.isEmpty) return null;

  // 1. Find bounding box of all drawn points
  final left = points.map((p) => p.dx).reduce((a, b) => a < b ? a : b);
  final right = points.map((p) => p.dx).reduce((a, b) => a > b ? a : b);
  final top = points.map((p) => p.dy).reduce((a, b) => a < b ? a : b);
  final bottom = points.map((p) => p.dy).reduce((a, b) => a > b ? a : b);

  final croppedWidth = right - left;
  final croppedHeight = bottom - top;

  final canvasSize = Size(
    croppedWidth + padding * 2,
    croppedHeight + padding * 2,
  );

  // 2. Set up canvas
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale, scale);

  // 3. Draw white background
  final bgPaint = Paint()..color = const ui.Color(0xFFFFFFFF);
  canvas.drawRect(Offset.zero & canvasSize, bgPaint);

  // 4. Draw all strokes translated into the cropped box
  final linePaint = Paint()
    ..color = controller.penColor
    ..strokeWidth = controller.penStrokeWidth
    ..strokeCap = StrokeCap.round;

  for (int i = 0; i < controller.points.length - 1; i++) {
    final p1 = controller.points[i];
    final p2 = controller.points[i + 1];
    final start = p1.offset - Offset(left, top) + Offset(padding, padding);
    final end = p2.offset - Offset(left, top) + Offset(padding, padding);
    canvas.drawLine(start, end, linePaint);
  }

  // 5. Export image
  final picture = recorder.endRecording();
  final img = await picture.toImage(
    (canvasSize.width * scale).toInt(),
    (canvasSize.height * scale).toInt(),
  );
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return byteData?.buffer.asUint8List();
}

class OrderDetailPage extends StatefulWidget {
  final Order order;
  const OrderDetailPage({super.key, required this.order});

  @override
  State<OrderDetailPage> createState() => _OrderDetailPageState();
}

class _OrderDetailPageState extends State<OrderDetailPage> {
  late Order _order;

  bool _isEditingDetails = false;
  late String _tempName;
  late String _tempJobId;
  late String _tempDateOrdered;
  late String _tempEta;
  late String _tempAddress;
  late String _tempPhoneNumber;
  late String _tempEmail;

  late String _tempStatus;
  late String _currentStatus;

  bool _isDeleting = false;
  bool _isEditingImages = false;
  bool _editingDocs = false;
  bool _isEditingEvidence = false;
  bool _showSignaturePad = false;
  bool _isUploadingImages = false;
  bool _isUploadingEvidence = false;
  bool _isUploadingDocuments = false;
  List<OrderDocument> _docs = [];
  List<OrderUpdate> _updates = [];
  List<String> _evidenceUrls = [];
  List<String> _imageUrls = [];
  List<String> _signatureUrls = [];
  late String _signatureName;
  late DateTime _signatureDate;

  late final void Function(dynamic) _detailUpdateHandler;

  final TextEditingController _customerNameController = TextEditingController();
  final TextEditingController _jobIdController = TextEditingController();
  final TextEditingController _dateOrderedController = TextEditingController();
  final TextEditingController _etaController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _newUpdateController = TextEditingController();
  final TextEditingController _sigNameController = TextEditingController();
  final SignatureController _signatureController = SignatureController(
    strokeCap: StrokeCap.round,
    strokeJoin: StrokeJoin.round,
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );
  late PageController _pageController = PageController();
  late PhotoViewController _photoViewController = PhotoViewController();

  late PageController _evidencePageController = PageController();
  late PhotoViewController _evidencePhotoViewController = PhotoViewController();

  String? _username;

  @override
  void initState() {
    super.initState();
    _order = widget.order;
    _resetTemps();
    _tempStatus = _order.status;
    _currentStatus = _order.status;

    _customerNameController.text = _order.customerName;
    _jobIdController.text = _order.jobId;
    _dateOrderedController.text = _order.dateOrdered;
    _etaController.text = _order.eta;
    _addressController.text = _order.address!;
    _phoneController.text = _order.phoneNumber;
    _emailController.text = _order.emailAddress;

    _pageController = PageController();
    _photoViewController = PhotoViewController();
    _evidencePageController = PageController();
    _evidencePhotoViewController = PhotoViewController();
    _loadUpdates();
    _loadImages();
    _loadEvidence();
    _loadUsernameFromToken();
    _loadSignature();
    _loadDocuments();
    final socket = SocketService().socket;

    socket.on('documentsUpdated', (data) {
      final incomingId = data['orderId'] is String
          ? int.tryParse(data['orderId'])
          : data['orderId'] as int;
      if (incomingId == _order.id) {
        _loadDocuments();
      }
    });

    _detailUpdateHandler = (data) {
      if (data == null || data['orderId'] == null) return;

      final incomingId = data['orderId'] is String
          ? int.tryParse(data['orderId'])
          : data['orderId'] as int;
      if (incomingId == _order.id) {
        _loadOrder();
      }
    };
    socket.on('ordersUpdated', _detailUpdateHandler);
    socket.on('signatureUpdated', (data) {
      final incomingId = data['orderId'] is String
          ? int.tryParse(data['orderId'])
          : data['orderId'];
      if (incomingId == _order.id) {
        _loadSignature();
      }
    });
    socket.on('updatesUpdated', (data) {
      final incomingId = data['orderId'] is String
          ? int.tryParse(data['orderId']) // parse the String → int
          : data['orderId'] as int;
      if (incomingId != null && _order.id == incomingId) {
        _loadUpdates();
      }
    });

    socket.on('evidenceUpdated', (data) {
      final incomingId = data['orderId'] is String
          ? int.tryParse(data['orderId']) // parse the String → int
          : data['orderId'] as int;
      if (incomingId != null && _order.id == incomingId) {
        _loadEvidence();
      }
    });
    socket.on('imagesUpdated', (data) {
      final incomingId = data['orderId'] is String
          ? int.tryParse(data['orderId'])
          : data['orderId'] as int;
      if (incomingId == _order.id) {
        _loadImages();
      }
    });

    socket.on('orderDeleted', _handleOrderDeleted);
  }

  void _handleOrderDeleted(dynamic data) {
    if (!mounted) return;

    if (_isDeleting) return;

    final incomingId = data['orderId'] is String
        ? int.tryParse(data['orderId'])
        : data['orderId'] as int;

    final route = ModalRoute.of(context);
    // Only show dialog if we're still on this detail page
    if (mounted &&
        route != null &&
        route.isCurrent &&
        incomingId == _order.id) {
      showDialog(
        context: context,
        barrierDismissible: false, // force the user to tap OK
        builder: (dialogContext) => AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('Order Deleted'),
          content: const Text('This order was deleted by another user.'),
          actions: [
            TextButton(
              onPressed: () {
                if (mounted) {
                  Navigator.of(dialogContext).pop(); // dismiss the dialog
                }

                if (mounted) {
                  Navigator.of(context).pop(); // go back to list
                }
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  void dispose() {
    _customerNameController.dispose();
    _dateOrderedController.dispose();
    _etaController.dispose();
    _jobIdController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _emailController.dispose();

    _pageController.dispose();
    _photoViewController.dispose();
    _evidencePageController.dispose();
    _evidencePhotoViewController.dispose();
    _signatureController.dispose();
    _sigNameController.dispose();
    final socket = SocketService().socket;
    socket.off('updatesUpdated');
    socket.off('signatureUpdated');
    socket.off('ordersUpdated', _detailUpdateHandler);
    socket.off('evidenceUpdated');
    socket.off('imagesUpdated');
    socket.off('documentsUpdated');
    socket.off('orderDeleted', _handleOrderDeleted);

    super.dispose();
  }

  void _resetTemps() {
    final o = _order;
    _tempName = o.customerName;
    _tempJobId = o.jobId;
    _tempDateOrdered = o.dateOrdered;
    _tempEta = o.eta;
    _tempAddress = o.address ?? '';
    // _tempStatus = o.status;
    _tempPhoneNumber = o.phoneNumber;
    _tempEmail = o.emailAddress;
  }

  final _dateMaskFormatter = MaskTextInputFormatter(
    mask: '##/##/####',
    filter: {'#': RegExp(r'\d')},
  );

  final _etaMaskFormatter = MaskTextInputFormatter(
    mask: '##/##/#### ##:##',
    filter: {'#': RegExp(r'\d')},
  );

  Future<void> _loadOrder() async {
    final uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}');

    // grab token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');

    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });
    if (resp.statusCode == 200) {
      if (!mounted) return;
      setState(() {
        _order = Order.fromJson(jsonDecode(resp.body));
        _resetTemps();
        _customerNameController.text = _order.customerName;
        _jobIdController.text = _order.jobId;
        _dateOrderedController.text = _order.dateOrdered;
        _etaController.text = _order.eta;
        _addressController.text = _order.address ?? '';
        _phoneController.text = _order.phoneNumber;
        _emailController.text = _order.emailAddress;
        _currentStatus = _order.status;
        _tempStatus = _order.status;
      });
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (pickedDate != null) {
      if (!mounted) return;
      setState(() {
        _dateOrderedController.text =
            DateFormat('dd/MM/yyyy').format(pickedDate);
        _tempDateOrdered = DateFormat('dd/MM/yyyy').format(pickedDate);
      });
    }
  }

  Future<void> _selectEta() async {
    // 1) pick the date
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) {
      return; // bail if user cancelled or widget gone
    }

    // 2) pick the time
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null || !mounted) return; // same guard

    // 3) assemble and write out
    final dt = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );

    // 4) update your controller inside setState
    setState(() {
      if (!mounted) return;
      _etaController.text = DateFormat('dd/MM/yyyy HH:mm').format(dt);
      _tempEta = DateFormat('dd/MM/yyyy HH:mm').format(dt);
    });
  }

  Future<void> _editDetails() async {
    final uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}');
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt') ?? '';

    final body = {
      'customerName': _tempName,
      'jobId': _tempJobId,
      'dateOrdered': _tempDateOrdered,
      'eta': _tempEta,
      'address': _tempAddress,
      'status': _tempStatus,
      'phoneNumber': _tempPhoneNumber,
      'emailAddress': _tempEmail,
    };

    final resp = await http.patch(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (resp.statusCode == 200) {
      setState(() {
        _order = Order.fromJson(jsonDecode(resp.body));

        _isEditingDetails = false;
      });
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save changes (${resp.statusCode})')),
      );
    }
  }

  Future<void> _printOrder() async {
    final pdf = pw.Document();

    // —— 1) DETAILS PAGE ——
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (_) {
          // helper for table rows
          pw.TableRow row(String label, String value) {
            return pw.TableRow(
              decoration: const pw.BoxDecoration(
                color: PdfColors.white,
              ),
              children: [
                pw.Padding(
                  padding:
                      const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                  child: pw.Text(label,
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ),
                pw.Padding(
                  padding:
                      const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                  child: pw.Text(value),
                ),
              ],
            );
          }

          final addr = (_order.address != null &&
                  _order.address!.toUpperCase().contains('CUSTOMER PICKUP'))
              ? 'Customer Pickup'
              : (_order.address?.isNotEmpty == true ? _order.address! : 'N/A');

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // Header bar
              pw.Center(
                child: pw.Container(
                    width: PdfPageFormat.a4.width,
                    padding: const pw.EdgeInsets.all(12),
                    color: PdfColors.deepPurple,
                    child: pw.Text(
                      textAlign: pw.TextAlign.center,
                      'Order #${_order.jobId}',
                      style: pw.TextStyle(
                        color: PdfColors.white,
                        fontSize: 20,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    )),
              ),
              pw.SizedBox(height: 16),

              // Data table
              pw.Table(
                border: pw.TableBorder.all(
                  color: PdfColors.deepPurple,
                  width: 0.5,
                ),
                columnWidths: const {
                  0: pw.FlexColumnWidth(2),
                  1: pw.FlexColumnWidth(3),
                },
                children: [
                  row('Customer Name', _order.customerName),
                  row('Date Ordered', _order.dateOrdered),
                  row('Order Number', _order.jobId),
                  row(
                      'Email Address',
                      _order.emailAddress.isNotEmpty
                          ? _order.emailAddress
                          : 'N/A'),
                  row(
                      'Phone Number',
                      _order.phoneNumber.isNotEmpty
                          ? _order.phoneNumber
                          : 'N/A'),
                  row('Delivery Address', addr),
                ],
              ),
            ],
          );
        },
      ),
    );

    // —— 2) IMAGE PAGES ——
    for (final url in _imageUrls) {
      final pw.ImageProvider img = await printpackage.networkImage(url);

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Center(
              child: pw.Container(
            width: PdfPageFormat.a4.width,
            height: PdfPageFormat.a4.height,
            child: pw.Image(img, fit: pw.BoxFit.fill),
          )),
        ),
      );
    }

    // 3) iOS Safari fallback
    if (kIsWeb) {
      final ua = js_util.getProperty(
        js_util.getProperty(js_util.globalThis, 'navigator'),
        'userAgent',
      ) as String;
      final isIOSSafari = ua.contains('Safari') &&
          !ua.contains('Chrome') &&
          ua.contains('Mobile');

      if (isIOSSafari) {
        // Open the PDF in a new tab so Safari’s native viewer can print multi-page
        final Uint8List bytes = await pdf.save();
        final blob = js_util.callConstructor(
          js_util.getProperty(js_util.globalThis, 'Blob'),
          [
            [bytes],
            js_util.jsify({'type': 'application/pdf'}),
          ],
        );
        final url = js_util.callMethod(
          js_util.getProperty(js_util.globalThis, 'URL'),
          'createObjectURL',
          [blob],
        ) as String;
        js_util.callMethod(js_util.globalThis, 'open', [url, '_blank']);
        return;
      }
    }

    // —— 4) PRINT DIALOG ——
    await printpackage.Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  Future<void> _loadImages() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt') ?? '';
    final uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}');
    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      // 1) Grab the raw JSON list (might be [null])
      final raw = (data['images'] as List<dynamic>?) ?? [];

      // 2) Keep only non-null Strings
      final names = raw.whereType<String>().toList();

      // 3) Turn each filename into a full URL
      setState(() {
        _imageUrls = names
            .map((fn) => '${getBaseUrl()}/uploads/${p.basename(fn)}')
            .toList();
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load images')),
        );
      }
    }
  }

  Future<void> _loadSignature() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt') ?? '';
    final uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}/signature');
    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });

    if (resp.statusCode == 200) {
      // decode as an object, not a list
      final Map<String, dynamic> data =
          jsonDecode(resp.body) as Map<String, dynamic>;
      setState(() {
        _signatureName = data['name'] as String;
        _signatureDate = DateTime.parse(data['date'] as String).toLocal();
        _signatureUrls = (data['images'] as List<dynamic>)
            .map((p) => '${getBaseUrl()}$p')
            .cast<String>()
            .toList();
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to load signature (${resp.statusCode})')),
        );
      }
    }
  }

  Future<void> _loadEvidence() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');
    final uri =
        Uri.parse('${getBaseUrl()}/orders/${_order.id}/delivery-evidence');
    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });
    if (resp.statusCode == 200) {
      setState(() {
        _evidenceUrls = List<String>.from(jsonDecode(resp.body));
      });
    }
  }

  Future<void> _loadDocuments() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt') ?? '';
    final uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}/documents');

    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });
    if (resp.statusCode != 200) return;

    final data = jsonDecode(resp.body) as List<dynamic>;
    setState(() {
      _docs = data
          .whereType<Map<String, dynamic>>()
          .map((m) => OrderDocument.fromJson(m))
          .toList();
    });
  }

  Future<void> _deleteDocument(String filename) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt') ?? '';
    final uri =
        Uri.parse('${getBaseUrl()}/orders/${_order.id}/documents/$filename');

    final resp = await http.delete(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (resp.statusCode == 200) {
      // remove locally for instant feedback
      setState(() {
        _editingDocs = false;
      });
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed (${resp.statusCode})')),
      );
    }
  }

  Future<void> _pickAndUploadDocuments() async {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = '.pdf'
      ..multiple = true;
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.length <= 0) return;
    // *** enforce a max of 5 ***
    if (files.length > 5) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('You can only select up to 5 documents')),
        );
      }
      return;
    }

    // 2) invoke your shared processor
    setState(() => _isUploadingDocuments = true);
    await _processAndUpload(files, 'Documents');
    // await _loadDocuments(); // refresh the list
    setState(() => _isUploadingDocuments = false);
  }

  Future<void> _pickAndUploadOrderImages() async {
    if (!mounted) return;

    // 1) Show a dialog, but only for the gallery choice
    final galleryChoice = await showDialog<bool>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: Colors.white,
        title: const Text('Upload Images'),
        children: [
          // CAMERA OPTION: we handle input.click right here
          SimpleDialogOption(
            onPressed: () async {
              Navigator.pop(ctx, false); // signal “camera”
              // --- start of synchronous user‐gesture block ---
              final input = web.HTMLInputElement()..type = 'file';
              // on iOS, force via accept+cature; on others, use capture attr
              final ua = web.window.navigator.userAgent.toLowerCase();
              final isiOS = ua.contains('iphone') ||
                  ua.contains('ipad') ||
                  ua.contains('ipod');

              if (isiOS) {
                input
                  ..setAttribute('accept', 'image/*;capture=camera')
                  ..accept = 'image/*;capture=camera'
                  ..setAttribute('capture', 'camera')
                  ..multiple = false;
              } else {
                input
                  ..capture = 'environment'
                  ..multiple = false;
              }

              input.style.display = 'none';
              web.document.body!.append(input);
              input.click();
              final files = await input.onChange.first.then((_) => input.files);
              input.remove();

              if (files!.length > 10) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('You can only select up to 10 Images')),
                  );
                }
                return;
              }

              if (files.length > 0) {
                await _processAndUpload(files, 'Images');
              }
              // --- end of gesture block ---
            },
            child: const Text('Take a Photo'),
          ),

          // GALLERY OPTION: pop and handle below
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, true), // signal “gallery”
            child: const Text('Choose from Gallery'),
          ),
        ],
      ),
    );

    if (galleryChoice == null) return;

    if (galleryChoice) {
      // 2) User chose gallery, do the normal picker with multiple=true
      final input = web.HTMLInputElement()
        ..type = 'file'
        ..accept = 'image/*,image/heic,.heic,.heif'
        ..multiple = true;

      input.style.display = 'none';
      web.document.body!.append(input);
      input.click();
      final files = await input.onChange.first.then((_) => input.files);
      input.remove();

      if (files!.length > 10) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('You can only select up to 10 Images')),
          );
        }
        return;
      }

      if (files.length > 0) {
        await _processAndUpload(files, 'Images');
      }
    }
  }

  Future<void> _uploadSignatureToServer(Uint8List data) async {
    final uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}/signature');
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt') ?? '';
    final name = _sigNameController.text.trim();
    if (name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a name')),
        );
      }
      return;
    }

    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['name'] = name // ← send the name
      ..files.add(http.MultipartFile.fromBytes(
        'signature',
        data,
        filename: 'signature-${DateTime.now().millisecondsSinceEpoch}.png',
        contentType: MediaType('image', 'png'),
      ));

    try {
      final resp = await request.send();
      if (resp.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Signature uploaded')),
          );
        }
      } else {
        throw Exception('Failed to upload: ${resp.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _pickAndUploadEvidence() async {
    if (!mounted) return;

    // 1) Show a dialog, but only for the gallery choice
    final galleryChoice = await showDialog<bool>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: Colors.white,
        title: const Center(child: Text('Upload Evidence')),
        children: [
          // CAMERA OPTION: we handle input.click right here
          SimpleDialogOption(
            onPressed: () async {
              Navigator.pop(ctx, false); // signal “camera”
              // --- start of synchronous user‐gesture block ---
              final input = web.HTMLInputElement()..type = 'file';
              // on iOS, force via accept+cature; on others, use capture attr
              final ua = web.window.navigator.userAgent.toLowerCase();
              final isiOS = ua.contains('iphone') ||
                  ua.contains('ipad') ||
                  ua.contains('ipod');

              if (isiOS) {
                input
                  ..setAttribute('accept', 'image/*;capture=camera')
                  ..accept = 'image/*;capture=camera'
                  ..setAttribute('capture', 'camera')
                  ..multiple = false;
              } else {
                input
                  ..capture = 'environment'
                  ..multiple = false;
              }

              input.style.display = 'none';
              web.document.body!.append(input);
              input.click();
              final files = await input.onChange.first.then((_) => input.files);
              input.remove();

              if (files!.length > 10) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('You can only select up to 10 Images')),
                  );
                }
                return;
              }
              if (files.length > 0) {
                await _processAndUpload(files, 'Evidence');
              }
              // --- end of gesture block ---
            },
            child: const Text('Take a Photo'),
          ),

          // GALLERY OPTION: pop and handle below
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, true), // signal “gallery”
            child: const Text('Choose from Gallery'),
          ),
        ],
      ),
    );

    if (galleryChoice == null) return;

    if (galleryChoice) {
      // 2) User chose gallery, do the normal picker with multiple=true
      final input = web.HTMLInputElement()
        ..type = 'file'
        ..accept = 'image/*,image/heic,.heic,.heif'
        ..multiple = true;

      input.style.display = 'none';
      web.document.body!.append(input);
      input.click();
      final files = await input.onChange.first.then((_) => input.files);
      input.remove();
      if (files!.length > 10) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('You can only select up to 10 Images')),
          );
        }
        return;
      }
      if (files.length > 0) {
        await _processAndUpload(files, 'Evidence');
      }
    }
  }

// Pull your validation + upload logic into one place
  Future<void> _processAndUpload(web.FileList files, String type) async {
    // 1) Determine allowed extensions and max count per type
    final allowedExts = (type == 'Documents')
        ? ['pdf']
        : ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg', 'heic', 'heif'];
    final maxCount = (type == 'Documents') ? 5 : 10;

    // 2) Filter out up to maxCount good files
    final good = <web.File>[];
    for (var i = 0; i < files.length && good.length < maxCount; i++) {
      final f = files.item(i)!;
      final ext = f.name.toLowerCase().split('.').last;
      if (allowedExts.contains(ext)) good.add(f);
      if (!allowedExts.contains(ext)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please upload correct file types.')),
          );
        }
        return;
      }
    }
    if (good.isEmpty) return;

    // 3) Build the correct URI for this type
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt') ?? '';
    late final Uri uri;
    if (type == 'Images') {
      uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}/images');
    } else if (type == 'Evidence') {
      uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}/delivery-evidence');
    } else {
      // Documents
      uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}/documents');
    }

    // 4) Prepare the multipart request
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token';

    // 5) Pick the right field name
    final field = (type == 'Images')
        ? 'images'
        : (type == 'Evidence')
            ? 'evidence'
            : 'documents';

    // 6) Attach each file
    for (final f in good) {
      final jsBuf = await f.arrayBuffer().toDart as ByteBuffer;
      final bytes = Uint8List.view(jsBuf);
      req.files.add(
        http.MultipartFile.fromBytes(
          field,
          bytes,
          filename: f.name,
          // for docs, explicitly set PDF MIME
          contentType:
              (type == 'Documents') ? MediaType('application', 'pdf') : null,
        ),
      );
    }

    // 7) Flip on the correct “uploading” spinner
    setState(() {
      if (type == 'Images') {
        _isUploadingImages = true;
      } else if (type == 'Evidence') {
        _isUploadingEvidence = true;
      } else {
        _isUploadingDocuments = true;
      }
    });

    // 8) Send, reload, and toast
    try {
      final resp = await req.send();
      if (resp.statusCode == 200) {
        if (type == 'Images') {
          //   await _loadImages();
        } else if (type == 'Evidence') {
          // await _loadEvidence();
        } else {
          //   await _loadDocuments();
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$type uploaded')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Upload failed')),
          );
        }
      }
    } finally {
      // 9) Turn off the spinner
      setState(() {
        if (type == 'Images') {
          _isUploadingImages = false;
        } else if (type == 'Evidence') {
          _isUploadingEvidence = false;
        } else {
          _isUploadingDocuments = false;
        }
      });
    }
  }

  Future<void> _loadUsernameFromToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');
    if (token != null) {
      final payload = decodeJwtPayload(token);
      setState(() {
        _username = payload['username'] as String?;
      });
    }
  }

  Map<String, dynamic> decodeJwtPayload(String token) {
    final parts = token.split('.');
    if (parts.length != 3) throw Exception('Invalid JWT');
    final payload = parts[1];
    final normalized = base64Url.normalize(payload);
    final decoded = utf8.decode(base64Url.decode(normalized));
    return json.decode(decoded) as Map<String, dynamic>;
  }

  Future<void> _loadUpdates() async {
    final uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}/updates');

    // grab token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');

    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });
    if (resp.statusCode == 200) {
      final List data = jsonDecode(resp.body);
      setState(() {
        _updates = data.map((j) => OrderUpdate.fromJson(j)).toList();
      });
    }
  }

  Future<void> _editUpdate(OrderUpdate u, String newText) async {
    final uri =
        Uri.parse('${getBaseUrl()}/orders/${_order.id}/updates/${u.id}');

    // grab token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');

    final resp = await http.patch(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'text': newText}),
    );
    if (resp.statusCode == 200) {
      final updated = OrderUpdate.fromJson(jsonDecode(resp.body));
      setState(() {
        final idx = _updates.indexWhere((e) => e.id == updated.id);
        if (idx != -1) _updates[idx] = updated;
      });
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Failed to edit update')));
    }
  }

  Future<void> _deleteUpdate(OrderUpdate u) async {
    final uri =
        Uri.parse('${getBaseUrl()}/orders/${_order.id}/updates/${u.id}');

    // grab token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');

    final resp = await http.delete(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });
    if (resp.statusCode == 200) {
      setState(() {
        _updates.removeWhere((e) => e.id == u.id);
      });
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete update')));
    }
  }

  Future<void> _addUpdate() async {
    final text = _newUpdateController.text.trim();
    if (text.isEmpty) return;
    final uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}/updates');

    // grab token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');

    final resp = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'text': text}),
    );
    if (resp.statusCode == 201) {
      setState(() {
        _updates.insert(0, OrderUpdate.fromJson(jsonDecode(resp.body)));
        _newUpdateController.clear();
      });
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to add update')),
      );
    }
  }

  Future<void> _confirmDelete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Delete this order?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          OutlinedButton(
              style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  side: const BorderSide(
                    color: Colors.grey,
                    width: 1,
                  )),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          OutlinedButton(
              style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  side: const BorderSide(
                    color: Colors.grey,
                    width: 1,
                  )),
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                'Delete',
                style: TextStyle(color: Colors.red),
              )),
        ],
      ),
    );
    if (yes == true) await _deleteOrder();
  }

  Future<void> _deleteOrder() async {
    setState(() => _isDeleting = true);

    final uri = Uri.parse('${getBaseUrl()}/orders/${_order.id}');

    // grab token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');

    final resp = await http.delete(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });
    if (resp.statusCode == 200) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Order deleted')),
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } else if (mounted) {
      setState(() => _isDeleting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete order')),
      );
    }
  }

  Future<void> _confirmDeleteImage(String filename) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Delete this image?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) await _deleteImage(filename);
  }

  Future<void> _confirmDeleteDocument(String filename) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Delete this Document?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) await _deleteDocument(filename);
  }

  Future<void> _openMap(String address) async {
    final encoded = Uri.encodeComponent(address);
    final uri =
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$encoded');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the map')),
      );
    }
  }

  Future<void> _deleteImage(String filename) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt') ?? '';
    final uri =
        Uri.parse('${getBaseUrl()}/orders/${_order.id}/images/$filename');
    final resp = await http.delete(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });

    if (resp.statusCode == 200) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Image deleted')));
        setState(() {
          _isEditingImages = false;
        });
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to delete image')));
      }
    }
  }

  Future<void> _confirmDeleteEvidence(String filename) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Delete this evidence?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) await _deleteEvidence(filename);
  }

  Future<void> _deleteEvidence(String filename) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt') ?? '';
    final uri = Uri.parse(
        '${getBaseUrl()}/orders/${_order.id}/delivery-evidence/$filename');
    final resp = await http.delete(uri, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });
    if (resp.statusCode == 200) {
      // await _loadEvidence(); // refresh evidence list
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Evidence deleted')));
        setState(() {
          _isEditingEvidence = false;
        });
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to delete evidence')));
      }
    }
  }

  Future<void> _callPhone(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    if (!await launchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not launch phone dialer')),
      );
    }
  }

  void _openFullscreenGalleryImages(int startIndex,
      PageController pageController, PhotoViewController photoViewController) {
    int currentIndex = startIndex;
    pageController.initialPage = startIndex;
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) {
          final screenWidth = MediaQuery.of(context).size.width;
          final isWideScreen = screenWidth > 500;

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            child: Stack(
              children: [
                PhotoViewGallery.builder(
                  pageController: pageController,
                  onPageChanged: (index) {
                    setState(() {
                      currentIndex = index;
                    });
                  },
                  itemCount: _imageUrls.length,
                  builder: (context, idx) => PhotoViewGalleryPageOptions(
                    controller: photoViewController,
                    imageProvider: CachedNetworkImageProvider(
                      _imageUrls[idx],
                    ),
                    initialScale: PhotoViewComputedScale.contained,
                    minScale: PhotoViewComputedScale.contained * 0.8,
                    maxScale: PhotoViewComputedScale.covered * 2,
                  ),
                  backgroundDecoration: const BoxDecoration(
                    color: Colors.transparent,
                  ),
                  scrollPhysics: const NeverScrollableScrollPhysics(),
                ),

                // Close Button
                Positioned(
                  top: 20,
                  right: 20,
                  child: FloatingActionButton(
                    shape: const CircleBorder(),
                    elevation: 0,
                    mini: true,
                    backgroundColor: Colors.grey.withValues(alpha: 0.5),
                    onPressed: () {
                      photoViewController.reset();
                      Navigator.of(context).pop();
                    },
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                    ),
                  ),
                ),

                // Zoom In
                if (isWideScreen)
                  Positioned(
                    top: 20,
                    right: 150,
                    child: FloatingActionButton(
                      shape: const CircleBorder(),
                      elevation: 0,
                      mini: true,
                      backgroundColor: Colors.grey.withValues(alpha: 0.5),
                      onPressed: () {
                        setState(() {
                          final newScale =
                              (photoViewController.scale ?? 1.0) * 1.2;
                          photoViewController.scale = newScale.clamp(0.5, 5.0);
                        });
                      },
                      child: const Icon(
                        Icons.zoom_in,
                        color: Colors.white,
                      ),
                    ),
                  ),

                // Zoom Out
                if (isWideScreen)
                  Positioned(
                    top: 20,
                    right: 90,
                    child: FloatingActionButton(
                      shape: const CircleBorder(),
                      elevation: 0,
                      mini: true,
                      backgroundColor: Colors.grey.withValues(alpha: 0.5),
                      onPressed: () {
                        setState(() {
                          final newScale =
                              (photoViewController.scale ?? 1.0) / 1.2;
                          photoViewController.scale = newScale.clamp(0.5, 5.0);
                        });
                      },
                      child: const Icon(
                        Icons.zoom_out,
                        color: Colors.white,
                      ),
                    ),
                  ),

                // Previous Image
                if (currentIndex > 0)
                  Positioned(
                    left: 10,
                    top: MediaQuery.of(context).size.height / 2 - 24,
                    child: FloatingActionButton(
                      shape: const CircleBorder(),
                      elevation: 0,
                      mini: false,
                      backgroundColor: Colors.grey.withValues(alpha: 0.5),
                      child: const Icon(Icons.arrow_back_ios_new,
                          size: 30, color: Colors.white),
                      onPressed: () {
                        if (currentIndex > 0) {
                          setState(() => currentIndex = currentIndex - 1);
                          photoViewController.reset();
                          pageController.previousPage(
                            duration: const Duration(milliseconds: 100),
                            curve: Curves.easeIn,
                          );
                        }
                      },
                    ),
                  ),

                // Next Image
                if (currentIndex < _imageUrls.length - 1)
                  Positioned(
                    right: 10,
                    top: MediaQuery.of(context).size.height / 2 - 24,
                    child: FloatingActionButton(
                      shape: const CircleBorder(),
                      elevation: 0,
                      mini: false,
                      backgroundColor: Colors.grey.withValues(alpha: 0.5),
                      child: const Icon(Icons.arrow_forward_ios,
                          size: 30, color: Colors.white),
                      onPressed: () {
                        if (currentIndex < _imageUrls.length - 1) {
                          setState(() => currentIndex = currentIndex + 1);
                          photoViewController.reset();
                          pageController.nextPage(
                            duration: const Duration(milliseconds: 100),
                            curve: Curves.easeIn,
                          );
                        }
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openFullscreenGalleryEvidence(int startIndex,
      PageController pageController, PhotoViewController photoViewController) {
    int currentIndex = startIndex;
    pageController.initialPage = startIndex;
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) {
          final screenWidth = MediaQuery.of(context).size.width;
          final isWideScreen = screenWidth > 500;

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            child: Stack(
              children: [
                PhotoViewGallery.builder(
                  pageController: pageController,
                  onPageChanged: (index) {
                    setState(() {
                      currentIndex = index;
                    });
                  },
                  itemCount: _evidenceUrls.length,
                  builder: (context, idx) => PhotoViewGalleryPageOptions(
                    controller: photoViewController,
                    imageProvider: CachedNetworkImageProvider(
                      '${getBaseUrl()}${_evidenceUrls[idx]}',
                    ),
                    initialScale: PhotoViewComputedScale.contained,
                    minScale: PhotoViewComputedScale.contained * 0.8,
                    maxScale: PhotoViewComputedScale.covered * 2,
                  ),
                  backgroundDecoration: const BoxDecoration(
                    color: Colors.transparent,
                  ),
                  scrollPhysics: const NeverScrollableScrollPhysics(),
                ),

                // Close Button
                Positioned(
                  top: 20,
                  right: 20,
                  child: FloatingActionButton(
                    shape: const CircleBorder(),
                    elevation: 0,
                    mini: true,
                    backgroundColor: Colors.grey.withValues(alpha: 0.5),
                    onPressed: () {
                      photoViewController.reset();
                      Navigator.of(context).pop();
                    },
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                    ),
                  ),
                ),

                // Zoom In
                if (isWideScreen)
                  Positioned(
                    top: 20,
                    right: 150,
                    child: FloatingActionButton(
                      shape: const CircleBorder(),
                      elevation: 0,
                      mini: true,
                      backgroundColor: Colors.grey.withValues(alpha: 0.5),
                      onPressed: () {
                        setState(() {
                          final newScale =
                              (photoViewController.scale ?? 1.0) * 1.2;
                          photoViewController.scale = newScale.clamp(0.5, 5.0);
                        });
                      },
                      child: const Icon(
                        Icons.zoom_in,
                        color: Colors.white,
                      ),
                    ),
                  ),

                // Zoom Out
                if (isWideScreen)
                  Positioned(
                    top: 20,
                    right: 90,
                    child: FloatingActionButton(
                      shape: const CircleBorder(),
                      elevation: 0,
                      mini: true,
                      backgroundColor: Colors.grey.withValues(alpha: 0.5),
                      onPressed: () {
                        setState(() {
                          final newScale =
                              (photoViewController.scale ?? 1.0) / 1.2;
                          photoViewController.scale = newScale.clamp(0.5, 5.0);
                        });
                      },
                      child: const Icon(
                        Icons.zoom_out,
                        color: Colors.white,
                      ),
                    ),
                  ),

                // Previous Image
                if (currentIndex > 0)
                  Positioned(
                    left: 10,
                    top: MediaQuery.of(context).size.height / 2 - 24,
                    child: FloatingActionButton(
                      shape: const CircleBorder(),
                      elevation: 0,
                      mini: false,
                      backgroundColor: Colors.grey.withValues(alpha: 0.5),
                      child: const Icon(Icons.arrow_back_ios_new,
                          size: 30, color: Colors.white),
                      onPressed: () {
                        if (currentIndex > 0) {
                          // Optimistically update
                          setState(() => currentIndex = currentIndex - 1);

                          photoViewController.reset();
                          pageController.previousPage(
                            duration: const Duration(milliseconds: 100),
                            curve: Curves.easeIn,
                          );
                        }
                      },
                    ),
                  ),

                // Next Image
                if (currentIndex < _evidenceUrls.length - 1)
                  Positioned(
                    right: 10,
                    top: MediaQuery.of(context).size.height / 2 - 24,
                    child: FloatingActionButton(
                      shape: const CircleBorder(),
                      elevation: 0,
                      mini: false,
                      backgroundColor: Colors.grey.withValues(alpha: 0.5),
                      child: const Icon(Icons.arrow_forward_ios,
                          size: 30, color: Colors.white),
                      onPressed: () {
                        if (currentIndex < _evidenceUrls.length - 1) {
                          // Optimistically update
                          setState(() => currentIndex = currentIndex + 1);
                          photoViewController.reset();
                          pageController.nextPage(
                            duration: const Duration(milliseconds: 100),
                            curve: Curves.easeIn,
                          );
                        }
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = _order;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  BackButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              FontAwesomeIcons.hashtag,
                              size: 30,
                              color: Colors.deepPurple,
                            ),
                          ),
                          Text(
                            'Order ',
                            style: theme.textTheme.titleLarge!
                                .copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(order.jobId, style: theme.textTheme.titleLarge),
                        ],
                      ),
                    ),
                  ),
                  const Padding(
                    padding:
                        EdgeInsets.only(left: 8, right: 8, top: 8, bottom: 8),
                    child: CircleAvatar(
                      radius: 25,
                      backgroundImage: AssetImage(
                        'images/arslogo.jpg',
                      ),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // ====== TEXT DATA CARD ======
                    Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 8,
                      margin: EdgeInsets.zero,
                      child: Column(
                        children: [
                          ListTile(
                            dense: true,
                            minVerticalPadding: 0,
                            minTileHeight: 0,
                            contentPadding:
                                const EdgeInsets.only(left: 16, top: 8),
                            leading: Icon(FontAwesomeIcons.solidUser,
                                size: 25, color: theme.colorScheme.primary),
                            title: Row(
                              children: [
                                Expanded(
                                  child: _isEditingDetails
                                      ? TextField(
                                          controller: _customerNameController,
                                          decoration: const InputDecoration(
                                              isDense: true),
                                          onChanged: (s) {
                                            setState(() => _tempName = s);
                                          },
                                        )
                                      : Text(
                                          order.customerName.toUpperCase(),
                                          style: theme.textTheme.titleMedium!
                                              .copyWith(
                                                  fontWeight: FontWeight.w600),
                                        ),
                                ),
                                const SizedBox(
                                  width: 8,
                                ),
                                if (order.urgent == 1)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                        right: 16.0, top: 8, bottom: 0),
                                    child: Card(
                                      color: Colors.white,
                                      elevation: 2,
                                      child: Container(
                                          alignment: Alignment.center,
                                          width: 70,
                                          height: 32,
                                          decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border.all(
                                                color: Colors.grey,
                                                width: 1,
                                              )),
                                          child: const Text(
                                            'URGENT',
                                            style: TextStyle(color: Colors.red),
                                          )),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: const Text('Customer Name'),
                          ),
                          const Divider(
                            indent: 15,
                            endIndent: 15,
                          ),
                          ListTile(
                            dense: true,
                            minVerticalPadding: 0,
                            minTileHeight: 0,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 0),
                            leading: _isEditingDetails
                                ? IconButton(
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.all(0),
                                    onPressed: () => _selectDate(context),
                                    icon: const Icon(
                                      FontAwesomeIcons.calendarDay,
                                      color: Colors.deepPurple,
                                      size: 25,
                                    ),
                                  )
                                : const Icon(
                                    FontAwesomeIcons.calendarDay,
                                    color: Colors.deepPurple,
                                    size: 25,
                                  ),
                            title: _isEditingDetails
                                ? TextField(
                                    onChanged: (s) {
                                      setState(() {
                                        _tempDateOrdered = s;
                                      });
                                    },
                                    inputFormatters: [_dateMaskFormatter],
                                    readOnly: false,
                                    controller: _dateOrderedController,
                                    decoration:
                                        const InputDecoration(isDense: true),
                                  )
                                : Text(
                                    order.dateOrdered,
                                    style: theme.textTheme.titleMedium!
                                        .copyWith(fontWeight: FontWeight.w600),
                                  ),
                            subtitle: const Text('Date Ordered'),
                          ),
                          const Divider(
                            indent: 15,
                            endIndent: 15,
                          ),
                          ListTile(
                            dense: true,
                            minVerticalPadding: 0,
                            minTileHeight: 0,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 0),
                            leading: _isEditingDetails
                                ? IconButton(
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.all(0),
                                    onPressed: () => _selectEta(),
                                    icon: const Icon(
                                      FontAwesomeIcons.solidClock,
                                      color: Colors.deepPurple,
                                      size: 25,
                                    ),
                                  )
                                : const Icon(
                                    FontAwesomeIcons.solidClock,
                                    color: Colors.deepPurple,
                                    size: 25,
                                  ),
                            title: _isEditingDetails
                                ? TextField(
                                    onChanged: (s) {
                                      setState(() {
                                        _tempEta = s;
                                      });
                                    },
                                    inputFormatters: [_etaMaskFormatter],
                                    readOnly: false,
                                    controller: _etaController,
                                    decoration:
                                        const InputDecoration(isDense: true),
                                  )
                                : Text(
                                    order.eta,
                                    style: theme.textTheme.titleMedium!
                                        .copyWith(fontWeight: FontWeight.w600),
                                  ),
                            subtitle: const Text('Date Required'),
                          ),
                          const Divider(
                            indent: 15,
                            endIndent: 15,
                          ),
                          ListTile(
                            dense: true,
                            minVerticalPadding: 0,
                            minTileHeight: 0,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 0),
                            leading: Icon(FontAwesomeIcons.hashtag,
                                size: 25, color: theme.colorScheme.primary),
                            title: _isEditingDetails
                                ? TextField(
                                    controller: _jobIdController,
                                    decoration:
                                        const InputDecoration(isDense: true),
                                    onChanged: (s) {
                                      setState(() => _tempJobId = s);
                                    },
                                  )
                                : Text(
                                    order.jobId.toUpperCase(),
                                    style: theme.textTheme.titleMedium!
                                        .copyWith(fontWeight: FontWeight.w600),
                                  ),
                            subtitle: const Text('Order Number'),
                          ),
                          const Divider(
                            indent: 15,
                            endIndent: 15,
                          ),
                          ListTile(
                            dense: true,
                            minVerticalPadding: 0,
                            minTileHeight: 0,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 0),
                            leading: Icon(FontAwesomeIcons.phone,
                                size: 25, color: theme.colorScheme.primary),
                            title: _isEditingDetails
                                ? TextField(
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                    ],
                                    keyboardType: TextInputType.number,
                                    controller: _phoneController,
                                    decoration:
                                        const InputDecoration(isDense: true),
                                    onChanged: (s) {
                                      setState(() => _tempPhoneNumber = s);
                                    },
                                  )
                                : Text(
                                    order.phoneNumber.isNotEmpty
                                        ? order.phoneNumber
                                        : 'None',
                                    style: theme.textTheme.titleMedium!
                                        .copyWith(fontWeight: FontWeight.w600),
                                  ),
                            subtitle: const Text('Phone Number'),
                            onTap: (order.phoneNumber.isNotEmpty)
                                ? () => _callPhone(order.phoneNumber)
                                : null,
                          ),
                          const Divider(
                            indent: 15,
                            endIndent: 15,
                          ),
                          ListTile(
                            dense: true,
                            minVerticalPadding: 0,
                            minTileHeight: 0,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 0),
                            leading: Icon(FontAwesomeIcons.solidEnvelope,
                                size: 25, color: theme.colorScheme.primary),
                            title: _isEditingDetails
                                ? TextField(
                                    keyboardType: TextInputType.emailAddress,
                                    controller: _emailController,
                                    decoration:
                                        const InputDecoration(isDense: true),
                                    onChanged: (s) {
                                      setState(() => _tempEmail = s);
                                    },
                                  )
                                : Text(
                                    order.emailAddress.isNotEmpty
                                        ? order.emailAddress
                                        : 'None',
                                    style: theme.textTheme.titleMedium!
                                        .copyWith(fontWeight: FontWeight.w600),
                                  ),
                            subtitle: const Text('Email Address'),
                            onTap: order.emailAddress.isNotEmpty
                                ? () async {
                                    final messenger =
                                        ScaffoldMessenger.of(context);
                                    final uri = Uri(
                                      scheme: 'mailto',
                                      path: order.emailAddress,
                                    );
                                    if (await canLaunchUrl(uri) &&
                                        order.emailAddress != '') {
                                      await launchUrl(uri);
                                    } else {
                                      messenger.showSnackBar(
                                        const SnackBar(
                                            content: Text(
                                                'Could not open mail app')),
                                      );
                                    }
                                  }
                                : null,
                          ),
                          const Divider(
                            indent: 15,
                            endIndent: 15,
                          ),
                          ListTile(
                            dense: true,
                            minVerticalPadding: 0,
                            minTileHeight: 0,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 0),
                            leading: Icon(FontAwesomeIcons.house,
                                size: 25, color: theme.colorScheme.primary),
                            title: _isEditingDetails
                                ? TextField(
                                    controller: _addressController,
                                    decoration:
                                        const InputDecoration(isDense: true),
                                    onChanged: (s) {
                                      setState(() => _tempAddress = s);
                                    },
                                  )
                                : Text(
                                    (order.address != null &&
                                            order.address!
                                                .toUpperCase()
                                                .contains('CUSTOMER PICKUP'))
                                        ? 'Customer Pickup'
                                        : (order.address?.toUpperCase() ??
                                            'Customer Pickup'),
                                    style: theme.textTheme.titleMedium!
                                        .copyWith(fontWeight: FontWeight.w600),
                                  ),
                            subtitle: const Text('Delivery Address'),
                            onTap: (order.address != null &&
                                    !order.address!
                                        .toUpperCase()
                                        .contains('CUSTOMER PICKUP'))
                                ? () => _openMap(order.address!)
                                : null,
                          ),

                          const Divider(
                            indent: 15,
                            endIndent: 15,
                          ),
                          // —— STATUS ROW ——
                          ListTile(
                            dense: true,
                            minVerticalPadding: 0,
                            minTileHeight: 0,
                            contentPadding:
                                const EdgeInsets.only(left: 16, bottom: 8),
                            leading: Icon(FontAwesomeIcons.circleInfo,
                                size: 25, color: theme.colorScheme.primary),
                            title: _isEditingDetails
                                ? Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(0, 0, 0, 8),
                                    child: DropdownButton<String>(
                                      style: theme.textTheme.titleMedium!
                                          .copyWith(
                                              fontWeight: FontWeight.w600),
                                      value: _tempStatus,
                                      isExpanded: true,
                                      isDense: true,
                                      borderRadius: BorderRadius.circular(10),
                                      padding: const EdgeInsets.all(5),
                                      focusColor: Colors.transparent,
                                      items: [
                                        'Pending',
                                        'Waiting',
                                        'In Progress',
                                        'Awaiting Collection',
                                        'Awaiting Delivery',
                                        'Collected',
                                        'Delivered',
                                        'Cancelled'
                                      ]
                                          .map((s) => DropdownMenuItem(
                                                value: s,
                                                child: Text(s),
                                              ))
                                          .toList(),
                                      onChanged: (s) {
                                        if (s != null) {
                                          setState(() => _tempStatus = s);
                                        }
                                      },
                                    ),
                                  )
                                : Text(
                                    _currentStatus,
                                    style: theme.textTheme.titleMedium!
                                        .copyWith(fontWeight: FontWeight.w600),
                                  ),
                            subtitle: const Text('Status'),
                            trailing: IconButton(
                              focusColor: Colors.transparent,
                              hoverColor: Colors.transparent,
                              highlightColor: Colors.transparent,
                              icon: Icon(
                                _isEditingDetails
                                    ? FontAwesomeIcons.solidCircleXmark
                                    : FontAwesomeIcons.solidPenToSquare,
                                size: 24,
                                color: Colors.deepPurple,
                              ),
                              onPressed: () {
                                setState(() {
                                  if (_isEditingDetails) {
                                    _customerNameController.text =
                                        _order.customerName;
                                    _jobIdController.text = _order.jobId;
                                    _dateOrderedController.text =
                                        _order.dateOrdered;
                                    _etaController.text = _order.eta;
                                    _phoneController.text = _order.phoneNumber;
                                    _emailController.text = _order.emailAddress;
                                    _addressController.text = _order.address!;
                                    _tempStatus = _currentStatus;
                                    _dateMaskFormatter.clear();
                                    _etaMaskFormatter.clear();
                                  }
                                  _isEditingDetails = !_isEditingDetails;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),
                    // —— SAVE BUTTON (only when editing) ——
                    if (_isEditingDetails)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Padding(
                              padding: const EdgeInsets.all(0),
                              child: Card(
                                color: Colors.white,
                                elevation: 2,
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.only(right: 12),
                                    side: const BorderSide(
                                        color: Colors.grey, width: 1),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  onPressed: () {
                                    // — Validate “Date Ordered” (DD/MM/YYYY) —
                                    final dateRegex =
                                        RegExp(r'^\d{2}/\d{2}/\d{4}$');
                                    if (!dateRegex.hasMatch(_tempDateOrdered)) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                            content: Text(
                                                'Date must be in DD/MM/YYYY format')),
                                      );
                                      return;
                                    }
                                    try {
                                      DateFormat('dd/MM/yyyy')
                                          .parseStrict(_tempDateOrdered);
                                    } catch (_) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                            content: Text(
                                                'Invalid date. Please use DD/MM/YYYY')),
                                      );
                                      return;
                                    }

// — Validate “ETA” (DD/MM/YYYY HH:MM) —
                                    final etaRegex = RegExp(
                                        r'^\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}$');
                                    if (!etaRegex.hasMatch(_tempEta)) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                            content: Text(
                                                'ETA must be in DD/MM/YYYY HH:MM format')),
                                      );
                                      return;
                                    }
                                    try {
                                      DateFormat('dd/MM/yyyy HH:mm')
                                          .parseStrict(_tempEta);
                                    } catch (_) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                            content: Text(
                                                'Invalid ETA. Please use DD/MM/YYYY HH:MM')),
                                      );
                                      return;
                                    }

                                    _editDetails();
                                    setState(() {
                                      _currentStatus = _tempStatus;
                                      _isEditingDetails = false;
                                    });
                                  },
                                  child: const Row(
                                    children: [
                                      Padding(
                                        padding: EdgeInsets.all(8.0),
                                        child: Icon(
                                          FontAwesomeIcons.solidFloppyDisk,
                                          size: 25,
                                          color: Colors.deepPurple,
                                        ),
                                      ),
                                      Text(
                                        'Save Changes',
                                        style: TextStyle(color: Colors.black),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_isEditingDetails) const SizedBox(height: 24),
                    Row(
                      children: [
                        Card(
                          color: Colors.white,
                          elevation: 2,
                          child: OutlinedButton.icon(
                            icon: const Icon(FontAwesomeIcons.print,
                                size: 25, color: Colors.deepPurple),
                            label: const Text(
                              'Print Order',
                              style: TextStyle(color: Colors.black),
                            ),
                            onPressed: _printOrder,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.all(16),
                              side: const BorderSide(
                                  color: Colors.grey, width: 1),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      elevation: 4,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(FontAwesomeIcons.solidFilePdf,
                                    color: Colors.deepPurple, size: 30),
                                const SizedBox(width: 8),
                                Text('Documents',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge!
                                        .copyWith(fontWeight: FontWeight.bold)),
                                const Spacer(),
                                IconButton(
                                  icon: Icon(
                                    _editingDocs
                                        ? FontAwesomeIcons.solidCircleXmark
                                        : FontAwesomeIcons.solidPenToSquare,
                                    color: Colors.deepPurple,
                                  ),
                                  onPressed: () => setState(() {
                                    _editingDocs = !_editingDocs;
                                  }),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            for (final doc in _docs)
                              ListTile(
                                leading: const Icon(Icons.picture_as_pdf,
                                    color: Colors.red),
                                title: Text(doc.originalName,
                                    style:
                                        Theme.of(context).textTheme.bodyMedium),
                                trailing: _editingDocs
                                    ? IconButton(
                                        icon: const Icon(FontAwesomeIcons.trash,
                                            color: Colors.red),
                                        onPressed: () {
                                          _confirmDeleteDocument(doc.filename);
                                        },
                                      )
                                    : null,
                                onTap: () {
                                  final url =
                                      '${getBaseUrl()}/uploads/${doc.filename}';
                                  launchUrl(Uri.parse(url),
                                      webOnlyWindowName: '_blank');
                                },
                              ),
                            if (_docs.isEmpty)
                              const Center(
                                  child: Text(
                                'No Documents',
                                style: TextStyle(color: Colors.black54),
                              )),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Card(
                                  color: Colors.white,
                                  elevation: 2,
                                  child: OutlinedButton.icon(
                                    icon: _isUploadingDocuments
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : const Icon(Icons.upload_rounded,
                                            size: 25),
                                    label: _isUploadingDocuments
                                        ? const Text('Uploading...')
                                        : const Text('Upload'),
                                    onPressed: _isUploadingDocuments
                                        ? null
                                        : _pickAndUploadDocuments,
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.only(
                                        top: 16,
                                        bottom: 16,
                                        right: 16,
                                        left: 8,
                                      ),
                                      side: const BorderSide(
                                          color: Colors.grey, width: 1),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    // ====== ORDER IMAGES CARD ======
                    Card(
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 8,
                      margin: const EdgeInsets.symmetric(vertical: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(left: 0, right: 8),
                                  child: Icon(
                                    FontAwesomeIcons.solidImage,
                                    size: 30,
                                    color: Colors.deepPurple,
                                  ),
                                ),
                                Text(
                                  'Images',
                                  style: theme.textTheme.titleLarge!
                                      .copyWith(fontWeight: FontWeight.w600),
                                ),
                                const Spacer(),
                                IconButton(
                                    icon: Icon(
                                      _isEditingImages
                                          ? FontAwesomeIcons.solidCircleXmark
                                          : FontAwesomeIcons.solidPenToSquare,
                                      color: Colors.deepPurple,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _isEditingImages = !_isEditingImages;
                                      });
                                    }),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (_imageUrls.isEmpty)
                              Center(
                                child: Text(
                                  'No images available',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              )
                            else ...[
                              GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: _imageUrls.length < 3
                                      ? _imageUrls.length
                                      : 3,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                ),
                                itemCount: _imageUrls.length,
                                itemBuilder: (context, idx) {
                                  final url = _imageUrls[idx];
                                  // extract filename if you need it for delete:
                                  final fname = url.split('/').last;
                                  return Stack(
                                    children: [
                                      GestureDetector(
                                        onTap: () =>
                                            _openFullscreenGalleryImages(
                                                idx,
                                                _pageController,
                                                _photoViewController),
                                        child: Card(
                                          elevation: 8,
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: Image.network(
                                              url,
                                              fit: BoxFit.cover,
                                              width: double.infinity,
                                              height: double.infinity,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                Icons.image_not_supported,
                                                color: Colors.deepPurple,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (_isEditingImages)
                                        Positioned(
                                          top: 10,
                                          right: 10,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.red
                                                  .withValues(alpha: 0.9),
                                              shape: BoxShape.circle,
                                            ),
                                            child: IconButton(
                                              icon: const Icon(
                                                  FontAwesomeIcons.trash,
                                                  size: 20,
                                                  color: Colors.white),
                                              onPressed: () =>
                                                  _confirmDeleteImage(fname),
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 16),
                            ],
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Card(
                                  color: Colors.white,
                                  elevation: 2,
                                  child: OutlinedButton.icon(
                                    icon: _isUploadingImages
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : const Icon(Icons.upload_rounded,
                                            size: 25),
                                    label: _isUploadingImages
                                        ? const Text('Uploading...')
                                        : const Text('Upload'),
                                    onPressed: _isUploadingImages
                                        ? null
                                        : _pickAndUploadOrderImages,
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.only(
                                        top: 16,
                                        bottom: 16,
                                        right: 16,
                                        left: 8,
                                      ),
                                      side: const BorderSide(
                                          color: Colors.grey, width: 1),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    Card(
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 8,
                      margin: const EdgeInsets.symmetric(vertical: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(left: 0, right: 8),
                                  child: Icon(
                                    FontAwesomeIcons.clockRotateLeft,
                                    size: 30,
                                    color: Colors.deepPurple,
                                  ),
                                ),
                                Text('Updates',
                                    style: theme.textTheme.titleLarge!
                                        .copyWith(fontWeight: FontWeight.w600)),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // List of past updates
                            if (_updates.isEmpty)
                              Text('No updates yet.',
                                  style: TextStyle(color: Colors.grey[600]))
                            else
                              ..._updates.map((u) => Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 4),
                                    child: Card(
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      elevation: 8,
                                      color: Colors.white,
                                      child: Padding(
                                        padding: const EdgeInsets.all(8.0),
                                        child: Row(
                                          children: [
                                            // Timestamp + text
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .all(8.0),
                                                          child: AutoSizeText(
                                                            maxLines: 1,
                                                            minFontSize: 8,
                                                            DateFormat(
                                                                    'dd/MM/yyyy HH:mm')
                                                                .format(u
                                                                    .createdAt),
                                                            style: const TextStyle(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600),
                                                          ),
                                                        ),
                                                      ),
                                                      Card(
                                                        shape:
                                                            RoundedRectangleBorder(
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8)),
                                                        elevation: 2,
                                                        color: Colors.white,
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .all(8.0),
                                                          child: Row(
                                                            children: [
                                                              const Icon(
                                                                FontAwesomeIcons
                                                                    .solidUser,
                                                                size: 15,
                                                                color: Colors
                                                                    .deepPurple,
                                                              ),
                                                              const SizedBox(
                                                                width: 4,
                                                              ),
                                                              Text(u.username
                                                                  .toTitleCase())
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 2),
                                                  const Divider(
                                                    indent: 10,
                                                    endIndent: 10,
                                                    color: Colors.deepPurple,
                                                    thickness: 2,
                                                  ),
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                            8.0),
                                                    child: Text(
                                                      u.text,
                                                    ),
                                                  ),
                                                  if (u.username == _username)
                                                    Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment.end,
                                                      children: [
                                                        IconButton(
                                                          icon: const Icon(
                                                            FontAwesomeIcons
                                                                .solidPenToSquare,
                                                            size: 20,
                                                            color: Colors
                                                                .deepPurple,
                                                          ),
                                                          onPressed: () async {
                                                            final controller =
                                                                TextEditingController(
                                                                    text:
                                                                        u.text);
                                                            final result =
                                                                await showDialog<
                                                                    String>(
                                                              context: context,
                                                              builder: (_) =>
                                                                  AlertDialog(
                                                                backgroundColor:
                                                                    Colors
                                                                        .white,
                                                                title: const Text(
                                                                    'Edit update'),
                                                                content:
                                                                    TextField(
                                                                  controller:
                                                                      controller,
                                                                  decoration:
                                                                      const InputDecoration(
                                                                          hintText:
                                                                              'Update text'),
                                                                ),
                                                                actions: [
                                                                  OutlinedButton(
                                                                    style: OutlinedButton
                                                                        .styleFrom(
                                                                            shape:
                                                                                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                                            side: const BorderSide(
                                                                              color: Colors.grey,
                                                                              width: 1,
                                                                            )),
                                                                    onPressed: () =>
                                                                        Navigator.pop(
                                                                            context,
                                                                            null),
                                                                    child: const Text(
                                                                        'Cancel'),
                                                                  ),
                                                                  OutlinedButton(
                                                                    style: OutlinedButton
                                                                        .styleFrom(
                                                                            shape:
                                                                                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                                            side: const BorderSide(
                                                                              color: Colors.grey,
                                                                              width: 1,
                                                                            )),
                                                                    onPressed: () => Navigator.pop(
                                                                        context,
                                                                        controller
                                                                            .text
                                                                            .trim()),
                                                                    child: const Text(
                                                                        'Save'),
                                                                  ),
                                                                ],
                                                              ),
                                                            );
                                                            if (result !=
                                                                    null &&
                                                                result
                                                                    .isNotEmpty &&
                                                                result !=
                                                                    u.text) {
                                                              await _editUpdate(
                                                                  u, result);
                                                            }
                                                          },
                                                        ),
                                                        IconButton(
                                                          icon: const Icon(
                                                              FontAwesomeIcons
                                                                  .trash,
                                                              size: 20,
                                                              color: Colors
                                                                  .redAccent),
                                                          onPressed: () async {
                                                            final yes =
                                                                await showDialog<
                                                                    bool>(
                                                              context: context,
                                                              builder: (_) =>
                                                                  AlertDialog(
                                                                backgroundColor:
                                                                    Colors
                                                                        .white,
                                                                title: const Text(
                                                                    'Delete this update?'),
                                                                actions: [
                                                                  OutlinedButton(
                                                                      style: OutlinedButton
                                                                          .styleFrom(
                                                                              shape: RoundedRectangleBorder(
                                                                                  borderRadius: BorderRadius.circular(
                                                                                      8)),
                                                                              side:
                                                                                  const BorderSide(
                                                                                color: Colors.grey,
                                                                                width: 1,
                                                                              )),
                                                                      onPressed: () => Navigator.pop(
                                                                          context,
                                                                          false),
                                                                      child: const Text(
                                                                          'Cancel')),
                                                                  OutlinedButton(
                                                                      style: OutlinedButton
                                                                          .styleFrom(
                                                                              shape: RoundedRectangleBorder(
                                                                                  borderRadius: BorderRadius.circular(
                                                                                      8)),
                                                                              side:
                                                                                  const BorderSide(
                                                                                color: Colors.grey,
                                                                                width: 1,
                                                                              )),
                                                                      onPressed: () => Navigator.pop(
                                                                          context,
                                                                          true),
                                                                      child:
                                                                          const Text(
                                                                        'Delete',
                                                                        style: TextStyle(
                                                                            color:
                                                                                Colors.red),
                                                                      )),
                                                                ],
                                                              ),
                                                            );
                                                            if (yes == true) {
                                                              await _deleteUpdate(
                                                                  u);
                                                            }
                                                          },
                                                        ),
                                                      ],
                                                    ),
                                                ],
                                              ),
                                            ),

                                            // Edit & Delete icons
                                          ],
                                        ),
                                      ),
                                    ),
                                  )),

                            const Divider(height: 24),
                            // New update input
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _newUpdateController,
                                    decoration: const InputDecoration(
                                      hintText: 'Add an update…',
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Card(
                                  color: Colors.white,
                                  elevation: 2,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.all(16),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8)),
                                        side: const BorderSide(
                                          color: Colors.grey,
                                          width: 1,
                                        )),
                                    onPressed: _addUpdate,
                                    child: const Row(
                                      children: [
                                        Icon(FontAwesomeIcons.solidCommentDots),
                                        SizedBox(
                                          width: 8,
                                        ),
                                        Text(
                                          'Add',
                                          style: TextStyle(color: Colors.black),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ), // ===== DELIVERY EVIDENCE =====
                    Card(
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      elevation: 8,
                      margin: const EdgeInsets.symmetric(vertical: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(FontAwesomeIcons.solidImage,
                                    size: 30, color: Colors.deepPurple),
                                const SizedBox(width: 8),
                                Text('Evidence',
                                    style: theme.textTheme.titleLarge!
                                        .copyWith(fontWeight: FontWeight.w600)),
                                const Spacer(),
                                IconButton(
                                  icon: Icon(
                                    _isEditingEvidence
                                        ? FontAwesomeIcons.solidCircleXmark
                                        : FontAwesomeIcons.solidPenToSquare,
                                    color: Colors.deepPurple,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _isEditingEvidence = !_isEditingEvidence;
                                    });
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (_evidenceUrls.isEmpty)
                              Center(
                                  child: Text('No evidence uploaded',
                                      style:
                                          TextStyle(color: Colors.grey[600])))
                            else
                              GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: _evidenceUrls.length < 3
                                      ? _evidenceUrls.length
                                      : 3,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                ),
                                itemCount: _evidenceUrls.length,
                                itemBuilder: (ctx, i) {
                                  final fname =
                                      _evidenceUrls[i].split('/').last;
                                  final url =
                                      '${getBaseUrl()}${_evidenceUrls[i]}';
                                  return Stack(
                                    children: [
                                      GestureDetector(
                                        onTap: () =>
                                            _openFullscreenGalleryEvidence(
                                                i,
                                                _evidencePageController,
                                                _evidencePhotoViewController),
                                        child: Card(
                                          elevation: 8,
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8)),
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: Image.network(
                                              url,
                                              fit: BoxFit.cover,
                                              width: double.infinity,
                                              height: double.infinity,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                Icons.image_not_supported,
                                                color: Colors.deepPurple,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (_isEditingEvidence)
                                        Positioned(
                                          top: 10,
                                          right: 10,
                                          child: Container(
                                            decoration: const BoxDecoration(
                                              color: Colors.red,
                                              shape: BoxShape.circle,
                                            ),
                                            child: IconButton(
                                              icon: const Icon(
                                                  FontAwesomeIcons.trash,
                                                  size: 20,
                                                  color: Colors.white),
                                              onPressed: () =>
                                                  _confirmDeleteEvidence(fname),
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 16.0),
                                  child: Card(
                                    color: Colors.white,
                                    elevation: 2,
                                    child: OutlinedButton.icon(
                                      icon: _isUploadingEvidence
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2),
                                            )
                                          : const Padding(
                                              padding: EdgeInsets.symmetric(
                                                  vertical: 8),
                                              child: Icon(Icons.upload_rounded,
                                                  size: 25),
                                            ),
                                      label: _isUploadingEvidence
                                          ? const Text('Uploading...')
                                          : const Text('Upload'),
                                      onPressed: _isUploadingEvidence
                                          ? null
                                          : _pickAndUploadEvidence,
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.only(
                                            left: 8, right: 16),
                                        side: const BorderSide(
                                            color: Colors.grey, width: 1),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8)),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_signatureUrls.isNotEmpty)
                      Card(
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 8,
                        margin: const EdgeInsets.symmetric(vertical: 16),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // signer info
                              ...[
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8.0, vertical: 8.0),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // Left: draw icon + "Signee"
                                      Row(
                                        children: [
                                          const Icon(
                                              FontAwesomeIcons.fileSignature,
                                              size: 30,
                                              color: Colors.deepPurple),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Signature',
                                            style: theme.textTheme.titleLarge!
                                                .copyWith(
                                                    fontWeight:
                                                        FontWeight.w600),
                                          ),
                                        ],
                                      ),

                                      const Spacer(),

                                      // Right: name & date
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            _signatureName.toTitleCase(),
                                            style: theme.textTheme.bodyMedium!
                                                .copyWith(
                                                    fontWeight:
                                                        FontWeight.w600),
                                          ),
                                          Text(
                                            DateFormat('dd/MM/yyyy HH:mm')
                                                .format(_signatureDate),
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],

                              // the signature image(s)
                              for (final url in _signatureUrls)
                                Center(
                                  child: Image.network(
                                    url,
                                    width: 300,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.error),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (!_showSignaturePad)
                      Row(
                        children: [
                          Card(
                            color: Colors.white,
                            elevation: 2,
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                FontAwesomeIcons.fileSignature,
                                size: 25,
                                color: Colors.deepPurple,
                              ),
                              label: const Text(
                                'Add Signature',
                                style: TextStyle(color: Colors.black),
                              ),
                              onPressed: () =>
                                  setState(() => _showSignaturePad = true),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.all(16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                                side: const BorderSide(
                                    color: Colors.grey, width: 1),
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_showSignaturePad)
                      Card(
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 8,
                        margin: const EdgeInsets.symmetric(vertical: 16),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(FontAwesomeIcons.fileSignature,
                                      size: 30, color: Colors.deepPurple),
                                  const SizedBox(width: 8),
                                  Text('Sign',
                                      style: theme.textTheme.titleLarge!
                                          .copyWith(
                                              fontWeight: FontWeight.w600)),
                                ],
                              ),
                              TextFormField(
                                controller: _sigNameController,
                                decoration: const InputDecoration(
                                  labelText: 'Recipient Name',
                                  suffixIcon: Icon(FontAwesomeIcons.solidUser,
                                      color: Colors.deepPurple),
                                ),
                                validator: (v) => (v?.trim().isEmpty ?? true)
                                    ? 'Enter your name'
                                    : null,
                              ),
                              const SizedBox(height: 12),
                              Container(
                                height: 150,
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Signature(
                                  controller: _signatureController,
                                  backgroundColor: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: () {
                                      setState(() {
                                        _sigNameController.text = '';
                                        _signatureController.clear();
                                        _showSignaturePad = false;
                                      });
                                    },
                                    child: const Text(
                                      'Cancel',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        _signatureController.clear(),
                                    child: const Text('Clear'),
                                  ),
                                  const SizedBox(width: 8),
                                  Card(
                                    color: Colors.white,
                                    elevation: 2,
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.only(
                                            left: 8, right: 16),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8)),
                                        side: const BorderSide(
                                            color: Colors.grey, width: 1),
                                      ),
                                      icon: const Icon(
                                        Icons.upload_rounded,
                                        size: 25,
                                        color: Colors.deepPurple,
                                      ),
                                      label: const Text('Upload'),
                                      onPressed: () async {
                                        if (_sigNameController.text.isEmpty) {
                                          if (mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                  content: Text(
                                                      'Enter Recipient Name')),
                                            );
                                          }
                                          return;
                                        }
                                        final pngBytes =
                                            await _exportCroppedSignatureAsPng(
                                                _signatureController);
                                        if (pngBytes != null) {
                                          await _uploadSignatureToServer(
                                              pngBytes);
                                        }
                                        setState(() {
                                          _sigNameController.text = '';
                                          _showSignaturePad = false;
                                          _signatureController.clear();
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Card(
                          color: Colors.white,
                          elevation: 2,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.all(16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                                side: const BorderSide(
                                  color: Colors.grey,
                                  width: 1,
                                )),
                            onPressed: _confirmDelete,
                            child: Row(
                              children: [
                                const Icon(
                                  FontAwesomeIcons.trash,
                                  size: 20,
                                  color: Colors.red,
                                ),
                                const SizedBox(
                                  width: 4,
                                ),
                                Text(
                                  'Delete Order',
                                  style: theme.textTheme.titleMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
