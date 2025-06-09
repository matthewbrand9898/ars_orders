String getBaseUrl() {
  final uri = Uri.base;
  if (uri.host.contains('arsorders')) {
    return uri.origin;
  } else {
    return 'http://192.168.1.4:3000';
  }
}
