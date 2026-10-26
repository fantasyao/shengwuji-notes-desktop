import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 本机已安装的一个字体家族。
class SystemFont {
  const SystemFont({
    required this.family,
    required this.label,
    required this.path,
  });

  /// 字体内部的家族名，直接交给 `TextStyle.fontFamily` 使用。
  final String family;

  /// 界面展示名，优先使用中文本地化名（如「宋体」），没有时等于 [family]。
  final String label;

  /// 字体文件路径，只用于提示与排查问题。
  final String path;
}

/// 枚举本机已安装的字体。
///
/// Windows 的系统字体在 `%WINDIR%\Fonts`，当前用户自己安装的字体在
/// `%LOCALAPPDATA%\Microsoft\Windows\Fonts`。这里直接读字体文件的 `name` 表，
/// 拿到可用于 [SystemFont.family] 的家族名；不联网、不写任何设置。
///
/// 同时支持 `.ttf` / `.otf` / `.ttc`：宋体、微软雅黑等中文字体常常打包在
/// `.ttc` 里，只认 `.ttf` 会漏掉一半。
class SystemFontCatalog {
  SystemFontCatalog({List<Directory>? fontDirectories})
    : _directories = fontDirectories;

  static const int _ttcTag = 0x74746366; // 'ttcf'
  static const int _nameTag = 0x6E616D65; // 'name'
  static const int _maxNameTableBytes = 1 << 20;
  static const int _maxTtcFaces = 256;

  final List<Directory>? _directories;
  Future<List<SystemFont>>? _loading;
  List<SystemFont>? _fonts;

  /// 读取所有字体；成功后缓存，重复调用不会重新扫目录。
  Future<List<SystemFont>> load() {
    final cached = _fonts;
    if (cached != null) return Future.value(cached);
    return _loading ??= _loadAll()
        .then((fonts) {
          _fonts = fonts;
          return fonts;
        })
        .whenComplete(() => _loading = null);
  }

  static List<Directory> defaultDirectories() {
    if (!Platform.isWindows) return const [];
    final windir = Platform.environment['WINDIR'];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    return [
      Directory(
        p.join(
          windir == null || windir.isEmpty ? r'C:\Windows' : windir,
          'Fonts',
        ),
      ),
      if (localAppData != null && localAppData.isNotEmpty)
        Directory(p.join(localAppData, 'Microsoft', 'Windows', 'Fonts')),
    ];
  }

  Future<List<SystemFont>> _loadAll() async {
    final found = <String, SystemFont>{};
    var failures = 0;
    for (final directory in _directories ?? defaultDirectories()) {
      if (!await directory.exists()) continue;
      List<FileSystemEntity> entries;
      try {
        entries = await directory.list(followLinks: false).toList();
      } catch (error) {
        debugPrint('读取字体目录失败 ${directory.path}：$error');
        continue;
      }
      for (final entry in entries) {
        if (entry is! File) continue;
        final extension = p.extension(entry.path).toLowerCase();
        if (extension != '.ttf' && extension != '.otf' && extension != '.ttc') {
          continue;
        }
        try {
          for (final face in await readFontFaces(entry)) {
            final key = face.family.toLowerCase();
            if (key.isEmpty || found.containsKey(key)) continue;
            found[key] = face;
          }
        } catch (error) {
          failures++;
          if (failures <= 3) {
            debugPrint('读取字体失败 ${entry.path}：$error');
          }
        }
      }
    }
    if (failures > 3) {
      debugPrint('另有 ${failures - 3} 个字体文件读取失败，已跳过');
    }
    final fonts = found.values.toList()
      ..sort(
        (a, b) => a.family.toLowerCase().compareTo(b.family.toLowerCase()),
      );
    return List.unmodifiable(fonts);
  }

  /// 读一个字体文件里的所有字体家族（ttc 可能包含多个）。
  @visibleForTesting
  Future<List<SystemFont>> readFontFaces(File file) async {
    final handle = await file.open();
    try {
      final faces = <SystemFont>[];
      final headerBytes = await _readAt(handle, 0, 12);
      if (headerBytes.length < 12) return faces;
      final header = ByteData.sublistView(headerBytes);
      if (header.getUint32(0) == _ttcTag) {
        final count = header.getUint32(8);
        if (count == 0 || count > _maxTtcFaces) return faces;
        final offsetBytes = await _readAt(handle, 12, count * 4);
        final offsets = ByteData.sublistView(offsetBytes);
        for (var i = 0; i < count && (i + 1) * 4 <= offsetBytes.length; i++) {
          final name = await _readFaceName(handle, offsets.getUint32(i * 4));
          if (name != null) {
            faces.add(_toFont(name, file.path));
          }
        }
        return faces;
      }
      final name = await _readFaceName(handle, 0);
      if (name != null) faces.add(_toFont(name, file.path));
      return faces;
    } finally {
      await handle.close();
    }
  }

  SystemFont _toFont(_FaceName name, String path) =>
      SystemFont(family: name.family, label: name.label, path: path);

  Future<_FaceName?> _readFaceName(
    RandomAccessFile handle,
    int faceOffset,
  ) async {
    if (faceOffset < 0) return null;
    final headerBytes = await _readAt(handle, faceOffset, 12);
    if (headerBytes.length < 12) return null;
    final header = ByteData.sublistView(headerBytes);
    final version = header.getUint32(0);
    if (version != 0x00010000 &&
        version != 0x4F54544F && // 'OTTO'
        version != 0x74727565) {
      // 'true'
      return null;
    }
    final tableCount = header.getUint16(4);
    if (tableCount == 0 || tableCount > 512) return null;

    final directoryBytes = await _readAt(
      handle,
      faceOffset + 12,
      tableCount * 16,
    );
    if (directoryBytes.length < tableCount * 16) return null;
    final directory = ByteData.sublistView(directoryBytes);
    int? nameOffset;
    int? nameLength;
    for (var i = 0; i < tableCount; i++) {
      final base = i * 16;
      if (directory.getUint32(base) != _nameTag) continue;
      nameOffset = directory.getUint32(base + 8);
      nameLength = directory.getUint32(base + 12);
      break;
    }
    if (nameOffset == null || nameLength == null || nameLength <= 0) {
      return null;
    }
    final tableBytes = await _readAt(
      handle,
      nameOffset,
      math.min(nameLength, _maxNameTableBytes),
    );
    return _parseNameTable(tableBytes);
  }

  static Future<Uint8List> _readAt(
    RandomAccessFile handle,
    int offset,
    int length,
  ) async {
    await handle.setPosition(offset);
    return handle.read(length);
  }

  /// 解析 `name` 表里的家族名。
  ///
  /// 优先英文家族名（交给系统匹配最稳），同时读一份中文名做展示；
  /// 没有英文名时退回任一可用名字。
  static _FaceName? _parseNameTable(Uint8List bytes) {
    if (bytes.length < 6) return null;
    final data = ByteData.sublistView(bytes);
    final count = data.getUint16(2);
    final storageOffset = data.getUint16(4);
    if (count == 0 || count > 4096) return null;
    if (6 + count * 12 > bytes.length) return null;

    String? familyEnglish;
    String? familyChinese;
    String? familyAny;
    String? typographicEnglish;
    String? typographicChinese;

    for (var i = 0; i < count; i++) {
      final base = 6 + i * 12;
      final platformId = data.getUint16(base);
      final languageId = data.getUint16(base + 4);
      final nameId = data.getUint16(base + 6);
      final length = data.getUint16(base + 8);
      final stringOffset = data.getUint16(base + 10);
      if (nameId != 1 && nameId != 16) continue;
      // 只处理 Unicode（3 = Windows/Unicode BMP，0 = Unicode）。
      if (platformId != 0 && platformId != 3) continue;
      final start = storageOffset + stringOffset;
      final end = start + length;
      if (length.isOdd || start < 0 || end > bytes.length) continue;
      final text = _decodeUtf16Be(bytes, start, end).trim();
      if (text.isEmpty || text.startsWith('@')) continue;

      final isEnglish = platformId == 3 && languageId == 0x0409;
      final isChinese =
          platformId == 3 &&
          (languageId == 0x0804 ||
              languageId == 0x0404 ||
              languageId == 0x1004);
      if (nameId == 1) {
        familyAny ??= text;
        if (isEnglish) familyEnglish ??= text;
        if (isChinese) familyChinese ??= text;
      } else {
        if (isEnglish) typographicEnglish ??= text;
        if (isChinese) typographicChinese ??= text;
      }
    }

    final family =
        familyEnglish ?? typographicEnglish ?? familyAny ?? familyChinese;
    if (family == null || family.isEmpty) return null;
    final localized = familyChinese ?? typographicChinese;
    final label = localized == null || localized == family ? family : localized;
    return _FaceName(family: family, label: label);
  }

  static String _decodeUtf16Be(Uint8List bytes, int start, int end) {
    final buffer = StringBuffer();
    for (var i = start; i + 1 < end; i += 2) {
      final unit = (bytes[i] << 8) | bytes[i + 1];
      if (unit == 0) continue;
      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }
}

class _FaceName {
  const _FaceName({required this.family, required this.label});

  final String family;
  final String label;
}
