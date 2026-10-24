import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import '../sync/sync_exception.dart';
import 'image_payload.dart';
import 'legacy_json_note_store.dart';
import 'note_backend.dart';
import 'note_database.dart';

/// 笔记存储门面：默认使用 SQLite，`notes.json` 迁移失败时退回旧版 JSON。
///
/// 界面只依赖这里的方法，因此存储后端可以继续演进而不影响页面与控制器。
class NoteStore {
  NoteStore({required this.rootDir});

  static const int maxImageBytes = kMaxImageBytes;

  final Directory rootDir;

  Future<NoteBackend>? _opening;
  bool _usingLegacyJson = false;

  /// 当前是否因为迁移失败而运行在 `notes.json` 兼容模式。
  bool get isLegacyFallback => _usingLegacyJson;

  static Future<NoteStore> openDefault() async {
    final base = await getApplicationSupportDirectory();
    return NoteStore(
      rootDir: Directory(p.join(base.path, 'shengwuji_desktop')),
    );
  }

  Directory get imagesDir => Directory(p.join(rootDir.path, 'images'));

  Future<List<Note>> load() async => (await _ensureBackend()).load();

  Future<void> writeAll(List<Note> notes) async {
    await (await _ensureBackend()).writeAll(notes);
  }

  Future<String> saveImage(Uint8List bytes) async {
    return (await _ensureBackend()).saveImage(bytes);
  }

  /// 图片/附件在磁盘上的实际路径。
  ///
  /// `blobs/`、`images/` 开头的相对路径按数据目录解析；旧版扁平文件名仍落在
  /// `images/` 下，兼容模式与测试替身都依赖这个约定。
  File imageFile(String name) {
    final relative = sanitizeAttachmentPath(name);
    if (isManagedAttachmentPath(relative)) {
      return attachmentFile(rootDir, relative);
    }
    return File(p.join(imagesDir.path, p.basename(relative)));
  }

  Future<void> deleteImage(String name) async {
    await (await _ensureBackend()).deleteImage(name);
  }

  Future<void> deleteImages(Iterable<String> names) async {
    for (final name in names) {
      await deleteImage(name);
    }
  }

  /// 复制到新数据目录；设置文件不在这里，始终留在配置目录。
  Future<int> copyTo(Directory target) async {
    return (await _ensureBackend()).copyTo(target);
  }

  /// 当前后端是否支持双向同步（旧 JSON 兼容模式不支持）。
  Future<bool> supportsSync() async =>
      (await _ensureBackend()) is SyncCapableNoteBackend;

  Future<SyncSnapshot?> readSyncSnapshot() async {
    final backend = await _ensureBackend();
    return backend is SyncCapableNoteBackend
        ? (backend as SyncCapableNoteBackend).readSyncSnapshot()
        : null;
  }

  Future<void> applySync({
    required SyncSnapshot expected,
    required SyncSnapshot finalState,
  }) async {
    final backend = await _ensureBackend();
    if (backend is! SyncCapableNoteBackend) {
      throw const SyncException('当前数据目录处于兼容模式，暂不支持同步');
    }
    await (backend as SyncCapableNoteBackend).applySync(
      expected: expected,
      finalState: finalState,
    );
  }

  Future<String?> readSyncState() async {
    final backend = await _ensureBackend();
    return backend is SyncCapableNoteBackend
        ? (backend as SyncCapableNoteBackend).readSyncState()
        : null;
  }

  Future<void> writeSyncState(String json) async {
    final backend = await _ensureBackend();
    if (backend is SyncCapableNoteBackend) {
      await (backend as SyncCapableNoteBackend).writeSyncState(json);
    }
  }

  /// 把远端图片按内容寻址写入本地 blob，返回相对路径。
  Future<String> importBlob(String hash, Uint8List bytes) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('远端图片哈希不合法');
    }
    final actual = sha256.convert(bytes).toString();
    if (actual != hash) {
      throw const FormatException('远端图片校验失败');
    }
    if (bytes.length > maxImageBytes) {
      throw const ImageTooLargeException(maxImageBytes);
    }
    final detected = detectImageExtension(bytes);
    if (detected == null) {
      throw const UnsupportedImageException('远端图片格式不受支持');
    }
    final relative = 'blobs/${hash.substring(0, 2)}/$hash.$detected';
    final file = attachmentFile(rootDir, relative);
    if (await file.exists()) return relative;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.syncing');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        if (!await file.exists()) rethrow;
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 临时文件清理失败不影响已落盘的内容。
      }
    }
    return relative;
  }

  /// 把远端录音按内容寻址写入本地 blob，返回相对路径。
  ///
  /// 与图片不同，录音没有可校验的格式魔数，只校验 sha256 与扩展名。
  Future<String> importAudioBlob(
    String hash,
    Uint8List bytes,
    String extension,
  ) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('远端录音哈希不合法');
    }
    final actual = sha256.convert(bytes).toString();
    if (actual != hash) {
      throw const FormatException('远端录音校验失败');
    }
    final ext = RegExp(r'^[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : 'bin';
    final relative = 'blobs/${hash.substring(0, 2)}/$hash.$ext';
    final file = attachmentFile(rootDir, relative);
    if (await file.exists()) return relative;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.syncing');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        if (!await file.exists()) rethrow;
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 临时文件清理失败不影响已落盘的内容。
      }
    }
    return relative;
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening == null) return;
    try {
      await (await opening).close();
    } catch (error) {
      debugPrint('关闭笔记存储失败：$error');
    }
  }

  Future<NoteBackend> _ensureBackend() {
    return _opening ??= _openBackend();
  }

  Future<NoteBackend> _openBackend() async {
    try {
      return await NoteDatabase.open(rootDir);
    } on LegacyMigrationException catch (error) {
      debugPrint('$error，改用 notes.json 兼容模式');
      _usingLegacyJson = true;
      return LegacyJsonNoteStore(rootDir);
    }
  }
}
