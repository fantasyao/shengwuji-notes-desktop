import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import 'image_payload.dart';

/// 本地笔记存储：`notes.json` + `images/`。
///
/// 数据保存在系统应用支持目录，卸载应用前不会丢；JSON 采用先写临时文件再
/// 替换的方式，避免写到一半崩溃留下半截文件。损坏的 notes.json 会被改名留档，
/// 不会直接被覆盖。
class NoteStore {
  NoteStore({required this.rootDir});

  static const int maxImageBytes = 20 * 1024 * 1024;
  static const Uuid _uuid = Uuid();

  final Directory rootDir;

  static Future<NoteStore> openDefault() async {
    final base = await getApplicationSupportDirectory();
    return NoteStore(rootDir: Directory(p.join(base.path, 'shengwuji_desktop')));
  }

  File get notesFile => File(p.join(rootDir.path, 'notes.json'));

  Directory get imagesDir => Directory(p.join(rootDir.path, 'images'));

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
          // 单条坏行跳过，不影响其余笔记。
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

  /// 保存一张图片，返回相对文件名（存进 Note.images）。
  Future<String> saveImage(Uint8List bytes) async {
    final payload = normalizeImage(bytes);
    if (payload.bytes.length > maxImageBytes) {
      throw const ImageTooLargeException(maxImageBytes);
    }
    await imagesDir.create(recursive: true);
    final name =
        '${DateTime.now().millisecondsSinceEpoch}_'
        '${_uuid.v4().substring(0, 8)}.${payload.extension}';
    final file = File(p.join(imagesDir.path, name));
    await file.writeAsBytes(payload.bytes, flush: true);
    return name;
  }

  File imageFile(String name) {
    // 文件名来自本地 JSON，仍做一次 basename 收敛，防止路径穿越。
    return File(p.join(imagesDir.path, p.basename(name)));
  }

  Future<void> deleteImage(String name) async {
    if (!_isSafeImageName(name)) return;
    final file = imageFile(name);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint('删除图片失败 $name：$error');
    }
  }

  Future<void> deleteImages(Iterable<String> names) async {
    for (final name in names) {
      await deleteImage(name);
    }
  }

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
