import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shengwuji_desktop/data/data_location.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('shengwuji_location_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('hasExistingNotes 只认非空笔记列表', () async {
    final dir = Directory(p.join(root.path, 'target'))..createSync();
    expect(await hasExistingNotes(dir), isFalse);

    final notes = File(p.join(dir.path, 'notes.json'));
    notes.writeAsStringSync('');
    expect(await hasExistingNotes(dir), isFalse);

    notes.writeAsStringSync('[]');
    expect(await hasExistingNotes(dir), isFalse);

    notes.writeAsStringSync('[{"uuid":"a","content":"hi"}]');
    expect(await hasExistingNotes(dir), isTrue);
  });

  test('notes.json 损坏时按“已有数据”处理，避免直接覆盖', () async {
    final dir = Directory(p.join(root.path, 'broken'))..createSync();
    File(p.join(dir.path, 'notes.json')).writeAsStringSync('{broken');
    expect(await hasExistingNotes(dir), isTrue);
  });

  test('复制笔记与图片到新目录，不复制设置，原目录保留', () async {
    final from = Directory(p.join(root.path, 'from'))..createSync();
    final to = Directory(p.join(root.path, 'to'))..createSync();
    File(p.join(from.path, 'notes.json')).writeAsStringSync('[]');
    File(p.join(from.path, 'settings.json')).writeAsStringSync('{}');
    final images = Directory(p.join(from.path, 'images'))..createSync();
    File(p.join(images.path, 'a.png')).writeAsBytesSync([1, 2, 3]);

    final copied = await copyNotesData(from, to);

    expect(copied, 2);
    expect(File(p.join(to.path, 'notes.json')).existsSync(), isTrue);
    expect(File(p.join(to.path, 'images', 'a.png')).existsSync(), isTrue);
    expect(File(p.join(to.path, 'settings.json')).existsSync(), isFalse);
    expect(File(p.join(from.path, 'notes.json')).existsSync(), isTrue);
    expect(File(p.join(from.path, 'images', 'a.png')).existsSync(), isTrue);
  });
}
