/// 同步失败时给界面看的可读原因。
class SyncException implements Exception {
  const SyncException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
