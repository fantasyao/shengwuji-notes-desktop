import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shengwuji_desktop/data/image_payload.dart';
import 'package:shengwuji_desktop/data/note_store.dart';
import 'package:shengwuji_desktop/models/note.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late NoteStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shengwuji_store_test_');
    store = NoteStore(rootDir: dir);
  });

  tearDown(() async {
    await store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Uint8List pngBytes() {
    return Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));
  }

  Note note(
    String uuid, {
    String content = '',
    List<String> images = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
    String? tag,
    bool archived = false,
    Map<String, dynamic> raw = const {},
  }) {
    final created = createdAt ?? DateTime(2026, 10, 22, 9, 30);
    return Note(
      uuid: uuid,
      content: content,
      images: images,
      createdAt: created,
      updatedAt: updatedAt ?? created,
      tag: tag,
      archived: archived,
      raw: raw,
    );
  }

  test('全新建库包含七张表与 schema 版本', () async {
    await store.load();
    await store.close();

    final db = await databaseFactoryFfi.openDatabase(
      p.join(dir.path, 'shengwuji.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final version = await db.rawQuery('PRAGMA user_version');
      expect(version.first.values.first, 1);
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      );
      expect(
        tables.map((row) => row['name']),
        containsAll([
          'app_meta',
          'notes',
          'tags',
          'note_tags',
          'attachments',
          'items',
          'tombstones',
        ]),
      );
    } finally {
      await db.close();
    }
  });

  test('写入后读回，字段与未知字段都保留', () async {
    final image = await store.saveImage(pngBytes());
    final created = DateTime(2026, 10, 22, 9, 30);
    final updated = DateTime(2026, 10, 22, 10, 15);
    await store.writeAll([
      note(
        'a',
        content: '第一条',
        images: [image],
        createdAt: created,
        updatedAt: updated,
        tag: 'idea',
        raw: {
          'audio': 'a.m4a',
          'locked': 1,
          'sort_order': 3,
          'custom': 'keep-me',
        },
      ),
    ]);

    final loaded = (await store.load()).single;
    expect(loaded.uuid, 'a');
    expect(loaded.content, '第一条');
    expect(loaded.images, [image]);
    expect(loaded.tag, 'idea');
    expect(
      loaded.createdAt.toUtc().millisecondsSinceEpoch,
      created.toUtc().millisecondsSinceEpoch,
    );
    expect(
      loaded.updatedAt.toUtc().millisecondsSinceEpoch,
      updated.toUtc().millisecondsSinceEpoch,
    );
    expect(loaded.raw['audio'], 'a.m4a');
    expect(loaded.raw['locked'], 1);
    expect(loaded.raw['sort_order'], 3);
    expect(loaded.raw['custom'], 'keep-me');
    expect(loaded.toJson()['audio'], 'a.m4a');
  });

  test('相同内容重复保存不 bump rev，内容变化才 bump', () async {
    await store.writeAll([note('a', content: '第一版')]);
    await store.writeAll([note('a', content: '第一版')]);
    await store.writeAll([note('a', content: '第二版')]);

    await store.close();
    final db = await databaseFactoryFfi.openDatabase(
      p.join(dir.path, 'shengwuji.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final row = (await db.query('notes')).single;
      expect(row['content'], '第二版');
      expect(row['rev'], 2);
    } finally {
      await db.close();
    }
  });

  test('同 uuid 重新创建会清掉旧墓碑', () async {
    await store.writeAll([note('a', content: '回来')]);
    await store.writeAll([]);
    await store.writeAll([note('a', content: '回来')]);

    await store.close();
    final db = await databaseFactoryFfi.openDatabase(
      p.join(dir.path, 'shengwuji.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      expect(await db.query('tombstones'), isEmpty);
    } finally {
      await db.close();
    }
    expect((await store.load()).single.uuid, 'a');
  });

  test('删除笔记写墓碑，附件行级联删除', () async {
    final image = await store.saveImage(pngBytes());
    await store.writeAll([
      note('a', content: '待删除', images: [image]),
    ]);
    await store.writeAll([]);

    expect(await store.load(), isEmpty);
    await store.deleteImage(image);
    expect(store.imageFile(image).existsSync(), isFalse);

    await store.close();
    final db = await databaseFactoryFfi.openDatabase(
      p.join(dir.path, 'shengwuji.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final tombstones = await db.query('tombstones');
      expect(tombstones, hasLength(1));
      expect(tombstones.single['entity'], 'note');
      expect(tombstones.single['uuid'], 'a');
      expect(tombstones.single['rev'], 2);
      final attachments = await db.query('attachments');
      expect(attachments, isEmpty);
    } finally {
      await db.close();
    }
  });

  test('相同内容只落一份 blob，引用清零后才删文件', () async {
    final bytes = pngBytes();
    final first = await store.saveImage(bytes);
    final second = await store.saveImage(bytes);
    expect(second, first);

    await store.writeAll([
      note('a', content: '甲', images: [first]),
      note('b', content: '乙', images: [second]),
    ]);
    await store.writeAll([
      note('a', content: '甲', images: [first]),
    ]);
    await store.deleteImage(first);
    expect(store.imageFile(first).existsSync(), isTrue);

    await store.writeAll([]);
    await store.deleteImage(first);
    expect(store.imageFile(first).existsSync(), isFalse);
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

  test('附件名不会穿越到数据目录之外', () async {
    final settings = File(p.join(dir.path, 'settings.json'));
    settings.writeAsStringSync('{}');

    expect(
      store.imageFile('../settings.json').path,
      store.imageFile('settings.json').path,
    );
    await store.deleteImage('../settings.json');
    expect(settings.existsSync(), isTrue);
  });

  test('deleteImages 清掉未被引用的附件', () async {
    final name = await store.saveImage(pngBytes());
    expect(store.imageFile(name).existsSync(), isTrue);
    await store.deleteImages([name]);
    expect(store.imageFile(name).existsSync(), isFalse);
  });
}
