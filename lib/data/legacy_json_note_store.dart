import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import 'image_payload.dart';
import 'note_backend.dart';

/// 兼容模式后端：继续读写旧版 `notes.json` + `images/`。
///
/// 只在 `notes.json` 无法迁移进 SQLite 时使用，保证原文件不动、应用仍可打开。
class LegacyJsonNoteStore implements NoteBackend {
  LegacyJsonNoteStore(this.rootDir);

  static const Uuid _uuid = Uuid();

  final Directory rootDir;

  File get notesFile => File(p.join(rootDir.path, 'notes.json'));

  Directory get imagesDir => Directory(p.join(rootDir.path, 'images'));

  @override
  Future<List<Note>> load() async {
    await imagesDir.create(recursive: true);
    if (!await notesFile.exists()) return [];

    final text = await notesFile.readAsString();
    if (text.trim().isEmpty) return [];

    try {
      final decoded = jsonDecode(text);
      if (decoded is! List) {
        throw const FormatException('notes.json 顶层不是数组');
      }
      final notes = <Note>[];
      for (final item in decoded) {
        final map = decodeNoteMap(item);
        if (map == null) continue;
        try {
          notes.add(Note.fromJson(map));
        } on FormatException catch (error) {
          debugPrint('跳过一条无法解析的笔记：$error');
        }
      }
      return notes;
    } catch (error) {
      debugPrint('notes.json 解析失败，已留档：$error');
      await _preserveCorruptFile();
      return [];
    }
  }

  @override
  Future<void> writeAll(List<Note> notes) async {
    await rootDir.create(recursive: true);
    final content = encodeNotesPretty(notes);
    final tmp = File('${notesFile.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    try {
      await tmp.rename(notesFile.path);
    } on FileSystemException {
      // Windows 上目标存在时 rename 可能失败，退回直接覆盖。
      await notesFile.writeAsString(content, flush: true);
      if (await tmp.exists()) {
        await tmp.delete();
      }
    }
  }

  @override
  Future<String> saveImage(Uint8List bytes) async {
    final payload = normalizeImage(bytes);
    if (payload.bytes.length > kMaxImageBytes) {
      throw const ImageTooLargeException(kMaxImageBytes);
    }
    await imagesDir.create(recursive: true);
    final name =
        '${DateTime.now().millisecondsSinceEpoch}_'
        '${_uuid.v4().substring(0, 8)}.${payload.extension}';
    final file = File(p.join(imagesDir.path, name));
    await file.writeAsBytes(payload.bytes, flush: true);
    return name;
  }

  @override
  Future<void> deleteImage(String name) async {
    if (!_isSafeImageName(name)) return;
    final file = File(p.join(imagesDir.path, p.basename(name)));
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint('删除图片失败 $name：$error');
    }
  }

  @override
  Future<int> copyTo(Directory target) async {
    var copied = 0;
    if (await notesFile.exists()) {
      await notesFile.copy(p.join(target.path, 'notes.json'));
      copied++;
    }
    final images = Directory(p.join(rootDir.path, 'images'));
    if (await images.exists()) {
      final targetImages = Directory(p.join(target.path, 'images'));
      await targetImages.create(recursive: true);
      await for (final entity in images.list(followLinks: false)) {
        if (entity is! File) continue;
        await entity.copy(p.join(targetImages.path, p.basename(entity.path)));
        copied++;
      }
    }
    return copied;
  }

  @override
  Future<void> close() async {}

  bool _isSafeImageName(String name) {
    return name.isNotEmpty &&
        p.basename(name) == name &&
        !name.contains('..') &&
        !name.contains('/') &&
        !name.contains(r'\');
  }

  Future<void> _preserveCorruptFile() async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final target = File(p.join(rootDir.path, 'notes.corrupt-$stamp.json'));
    try {
      await notesFile.rename(target.path);
    } on FileSystemException catch (error) {
      debugPrint('损坏文件留档失败：$error');
    }
  }
}
