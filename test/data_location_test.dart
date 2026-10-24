import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shengwuji_desktop/data/data_location.dart';
import 'package:shengwuji_desktop/data/note_store.dart';
import 'package:shengwuji_desktop/models/note.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('shengwuji_location_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('hasExistingNotes 识别 JSON 与 SQLite 两种数据', () async {
    final target = Directory(p.join(root.path, 'target'))..createSync();
    expect(await hasExistingNotes(target), isFalse);

    final notes = File(p.join(target.path, 'notes.json'));
    notes.writeAsStringSync('');
    expect(await hasExistingNotes(target), isFalse);

    notes.writeAsStringSync('[]');
    expect(await hasExistingNotes(target), isFalse);

    notes.writeAsStringSync('[{"uuid":"a","content":"hi"}]');
    expect(await hasExistingNotes(target), isTrue);

    notes.writeAsStringSync('{broken');
    expect(await hasExistingNotes(target), isTrue);

    final dbDir = Directory(p.join(root.path, 'db'))..createSync();
    File(p.join(dbDir.path, 'shengwuji.db')).writeAsBytesSync([1, 2, 3]);
    expect(await hasExistingNotes(dbDir), isTrue);
  });

  test('notes.json 损坏时按“已有数据”处理，避免直接覆盖', () async {
    final dir = Directory(p.join(root.path, 'broken'))..createSync();
    File(p.join(dir.path, 'notes.json')).writeAsStringSync('{broken');
    expect(await hasExistingNotes(dir), isTrue);
  });

  test('copyTo 复制数据库与 blob，不复制设置，原目录保留', () async {
    final from = Directory(p.join(root.path, 'from'))..createSync();
    final to = Directory(p.join(root.path, 'to'))..createSync();
    final store = NoteStore(rootDir: from);
    addTearDown(store.close);

    final imageName = await store.saveImage(
      img.encodePng(img.Image(width: 2, height: 2)),
    );
    final now = DateTime(2026, 10, 22, 9, 30);
    await store.writeAll([
      Note(
        uuid: 'a',
        content: '复制我',
        images: [imageName],
        createdAt: now,
        updatedAt: now,
      ),
    ]);
    File(p.join(from.path, 'settings.json')).writeAsStringSync('{}');

    final copied = await store.copyTo(to);
    expect(copied, 2);
    expect(File(p.join(to.path, 'shengwuji.db')).existsSync(), isTrue);
    expect(File(p.join(to.path, 'settings.json')).existsSync(), isFalse);
    expect(store.imageFile(imageName).existsSync(), isTrue);

    final target = NoteStore(rootDir: to);
    addTearDown(target.close);
    final loaded = await target.load();
    expect(loaded.single.content, '复制我');
    expect(loaded.single.images, [imageName]);
    expect(target.imageFile(imageName).existsSync(), isTrue);
  });
}
