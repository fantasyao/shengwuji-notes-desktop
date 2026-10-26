import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shengwuji_desktop/services/system_fonts.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shengwuji_fonts_test_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('读取 ttf 的英文家族名与中文展示名', () async {
    final file = File(p.join(dir.path, 'test_sans.ttf'))
      ..writeAsBytesSync(buildFace(family: 'Test Sans', localized: '测试黑体'));

    final fonts = await SystemFontCatalog(fontDirectories: [dir]).load();

    expect(fonts, hasLength(1));
    expect(fonts.single.family, 'Test Sans');
    expect(fonts.single.label, '测试黑体');
    expect(fonts.single.path, file.path);
  });

  test('ttc 里包含的多个字体都会列出来', () async {
    File(p.join(dir.path, 'bundle.ttc')).writeAsBytesSync(
      buildTtc([
        (base) => buildFace(family: 'Zed Serif', localized: '测试宋体', base: base),
        (base) => buildFace(family: 'Alpha Kai', localized: '测试楷体', base: base),
      ]),
    );

    final fonts = await SystemFontCatalog(fontDirectories: [dir]).load();

    expect(fonts.map((font) => font.family), ['Alpha Kai', 'Zed Serif']);
    expect(fonts.map((font) => font.label), ['测试楷体', '测试宋体']);
  });

  test('同名字体只保留一份', () async {
    File(
      p.join(dir.path, 'regular.ttf'),
    ).writeAsBytesSync(buildFace(family: 'Test Sans', localized: '测试黑体'));
    File(
      p.join(dir.path, 'bold.ttf'),
    ).writeAsBytesSync(buildFace(family: 'Test Sans', localized: '测试黑体粗体'));

    final fonts = await SystemFontCatalog(fontDirectories: [dir]).load();

    expect(fonts, hasLength(1));
    expect(fonts.single.family, 'Test Sans');
  });

  test('没有 name 表的文件会被跳过且不影响其它字体', () async {
    File(p.join(dir.path, 'broken.ttf')).writeAsBytesSync([1, 2, 3, 4]);
    File(p.join(dir.path, 'readme.txt')).writeAsStringSync('not a font');
    File(
      p.join(dir.path, 'good.ttf'),
    ).writeAsBytesSync(buildFace(family: 'Good Font', localized: '可用字体'));

    final fonts = await SystemFontCatalog(fontDirectories: [dir]).load();

    expect(fonts, hasLength(1));
    expect(fonts.single.family, 'Good Font');
  });

  test('没有中文本地化名时展示英文名', () async {
    File(p.join(dir.path, 'latin.ttf')).writeAsBytesSync(
      buildFace(family: 'Only English', localized: 'Only English'),
    );

    final fonts = await SystemFontCatalog(fontDirectories: [dir]).load();

    expect(fonts.single.label, 'Only English');
  });

  test('加载结果会缓存，重复打开设置不重扫目录', () async {
    File(
      p.join(dir.path, 'cached.ttf'),
    ).writeAsBytesSync(buildFace(family: 'Cached Font', localized: '缓存字体'));
    final catalog = SystemFontCatalog(fontDirectories: [dir]);

    final first = await catalog.load();
    File(
      p.join(dir.path, 'later.ttf'),
    ).writeAsBytesSync(buildFace(family: 'Later Font', localized: '后来字体'));
    final second = await catalog.load();

    expect(identical(first, second), isTrue);
    expect(second, hasLength(1));
  });
}

/// 生成一个只含 `name` 表的最小 sfnt 字体，供解析测试使用。
///
/// [base] 是字体在文件里的起始位置；ttc 里的表偏移按整个文件计算，
/// 所以要把它带进来。
Uint8List buildFace({
  required String family,
  required String localized,
  int base = 0,
}) {
  final nameTable = _buildNameTable(
    records: [
      _NameRecord(
        platform: 3,
        encoding: 1,
        language: 0x0409,
        nameId: 1,
        text: family,
      ),
      _NameRecord(
        platform: 3,
        encoding: 1,
        language: 0x0804,
        nameId: 1,
        text: localized,
      ),
    ],
  );
  final header = ByteData(12)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, 1)
    ..setUint16(6, 16);
  final record = ByteData(16)
    ..setUint32(0, 0x6E616D65) // 'name'
    ..setUint32(8, base + 28)
    ..setUint32(12, nameTable.length);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...record.buffer.asUint8List(),
    ...nameTable,
  ]);
}

Uint8List buildTtc(List<Uint8List Function(int base)> faces) {
  final headerSize = 12 + faces.length * 4;
  final header = ByteData(headerSize)
    ..setUint32(0, 0x74746366) // 'ttcf'
    ..setUint32(4, 0x00010000)
    ..setUint32(8, faces.length);
  final parts = <Uint8List>[];
  var cursor = headerSize;
  for (var i = 0; i < faces.length; i++) {
    header.setUint32(12 + i * 4, cursor);
    final face = faces[i](cursor);
    parts.add(face);
    cursor += face.length;
  }
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    for (final part in parts) ...part,
  ]);
}

Uint8List _buildNameTable({required List<_NameRecord> records}) {
  final strings = [for (final record in records) _utf16be(record.text)];
  final headerSize = 6 + records.length * 12;
  final total =
      headerSize + strings.fold<int>(0, (sum, bytes) => sum + bytes.length);
  final bytes = Uint8List(total);
  final data = ByteData.sublistView(bytes)
    ..setUint16(0, 0)
    ..setUint16(2, records.length)
    ..setUint16(4, headerSize);
  var offset = 0;
  for (var i = 0; i < records.length; i++) {
    final record = records[i];
    final base = 6 + i * 12;
    data
      ..setUint16(base, record.platform)
      ..setUint16(base + 2, record.encoding)
      ..setUint16(base + 4, record.language)
      ..setUint16(base + 6, record.nameId)
      ..setUint16(base + 8, strings[i].length)
      ..setUint16(base + 10, offset);
    bytes.setRange(
      headerSize + offset,
      headerSize + offset + strings[i].length,
      strings[i],
    );
    offset += strings[i].length;
  }
  return bytes;
}

Uint8List _utf16be(String text) {
  final units = text.codeUnits;
  final bytes = Uint8List(units.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < units.length; i++) {
    data.setUint16(i * 2, units[i]);
  }
  return bytes;
}

class _NameRecord {
  const _NameRecord({
    required this.platform,
    required this.encoding,
    required this.language,
    required this.nameId,
    required this.text,
  });

  final int platform;
  final int encoding;
  final int language;
  final int nameId;
  final String text;
}
