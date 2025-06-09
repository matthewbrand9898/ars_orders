import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:js_interop';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:http_parser/http_parser.dart';
import 'package:js/js.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;
import 'package:http/http.dart' as http;
import '../models/order.dart';
import '../services/api.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';

@JS('window.heic2anyConvert')
external void _heic2anyConvert(JSAny blob, Function callback);

@JS('window.imageCompressCall')
external void _imageCompressCall(
    JSAny file, CompressOptions options, Function callback);

@JS('URL.createObjectURL')
external String _createObjectURL(JSAny blob);

@JS()
@anonymous
class CompressOptions {
  external factory CompressOptions({
    int maxWidthOrHeight,
    double initialQuality,
    bool useWebWorker,
  });
}

class AddOrderPage extends StatefulWidget {
  final Function(Order) onAddOrder;
  const AddOrderPage({super.key, required this.onAddOrder});

  @override
  State<AddOrderPage> createState() => _AddOrderPageState();
}

class _AddOrderPageState extends State<AddOrderPage> {
  final TextEditingController _customerNameController = TextEditingController();
  final TextEditingController _dateOrderedController = TextEditingController();
  final TextEditingController _jobIdController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _phoneNumberController = TextEditingController();
  final TextEditingController _emailAdressController = TextEditingController();
  final TextEditingController _etaController = TextEditingController();

  @override
  void dispose() {
    _customerNameController.dispose();
    _dateOrderedController.dispose();
    _jobIdController.dispose();
    _addressController.dispose();
    _phoneNumberController.dispose();
    _emailAdressController.dispose();
    _etaController.dispose();
    super.dispose();
  }

  List<web.File> _selectedFiles = [];
  List<String> _selectedFileDataUrls = [];

  List<web.File> _selectedDocuments = [];

  bool _isSubmitting = false;

  bool _isUrgent = false;
  bool _isPickup = false;

  final _dateMaskFormatter = MaskTextInputFormatter(
    mask: '##/##/####',
    filter: {'#': RegExp(r'\d')},
  );

  final _etaMaskFormatter = MaskTextInputFormatter(
    mask: '##/##/#### ##:##',
    filter: {'#': RegExp(r'\d')},
  );

  Future<JSAny> _heicConvert(JSAny blob) {
    final completer = Completer<JSAny>();
    _heic2anyConvert(blob, allowInterop((res) {
      completer.complete(res as JSAny);
    }));
    return completer.future;
  }

  Future<JSAny> _compressJS(JSAny file, int maxSize, double quality) {
    final completer = Completer<JSAny>();
    final options = CompressOptions(
      maxWidthOrHeight: maxSize,
      initialQuality: quality,
      useWebWorker: true,
    );
    _imageCompressCall(file, options, allowInterop((res) {
      completer.complete(res as JSAny);
    }));
    return completer.future;
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
      _etaController.text = DateFormat('dd/MM/yyyy HH:mm').format(dt);
    });
  }

  Future<String> _compressImage(web.File file,
      {int maxSize = 200, double quality = 0.7}) async {
    // 1) Convert to JS object
    JSAny jsFile = file;
    final name = file.name.toLowerCase();

    // 2) HEIC/HEIF → JPEG
    if (name.endsWith('.heic') || name.endsWith('.heif')) {
      jsFile = await _heicConvert(jsFile);
    }

    // 3) Compress & resize
    final compressed = await _compressJS(jsFile, maxSize, quality);

    // 4) Create preview URL
    return _createObjectURL(compressed);
  }

  Future<void> _pickDocuments() async {
    final input = web.HTMLInputElement()
      // only change: accept PDFs
      ..type = 'file'
      ..accept = '.pdf'
      ..multiple = true;
    input.click();
    await input.onChange.first;

    final files = input.files;
    if (files == null) return;
    if (files.length > 5) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('You can only select up to 5 documents')),
        );
      }
      return;
    }

    setState(() => _isSubmitting = true);

    // identical looping logic, just using web.File now
    final dartFiles = List<web.File>.generate(
      files.length,
      (i) => files.item(i)!,
    );

    // only change: filter for PDFs
    final bad = dartFiles.where((f) {
      final name = f.name.toLowerCase();
      return f.type != 'application/pdf' && !name.endsWith('.pdf');
    }).toList();
    if (bad.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Only PDF files are allowed')),
        );
      }
      setState(() => _isSubmitting = false);
      return;
    }

    setState(() {
      _selectedDocuments = dartFiles;

      _isSubmitting = false;
    });
  }

  Future<void> _pickImages() async {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = 'image/*,image/heic,.heic,.HEIC'
      ..multiple = true;
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null) return;
    if (files.length > 10) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('You can only select up to 10 images')));
      }
      return;
    }

    setState(() => _isSubmitting = true);
    final dartFiles = List<web.File>.generate(
      files.length,
      (i) => files.item(i)!,
    );

    final bad = dartFiles.where((f) {
      final ext = f.name.toLowerCase();
      return !f.type.startsWith('image/') &&
          !ext.endsWith('.heic') &&
          !ext.endsWith('.heif');
    }).toList();
    if (bad.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Only image files are allowed')));
      }
      setState(() => _isSubmitting = false);
      return;
    }

    final previews = <String>[];
    for (final f in dartFiles) {
      previews.add(await _compressImage(f, maxSize: 150, quality: 0.6));
    }

    setState(() {
      _selectedFiles = dartFiles;
      _selectedFileDataUrls = previews;
      _isSubmitting = false;
    });
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (pickedDate != null) {
      setState(() {
        _dateOrderedController.text =
            DateFormat('dd/MM/yyyy').format(pickedDate);
      });
    }
  }

  Future<void> _attachFilesToRequest(
    http.MultipartRequest request,
    List<web.File> files, {
    required String fieldName,
  }) async {
    for (final file in files) {
      final jsBuffer = await file.arrayBuffer().toDart as ByteBuffer;
      final bytes = Uint8List.view(jsBuffer);

      // file.type is something like "image/jpeg" or "image/png"
      final parts = file.type.split('/');
      final contentType = (parts.length == 2)
          ? MediaType(parts[0], parts[1])
          : MediaType('image', 'jpeg'); // fallback if file.type is empty

      request.files.add(
        http.MultipartFile.fromBytes(
          fieldName,
          bytes,
          filename: file.name,
          contentType: contentType,
        ),
      );
    }
  }

  Future<void> _submitForm() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    final customerName = _customerNameController.text;
    final dateOrdered = _dateOrderedController.text;
    final jobId = _jobIdController.text;
    final address = _addressController.text;
    final phoneNumber = _phoneNumberController.text;
    final emailAddress = _emailAdressController.text;
    final eta = _etaController.text;

    if (customerName.isEmpty ||
        dateOrdered.isEmpty ||
        jobId.isEmpty ||
        eta.isEmpty ||
        (address.isEmpty && !_isPickup)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields')),
      );
      setState(() => _isSubmitting = false);
      return;
    }

    // — Validate “Date Ordered” (DD/MM/YYYY) —
    final dateRegex = RegExp(r'^\d{2}/\d{2}/\d{4}$');
    if (!dateRegex.hasMatch(dateOrdered)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Date must be in DD/MM/YYYY format')),
      );
      setState(() => _isSubmitting = false);
      return;
    }
    try {
      DateFormat('dd/MM/yyyy').parseStrict(dateOrdered);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid date. Please use DD/MM/YYYY')),
      );
      setState(() => _isSubmitting = false);
      return;
    }

// — Validate “ETA” (DD/MM/YYYY HH:MM) —
    final etaRegex = RegExp(r'^\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}$');
    if (!etaRegex.hasMatch(eta)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ETA must be in DD/MM/YYYY HH:MM format')),
      );
      setState(() => _isSubmitting = false);
      return;
    }
    try {
      DateFormat('dd/MM/yyyy HH:mm').parseStrict(eta);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Invalid ETA. Please use DD/MM/YYYY HH:MM')),
      );
      setState(() => _isSubmitting = false);
      return;
    }

    // grab token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');

    final uri = Uri.parse('${getBaseUrl()}/orders');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['customerName'] = customerName
      ..fields['dateOrdered'] = dateOrdered
      ..fields['eta'] = eta
      ..fields['jobId'] = jobId
      ..fields['address'] = address
      ..fields['pickup'] = _isPickup ? '1' : '0'
      ..fields['urgent'] = _isUrgent ? '1' : '0'
      ..fields['emailAddress'] = emailAddress
      ..fields['phoneNumber'] = phoneNumber;

    if (_selectedFiles.isNotEmpty) {
      await _attachFilesToRequest(request, _selectedFiles, fieldName: 'images');
    }
    if (_selectedDocuments.isNotEmpty) {
      await _attachFilesToRequest(request, _selectedDocuments,
          fieldName: 'documents');
    }

    try {
      final response = await request.send();
      if (response.statusCode == 200) {
        final responseData = await response.stream.bytesToString();
        final order = Order.fromJson(jsonDecode(responseData));
        widget.onAddOrder(order);
        if (mounted) Navigator.pop(context);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to add order: ${response.statusCode}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
        child: Center(
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          FontAwesomeIcons.folderPlus,
                          size: 25,
                          color: Colors.deepPurple,
                        ),
                        Padding(
                            padding: const EdgeInsets.only(left: 8, right: 8),
                            child: Text('Create Order',
                                style: theme.textTheme.titleLarge!
                                    .copyWith(fontWeight: FontWeight.w600))),
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
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  color: Colors.white,
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _customerNameController,
                          decoration: const InputDecoration(
                              labelText: 'Customer Name',
                              suffixIcon: Icon(
                                FontAwesomeIcons.solidUser,
                                color: Colors.deepPurple,
                              )),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          inputFormatters: [_dateMaskFormatter],
                          readOnly: false,
                          controller: _dateOrderedController,
                          decoration: InputDecoration(
                            labelText: 'Date (DD/MM/YYYY)',
                            suffixIcon: IconButton(
                              onPressed: () => _selectDate(context),
                              icon: const Icon(FontAwesomeIcons.calendarDay),
                              color: Colors.deepPurple,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          inputFormatters: [_etaMaskFormatter],
                          readOnly: false,
                          controller: _etaController,
                          decoration: InputDecoration(
                            labelText: 'Date Required (DD/MM/YYYY HH:MM)',
                            suffixIcon: IconButton(
                              onPressed: () => _selectEta(),
                              icon: const Icon(FontAwesomeIcons.solidClock),
                              color: Colors.deepPurple,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _jobIdController,
                          decoration: const InputDecoration(
                              labelText: 'Order Number',
                              suffixIcon: Icon(
                                FontAwesomeIcons.hashtag,
                                color: Colors.deepPurple,
                              )),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _phoneNumberController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Phone Number',
                            suffixIcon: Icon(
                              FontAwesomeIcons.phone,
                              color: Colors.deepPurple,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          keyboardType: TextInputType.emailAddress,
                          controller: _emailAdressController,
                          decoration: const InputDecoration(
                              labelText: 'Email Address',
                              suffixIcon: Icon(
                                FontAwesomeIcons.solidEnvelope,
                                color: Colors.deepPurple,
                              )),
                        ),
                        const SizedBox(height: 12),
                        if (!_isPickup)
                          TextField(
                            controller: _addressController,
                            decoration: const InputDecoration(
                                labelText: ' Delivery Address',
                                suffixIcon: Icon(
                                  FontAwesomeIcons.house,
                                  color: Colors.deepPurple,
                                )),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: CheckboxListTile(
                            contentPadding: const EdgeInsets.all(0),
                            title: const Text('Customer Pickup'),
                            value: _isPickup,
                            onChanged: (val) {
                              setState(() {
                                _isPickup = val ?? false;
                                if (val == true) {
                                  _addressController.text = 'Customer Pickup';
                                } else {
                                  _addressController.text = '';
                                }
                              });
                            },
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: CheckboxListTile(
                            contentPadding: const EdgeInsets.all(0),
                            title: const Text('Mark as Urgent'),
                            value: _isUrgent,
                            onChanged: (val) =>
                                setState(() => _isUrgent = val ?? false),
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
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
                                  onPressed: _pickDocuments,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        FontAwesomeIcons.solidFilePdf,
                                        size: 25,
                                        color: Colors.deepPurple.shade500,
                                      ),
                                      const SizedBox(
                                        width: 8,
                                      ),
                                      Text(
                                        'Add Documents',
                                        style: theme.textTheme.titleMedium,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
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
                                  onPressed: _pickImages,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        FontAwesomeIcons.solidImage,
                                        size: 25,
                                        color: Colors.deepPurple.shade500,
                                      ),
                                      const SizedBox(
                                        width: 8,
                                      ),
                                      Text(
                                        'Add Images',
                                        style: theme.textTheme.titleMedium,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Card(
                                color: Colors.white,
                                elevation: 2,
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.all(16),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    side: const BorderSide(
                                      color: Colors.grey,
                                      width: 1,
                                    ),
                                  ),
                                  onPressed: _isSubmitting ? null : _submitForm,
                                  child: _isSubmitting
                                      ? Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor:
                                                    AlwaysStoppedAnimation(
                                                  Colors.deepPurple.shade500,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(
                                              width: 8,
                                            ),
                                            Text(
                                              'Uploading...',
                                              style:
                                                  theme.textTheme.titleMedium,
                                            )
                                          ],
                                        )
                                      : Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              FontAwesomeIcons.folderPlus,
                                              size: 25,
                                              color: Colors.deepPurple.shade500,
                                            ),
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  left: 8.0),
                                              child: Text(
                                                'Create Order',
                                                style:
                                                    theme.textTheme.titleMedium,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_selectedFiles.isNotEmpty) ...[
                          Text(
                              '${_selectedFiles.length} of 10 images selected'),
                          const SizedBox(height: 8),
                        ],
                        if (_selectedFileDataUrls.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _selectedFileDataUrls.map((dataUrl) {
                              return ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  dataUrl,
                                  width: 80,
                                  height: 80,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.broken_image),
                                ),
                              );
                            }).toList(),
                          ),
                        if (_selectedDocuments.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            '${_selectedDocuments.length} PDF${_selectedDocuments.length > 1 ? 's' : ''} selected out of 5',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: _selectedDocuments.map((file) {
                              return Chip(
                                avatar: const Icon(Icons.picture_as_pdf,
                                    size: 20, color: Colors.red),
                                label: Text(
                                  file.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
