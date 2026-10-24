import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shengwuji_desktop/sync/sync_exception.dart';
import 'package:shengwuji_desktop/sync/webdav_client.dart';

/// 内存版 WebDAV：路径均相对远端目录。
class FakeCloudStorage implements CloudStorage {
  final Map<String, Uint8List> files = {};

  bool supportsList = true;
  bool supportsStat = true;
  bool directoryReady = false;
  bool closed = false;
  int writes = 0;
  int reads = 0;
  int stats = 0;
  String? failWritePath;
  int failWriteStatus = 500;

  /// 非空时阻塞下一次读取，用来模拟慢速网络。
  Completer<void>? blockRead;

  void putText(String path, String text) {
    files[path] = Uint8List.fromList(utf8.encode(text));
  }

  String? text(String path) {
    final bytes = files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  Future<void> ensureDirectory() async {
    directoryReady = true;
  }

  @override
  Future<RemoteStat?> stat(String path) async {
    stats++;
    if (!supportsStat) throw UnsupportedError('测试：不支持 PROPFIND');
    final bytes = files[path];
    if (bytes == null) return null;
    return RemoteStat(
      etag: sha256.convert(bytes).toString(),
      lastModified: '${bytes.length}',
    );
  }

  @override
  Future<RemoteFile?> read(String path) async {
    reads++;
    final gate = blockRead;
    if (gate != null) {
      blockRead = null;
      await gate.future;
    }
    final bytes = files[path];
    if (bytes == null) return null;
    return RemoteFile(bytes: bytes, etag: '${bytes.length}');
  }

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    String contentType = 'application/json; charset=utf-8',
  }) async {
    writes++;
    if (path == failWritePath) {
      throw SyncException('模拟上传失败', statusCode: failWriteStatus);
    }
    files[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }

  @override
  Future<Set<String>?> list(String path) async {
    if (!supportsList) return null;
    final prefix = path.endsWith('/') ? path : '$path/';
    final names = <String>{};
    for (final key in files.keys) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length);
      if (rest.isEmpty || rest.contains('/')) continue;
      names.add(rest);
    }
    return names;
  }

  @override
  Future<void> ping() async {}

  @override
  Future<void> close() async {
    closed = true;
  }
}
