import 'order_update.dart';

class OrderDocument {
  final String filename; // the stored name on disk
  final String originalName; // what the user called it

  OrderDocument({required this.filename, required this.originalName});

  factory OrderDocument.fromJson(Map<String, dynamic> j) {
    return OrderDocument(
      filename: j['filename'] as String,
      originalName: j['originalname'] as String,
    );
  }
}

class Order {
  final int? id;
  final String customerName;
  final String dateOrdered;
  final String eta;
  final String jobId;
  final String status;
  final String phoneNumber;
  final String emailAddress;
  final int? pickup;
  final String? address;
  final List<String> images;
  final List<OrderDocument> documents;
  // final List<String> evidence;
  final List<OrderUpdate> updates;
  final int urgent;

  Order({
    this.id,
    required this.customerName,
    required this.dateOrdered,
    required this.eta,
    required this.jobId,
    required this.status,
    required this.address,
    required this.phoneNumber,
    required this.emailAddress,
    required this.pickup,
    required this.images,
    required this.documents,
    //this.evidence = const [],
    this.updates = const [],
    required this.urgent,
  });

  /*
  Order copyWith(
      {int? id,
      String? customerName,
      String? dateOrdered,
      String? jobId,
      String? status,
      String? address,
      int? pickup,
      List<String>? images,
      List<OrderUpdate>? updates,
      int? urgent}) {
    return Order(
      id: id ?? this.id,
      status: status ?? this.status,
      customerName: customerName ?? this.customerName,
      dateOrdered: dateOrdered ?? this.dateOrdered,
      images: images ?? this.images,
      address: address ?? this.address,
      pickup: pickup ?? this.pickup,
      jobId: jobId ?? this.jobId,
      updates: updates ?? this.updates,
      urgent: urgent ?? this.urgent,
    );
  }
*/

  factory Order.fromJson(Map<String, dynamic> j) {
    final rawImages = j['images'];
    List<String> imagesList = [];
    if (rawImages is List) {
      imagesList =
          rawImages.where((e) => e != null).map((e) => e as String).toList();
    }

    final rawDocs = j['documents'] as List? ?? [];
    final docList = rawDocs
        .whereType<Map<String, dynamic>>()
        .map((m) => OrderDocument.fromJson(m))
        .toList();

    //List<String> evidenceList = [];
    //if (j['evidence'] is List) {
    // evidenceList = (j['evidence'] as List).cast<String>();
    //}

    var updList = <OrderUpdate>[];
    if (j['updates'] is List) {
      updList =
          (j['updates'] as List).map((u) => OrderUpdate.fromJson(u)).toList();
    }

    return Order(
        id: j['id'],
        customerName: j['customerName'],
        dateOrdered: j['dateOrdered'],
        eta: j['eta'],
        jobId: j['jobId'],
        status: j['status'],
        emailAddress: j['emailAddress'],
        phoneNumber: j['phoneNumber'],
        pickup: j['pickup'],
        address: j['address'],
        urgent: j['urgent'],
        //  evidence: evidenceList,
        images: imagesList,
        documents: docList,
        updates: updList);
  }
}
