import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 规范化后的图片数据：可直接落盘，扩展名与字节内容一致。
class ImagePayload {
  const ImagePayload({required this.bytes, required this.extension});

  final Uint8List bytes;
  final String extension;
}

class UnsupportedImageException implements Exception {
  const UnsupportedImageException([this.message = '不支持的图片格式']);

  final String message;

  @override
  String toString() => message;
}

/// 图片过大时抛出，避免一张截图把本地存储撑爆。
class ImageTooLargeException implements Exception {
  const ImageTooLargeException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() => '图片超过 ${maxBytes ~/ (1024 * 1024)} MB';
}

/// 识别图片格式；无法识别返回 null。
String? detectImageExtension(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'jpg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'webp';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return 'bmp';
  }
  return null;
}

/// Windows 剪贴板位图拿到的是 BMP（未压缩、体积大），统一转成 PNG 再落盘。
/// 其他已识别格式原样保存，避免无谓的重新编码损失与耗时。
ImagePayload normalizeImage(Uint8List bytes) {
  final extension = detectImageExtension(bytes);
  if (extension == 'bmp') {
    final decoded = img.decodeBmp(bytes) ?? img.decodeImage(bytes);
    if (decoded == null) {
      throw const UnsupportedImageException('剪贴板图片解析失败');
    }
    return ImagePayload(
      bytes: Uint8List.fromList(img.encodePng(decoded)),
      extension: 'png',
    );
  }
  if (extension != null) {
    return ImagePayload(bytes: bytes, extension: extension);
  }

  // 扩展名未知时再尝试解码一次，能解就转 PNG，否则按不支持处理。
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const UnsupportedImageException();
  }
  return ImagePayload(
    bytes: Uint8List.fromList(img.encodePng(decoded)),
    extension: 'png',
  );
}
