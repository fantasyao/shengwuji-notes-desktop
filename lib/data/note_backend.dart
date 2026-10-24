import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/note.dart';
import '../sync/sync_models.dart';

/// 笔记存储后端。
///
/// `NoteStore` 只负责对外 API 稳定；真正的读写由 SQLite（[NoteDatabase]）或
/// 迁移失败时的 `notes.json`（`LegacyJsonNoteStore`）实现。
abstract class NoteBackend {
  Future<List<Note>> load();

  Future<void> writeAll(List<Note> notes);

  /// 保存图片，返回相对数据目录的附件路径。
  Future<String> saveImage(Uint8List bytes);

  Future<void> deleteImage(String name);

  /// 把当前数据完整复制到目标目录，返回复制的主文件与附件数。
  Future<int> copyTo(Directory target);

  Future<void> close();
}

/// 同步快照：笔记（含附件元数据）与笔记墓碑。
class SyncSnapshot {
  const SyncSnapshot({required this.notes, required this.tombstones});

  final List<SyncNote> notes;
  final Map<String, NoteTombstone> tombstones;
}

/// 同步期间本地被用户改动，本次写入必须放弃并重试。
class LocalChangedDuringSync implements Exception {
  const LocalChangedDuringSync();

  @override
  String toString() => '同步期间本地有修改，已取消本次写入';
}

/// 支持双向同步的后端能力。兼容模式（旧 JSON）不实现，界面据此禁用同步。
abstract class SyncCapableNoteBackend {
  Future<SyncSnapshot> readSyncSnapshot();

  /// 以事务写入合并结果；[expected] 与当前库不一致时抛 [LocalChangedDuringSync]。
  Future<void> applySync({
    required SyncSnapshot expected,
    required SyncSnapshot finalState,
  });

  Future<String?> readSyncState();

  Future<void> writeSyncState(String json);
}


/// 把附件名收敛成数据目录下的安全相对路径。
///
/// 只放行 `blobs/<xx>/<file>` 与 `images/<file>` 两种结构；其余一律当旧版
/// 扁平文件名处理，`..`、绝对路径和多余层级都会被丢掉。
String sanitizeAttachmentPath(String name) {
  final segments = name
      .replaceAll(r'\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty && segment != '.')
      .toList(growable: false);
  if (segments.isEmpty) return '';
  if (segments.contains('..')) {
    return segments.where((segment) => segment != '..').lastOrNull ?? '';
  }
  if (segments.first == 'blobs' && segments.length >= 2) {
    return segments.join('/');
  }
  if (segments.first == 'images' && segments.length >= 2) {
    return segments.join('/');
  }
  return segments.last;
}

File attachmentFile(Directory rootDir, String name) {
  final relative = sanitizeAttachmentPath(name);
  if (relative.isEmpty) return File(rootDir.path);
  return File(p.joinAll([rootDir.path, ...relative.split('/')]));
}

/// 只有数据目录自己管理的附件子树才允许写入/删除。
bool isManagedAttachmentPath(String relative) {
  return relative.startsWith('blobs/') || relative.startsWith('images/');
}
