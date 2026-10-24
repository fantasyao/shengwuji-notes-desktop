import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shengwuji_desktop/data/note_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shengwuji_migration_test_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void writeImages() {
    final images = Directory(p.join(dir.path, 'images'))..createSync();
    File(
      p.join(images.path, 'a.png'),
    ).writeAsBytesSync(img.encodePng(img.Image(width: 3, height: 3)));
  }

  void writeNotesJson(Object? data) {
    File(
      p.join(dir.path, 'notes.json'),
    ).writeAsStringSync(data is String ? data : jsonEncode(data));
  }

  Future<Database> openDatabase() {
    return databaseFactoryFfi.openDatabase(
      p.join(dir.path, 'shengwuji.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
  }

  test('notes.json 迁入 SQLite：时间、未知字段、共享图片与留档', () async {
    writeImages();
    writeNotesJson([
      {
        'uuid': 'a',
        'content': '第一条',
        'created_at': '2026-10-22T09:30:00.000',
        'tag': 'idea',
        'archived': 1,
        'locked': true,
        'sort_order': 2,
        'images': ['a.png', 'missing.png'],
        'audio': 'a.m4a',
        'custom': {'x': 1},
      },
      {
        'uuid': 'b',
        'content': '第二条',
        'created_at': 'not-a-date',
        'updated_at': '2026-10-21T08:00:00.000Z',
        'images': ['a.png'],
      },
      {'content': '缺 uuid'},
      'not-a-map',
    ]);

    final store = NoteStore(rootDir: dir);
    addTearDown(store.close);
    final notes = await store.load();

    expect(store.isLegacyFallback, isFalse);
    expect(notes.map((note) => note.uuid), ['a', 'b']);

    final first = notes.first;
    expect(first.content, '第一条');
    expect(first.tag, 'idea');
    expect(first.archived, isTrue);
    expect(first.images, hasLength(1));
    expect(
      first.createdAt.toUtc().millisecondsSinceEpoch,
      DateTime.parse('2026-10-22T09:30:00.000').toUtc().millisecondsSinceEpoch,
    );
    expect(first.updatedAt, first.createdAt);
    expect(first.raw['audio'], 'a.m4a');
    expect(first.raw['custom'], {'x': 1});
    expect(first.raw['locked'], 1);
    expect(first.raw['sort_order'], 2);

    final second = notes.last;
    final expectedSecond = DateTime.parse('2026-10-21T08:00:00.000Z');
    expect(
      second.createdAt.toUtc().millisecondsSinceEpoch,
      expectedSecond.millisecondsSinceEpoch,
    );
    expect(second.updatedAt, second.createdAt);
    expect(second.images, first.images);

    expect(store.imageFile(first.images.single).existsSync(), isTrue);
    final blobs = Directory(
      p.join(dir.path, 'blobs'),
    ).listSync(recursive: true).whereType<File>().toList();
    expect(blobs, hasLength(1));

    final legacy = Directory(
      p.join(dir.path, 'legacy'),
    ).listSync().whereType<Directory>().single;
    expect(File(p.join(legacy.path, 'notes.json')).existsSync(), isTrue);
    expect(File(p.join(legacy.path, 'images', 'a.png')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'notes.json')).existsSync(), isFalse);
    expect(Directory(p.join(dir.path, 'images')).existsSync(), isFalse);

    await store.close();
    final db = await openDatabase();
    try {
      final meta = {
        for (final row in await db.query('app_meta'))
          row['key'] as String: row['value'],
      };
      expect(meta['legacy_migrated_at'], isNotNull);
      expect(meta['legacy_note_count'], '2');
      expect(meta['legacy_attachment_count'], '2');
      expect(meta['legacy_missing_images'], '1');
      expect(meta['data_revision'], '1');
    } finally {
      await db.close();
    }

    final reopened = NoteStore(rootDir: dir);
    addTearDown(reopened.close);
    expect(await reopened.load(), hasLength(2));
    expect(reopened.isLegacyFallback, isFalse);
  });

  test('损坏的 notes.json 不迁库，进入兼容模式并留档', () async {
    writeNotesJson('{broken');

    final store = NoteStore(rootDir: dir);
    addTearDown(store.close);
    expect(await store.load(), isEmpty);
    expect(store.isLegacyFallback, isTrue);
    expect(File(p.join(dir.path, 'shengwuji.db')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'notes.json')).existsSync(), isFalse);

    final corrupt = dir
        .listSync()
        .whereType<File>()
        .where((file) => p.basename(file.path).startsWith('notes.corrupt-'))
        .toList();
    expect(corrupt, hasLength(1));
  });

  test('顶层不是数组时同样回退兼容模式', () async {
    writeNotesJson({'uuid': 'a'});

    final store = NoteStore(rootDir: dir);
    addTearDown(store.close);
    expect(await store.load(), isEmpty);
    expect(store.isLegacyFallback, isTrue);
    expect(File(p.join(dir.path, 'shengwuji.db')).existsSync(), isFalse);
  });

  test('空 notes.json 也能建库并留档', () async {
    writeNotesJson('   ');

    final store = NoteStore(rootDir: dir);
    addTearDown(store.close);
    expect(await store.load(), isEmpty);
    expect(store.isLegacyFallback, isFalse);
    expect(File(p.join(dir.path, 'shengwuji.db')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'notes.json')).existsSync(), isFalse);
    expect(Directory(p.join(dir.path, 'legacy')).existsSync(), isTrue);
  });
}
