import 'dart:typed_data';

import 'package:shengwuji_desktop/services/clipboard_reader.dart';

/// 测试用剪贴板：按需返回位图、文字或图片文件路径。
class FakeClipboard implements ClipboardReader {
  FakeClipboard({this.image, this.text, this.paths = const []});

  Uint8List? image;
  String? text;
  List<String> paths;

  @override
  Future<Uint8List?> readImage() async => image;

  @override
  Future<List<String>> readImageFilePaths() async => paths;

  @override
  Future<String?> readText() async => text;
}
