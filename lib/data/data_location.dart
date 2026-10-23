import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'settings_store.dart';

/// 应用配置目录：`settings.json`（含数据目录指针）永远放在这里。
Future<Directory> configDirectory() async {
  final base = await getApplicationSupportDirectory();
  return Directory(p.join(base.path, 'shengwuji_desktop'));
}

/// 解析笔记目录：用户选过且能读写就用它，否则回退默认目录。
///
/// 外接硬盘 / 同步盘临时不可用时不能让应用起不来，这里始终返回一个可用目录。
Future<Directory> resolveDataDirectory(AppSettings settings) async {
  final fallback = await configDirectory();
  final configured = settings.dataDirectory?.trim();
  if (configured == null || configured.isEmpty) {
    await fallback.create(recursive: true);
    return fallback;
  }
  final dir = Directory(configured);
  try {
    await dir.create(recursive: true);
    return dir;
  } on FileSystemException catch (error) {
    debugPrint('数据目录不可用，回退默认目录：$error');
    await fallback.create(recursive: true);
    return fallback;
  }
}

/// 目录里是否已经有一份非空笔记，用来决定“复制过去”还是“直接用那边的数据”。
Future<bool> hasExistingNotes(Directory dir) async {
  final file = File(p.join(dir.path, 'notes.json'));
  if (!await file.exists()) return false;
  try {
    final text = await file.readAsString();
    if (text.trim().isEmpty) return false;
    final decoded = jsonDecode(text);
    if (decoded is List) return decoded.isNotEmpty;
    return true;
  } on FileSystemException {
    return true;
  } on FormatException {
    // 有内容但解析不了：当成“已有数据”，交给用户确认，避免直接覆盖。
    return true;
  }
}

/// 把笔记与图片复制到新目录，返回复制的文件数。
///
/// 只复制 `notes.json` 与 `images/`：设置文件属于应用本身，留在配置目录；
/// 原目录一律不动，切换失败或想换回去时数据都还在。
Future<int> copyNotesData(Directory from, Directory to) async {
  var copied = 0;
  final notes = File(p.join(from.path, 'notes.json'));
  if (await notes.exists()) {
    await notes.copy(p.join(to.path, 'notes.json'));
    copied++;
  }
  final images = Directory(p.join(from.path, 'images'));
  if (await images.exists()) {
    final targetImages = Directory(p.join(to.path, 'images'));
    await targetImages.create(recursive: true);
    await for (final entity in images.list(followLinks: false)) {
      if (entity is! File) continue;
      await entity.copy(p.join(targetImages.path, p.basename(entity.path)));
      copied++;
    }
  }
  return copied;
}

/// 切换数据目录失败时给界面展示的可读原因。
class DataDirectoryException implements Exception {
  const DataDirectoryException(this.message);

  final String message;

  @override
  String toString() => message;
}
