import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shengwuji_desktop/data/image_payload.dart';
import 'package:shengwuji_desktop/data/note_store.dart';
import 'package:shengwuji_desktop/models/note.dart';

void main() {
  late Directory dir;
  late NoteStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shengwuji_store_test_');
    store = NoteStore(rootDir: dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('写入后读回，字段与未知字段都保留', () async {
    final note = Note.fromJson({
      'uuid': 'a',
      'content': '第一条',
      'created_at': '2026-10-22T09:30:00.000',
      'audio': 'a.m4a',
      'locked': 1,
      'tag': 'idea',
      'images': ['x.png'],
      'custom': 'keep-me',
    });
    await store.writeAll([note]);

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.uuid, 'a');
    expect(loaded.single.content, '第一条');
    expect(loaded.single.images, ['x.png']);
    expect(loaded.single.tag, 'idea');
    final written = loaded.single.toJson();
    expect(written['audio'], 'a.m4a');
    expect(written['locked'], 1);
    expect(written['custom'], 'keep-me');
    expect(written['updated_at'], isNotNull);
  });

  test('单条坏行跳过，其余笔记照常读出', () async {
    await dir.create(recursive: true);
    await store.notesFile.writeAsString(
      jsonEncode([
        {
          'uuid': 'ok',
          'content': '正常',
          'created_at': '2026-10-22T09:30:00',
        },
        {'content': '缺 uuid'},
        'not-a-map',
        {'uuid': 'ok2', 'content': '也正常'},
      ]),
    );

    final loaded = await store.load();
    expect(loaded.map((note) => note.uuid), ['ok', 'ok2']);
    expect(store.notesFile.existsSync(), isTrue);
  });

  test('整份 JSON 损坏时留档并且不覆盖', () async {
    await dir.create(recursive: true);
    await store.notesFile.writeAsString('{broken');

    final loaded = await store.load();
    expect(loaded, isEmpty);
    expect(store.notesFile.existsSync(), isFalse);
    final backups = dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('notes.corrupt-'))
        .toList();
    expect(backups, hasLength(1));
  });

  test('PNG 原样保存，BMP 转为 PNG', () async {
    final image = img.Image(width: 4, height: 4);
    final png = Uint8List.fromList(img.encodePng(image));
    final bmp = Uint8List.fromList(img.encodeBmp(image));

    final pngName = await store.saveImage(png);
    final bmpName = await store.saveImage(bmp);

    expect(pngName, endsWith('.png'));
    expect(bmpName, endsWith('.png'));
    expect(store.imageFile(pngName).readAsBytesSync(), png);

    final converted = store.imageFile(bmpName).readAsBytesSync();
    expect(detectImageExtension(converted), 'png');
  });

  test('无法识别的字节抛 UnsupportedImageException', () async {
    await expectLater(
      store.saveImage(Uint8List.fromList([1, 2, 3, 4])),
      throwsA(isA<UnsupportedImageException>()),
    );
  });

  test('图片文件名不会被路径穿越', () async {
    await store.writeAll(const []);
    final image = img.Image(width: 2, height: 2);
    final name = await store.saveImage(
      Uint8List.fromList(img.encodePng(image)),
    );

    expect(store.imageFile('../$name').path, store.imageFile(name).path);
    await store.deleteImage('../notes.json');
    expect(store.notesFile.existsSync(), isTrue);
    expect(store.imageFile(name).existsSync(), isTrue);
  });

  test('deleteImages 清掉附件', () async {
    final image = img.Image(width: 2, height: 2);
    final name = await store.saveImage(
      Uint8List.fromList(img.encodePng(image)),
    );
    expect(store.imageFile(name).existsSync(), isTrue);
    await store.deleteImages([name]);
    expect(store.imageFile(name).existsSync(), isFalse);
  });
}
