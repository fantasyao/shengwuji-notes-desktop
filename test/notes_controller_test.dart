import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shengwuji_desktop/data/note_store.dart';
import 'package:shengwuji_desktop/models/note.dart';
import 'package:shengwuji_desktop/state/notes_controller.dart';

void main() {
  late Directory dir;
  late NoteStore store;
  late NotesController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shengwuji_controller_test_');
    store = NoteStore(rootDir: dir);
    controller = NotesController(store);
    await controller.load();
  });

  tearDown(() async {
    controller.dispose();
    await store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Note note(String uuid, String content, DateTime createdAt) {
    return Note(
      uuid: uuid,
      content: content,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
  }

  Uint8List pngBytes() {
    return Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
  }

  test('按创建时间倒序，搜索过滤正文', () async {
    final old = note('old', '苹果 笔记', DateTime(2026, 10, 20));
    final fresh = note('fresh', '香蕉 笔记', DateTime(2026, 10, 22));
    await controller.upsert(old);
    await controller.upsert(fresh);

    expect(controller.notes.map((item) => item.uuid), ['fresh', 'old']);
    controller.setQuery('苹果');
    expect(controller.visibleNotes.map((item) => item.uuid), ['old']);
    controller.setQuery('  ');
    expect(controller.visibleNotes, hasLength(2));
  });

  test('upsert 落盘，重开控制器仍能读到', () async {
    await controller.upsert(note('a', '持久化', DateTime(2026, 10, 22)));

    final reopened = NotesController(store);
    await reopened.load();
    expect(reopened.notes.single.content, '持久化');
    reopened.dispose();
  });

  test('移除图片时删除对应文件', () async {
    final name = await store.saveImage(pngBytes());
    final withImage = note(
      'a',
      '带图',
      DateTime(2026, 10, 22),
    ).copyWith(images: [name]);
    await controller.upsert(withImage);
    expect(store.imageFile(name).existsSync(), isTrue);

    await controller.upsert(withImage.copyWith(images: const []));
    expect(store.imageFile(name).existsSync(), isFalse);
  });

  test('删除先移入回收站，图片保留且可以恢复', () async {
    final name = await store.saveImage(pngBytes());
    final withImage = note(
      'a',
      '待删除',
      DateTime(2026, 10, 22),
    ).copyWith(images: [name]);
    final other = note('b', '其他笔记', DateTime(2026, 10, 21));
    await controller.upsert(withImage);
    await controller.upsert(other);

    await controller.moveToTrash(withImage);
    expect(controller.activeNotes.map((item) => item.uuid), ['b']);
    expect(controller.archivedNotes.map((item) => item.uuid), ['a']);
    expect(controller.visibleNotes.map((item) => item.uuid), ['b']);
    expect(store.imageFile(name).existsSync(), isTrue);

    final reopened = NotesController(store);
    await reopened.load();
    expect(reopened.archivedNotes.single.uuid, 'a');
    reopened.dispose();

    await controller.restore(controller.archivedNotes.single);
    expect(controller.activeNotes.map((item) => item.uuid), ['a', 'b']);
    expect(controller.archivedNotes, isEmpty);
    expect(store.imageFile(name).existsSync(), isTrue);
  });

  test('永久删除与清空回收站会清理图片', () async {
    final keep = await store.saveImage(pngBytes());
    final trashed = await store.saveImage(
      Uint8List.fromList(img.encodePng(img.Image(width: 3, height: 3))),
    );
    await controller.upsert(
      note('keep', '保留', DateTime(2026, 10, 22)).copyWith(images: [keep]),
    );
    await controller.upsert(
      note('trash', '待删', DateTime(2026, 10, 21)).copyWith(images: [trashed]),
    );
    await controller.moveToTrash(
      controller.notes.firstWhere((item) => item.uuid == 'trash'),
    );

    await controller.deletePermanently(controller.archivedNotes.single);
    expect(controller.notes.map((item) => item.uuid), ['keep']);
    expect(store.imageFile(trashed).existsSync(), isFalse);
    expect(store.imageFile(keep).existsSync(), isTrue);

    final more = await store.saveImage(
      Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
    );
    await controller.upsert(
      note('more', '再删', DateTime(2026, 10, 20)).copyWith(images: [more]),
    );
    await controller.moveToTrash(
      controller.notes.firstWhere((item) => item.uuid == 'more'),
    );
    await controller.emptyTrash();

    expect(controller.notes.map((item) => item.uuid), ['keep']);
    expect(store.imageFile(more).existsSync(), isFalse);
    expect(store.imageFile(keep).existsSync(), isTrue);
  });

  test('空白草稿丢弃时清理已落盘的图片', () async {
    final name = await store.saveImage(pngBytes());
    final draft = controller.createDraft().copyWith(images: [name]);

    await controller.discardDraft(draft);
    expect(store.imageFile(name).existsSync(), isFalse);
  });

  test('已保存的草稿不会被 discardDraft 清掉图片', () async {
    final name = await store.saveImage(pngBytes());
    final draft = controller.createDraft().copyWith(images: [name]);
    await controller.upsert(draft);

    await controller.discardDraft(draft);
    expect(store.imageFile(name).existsSync(), isTrue);
  });

  test('createDraft 生成唯一 uuid 且内容为空', () {
    final a = controller.createDraft();
    final b = controller.createDraft();
    expect(a.uuid, isNot(b.uuid));
    expect(a.content, isEmpty);
    expect(a.images, isEmpty);
  });
}
