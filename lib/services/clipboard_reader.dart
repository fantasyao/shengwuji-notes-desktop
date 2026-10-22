import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;

/// 剪贴板读取抽象：编辑器依赖接口，测试可以注入假实现，避免调用原生通道。
abstract interface class ClipboardReader {
  /// 剪贴板里的位图（Windows 上来自 CF_DIB，返回 BMP 字节）。
  Future<Uint8List?> readImage();

  /// 在资源管理器里复制图片文件时，剪贴板给的是文件路径列表。
  Future<List<String>> readImageFilePaths();

  /// 纯文本；用于 Ctrl+V 时判断是否应让文本框正常粘贴文字。
  Future<String?> readText();
}

class SystemClipboardReader implements ClipboardReader {
  const SystemClipboardReader();

  @override
  Future<Uint8List?> readImage() async {
    try {
      return await Pasteboard.image;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<String>> readImageFilePaths() async {
    try {
      return await Pasteboard.files();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String?> readText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } catch (_) {
      return null;
    }
  }
}

const Set<String> imageFileExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
};

bool looksLikeImageFile(String path) {
  final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
  return imageFileExtensions.contains(extension);
}

Future<List<Uint8List>> readClipboardFiles(List<String> paths) async {
  final images = <Uint8List>[];
  for (final path in paths) {
    if (!looksLikeImageFile(path)) continue;
    final file = File(path);
    try {
      if (await file.exists()) {
        images.add(await file.readAsBytes());
      }
    } on FileSystemException {
      // 单个文件读失败不影响其他图片。
    }
  }
  return images;
}
