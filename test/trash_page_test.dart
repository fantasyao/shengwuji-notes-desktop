import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/models/note.dart';
import 'package:shengwuji_desktop/pages/notes_page.dart';
import 'package:shengwuji_desktop/state/notes_controller.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

import 'support/memory_note_store.dart';

void main() {
  late Directory dir;
  late MemoryNoteStore store;
  late NotesController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shengwuji_trash_test_');
    store = MemoryNoteStore(rootDir: dir);
    controller = NotesController(store);
    await controller.load();
  });

  tearDown(() async {
    controller.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Note makeNote(
    String uuid,
    String content,
    DateTime createdAt, {
    bool archived = false,
  }) {
    return Note(
      uuid: uuid,
      content: content,
      createdAt: createdAt,
      updatedAt: createdAt,
      archived: archived,
    );
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NotesHomePage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTrash(WidgetTester tester) async {
    await tester.tap(find.byTooltip('回收站'));
    await tester.pumpAndSettle();
  }

  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('主页只统计未归档笔记，回收站入口展示归档内容', (tester) async {
    final now = DateTime(2026, 10, 22, 10);
    await store.writeAll([
      makeNote('active', '还在列表', now),
      makeNote(
        'gone',
        '已在回收站',
        now.subtract(const Duration(minutes: 1)),
        archived: true,
      ),
    ]);
    await controller.load();
    await pumpHome(tester);

    expect(find.text('共 1 条笔记'), findsOneWidget);
    expect(find.text('还在列表'), findsOneWidget);
    expect(find.text('已在回收站'), findsNothing);

    await openTrash(tester);
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('已在回收站'), findsOneWidget);
    expect(find.text('还在列表'), findsNothing);
  });

  testWidgets('回收站里恢复笔记后回到主列表', (tester) async {
    final now = DateTime(2026, 10, 22, 10);
    await store.writeAll([makeNote('gone', '待恢复', now, archived: true)]);
    await controller.load();
    await pumpHome(tester);
    await openTrash(tester);

    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(controller.archivedNotes, isEmpty);
    expect(controller.activeNotes.single.uuid, 'gone');
    expect(find.text('回收站是空的'), findsOneWidget);

    await tester.tap(find.byTooltip('返回 (Esc)'));
    await tester.pumpAndSettle();
    expect(find.text('待恢复'), findsOneWidget);
    expect(find.text('共 1 条笔记'), findsOneWidget);
  });

  testWidgets('永久删除与清空回收站都会移除笔记', (tester) async {
    final now = DateTime(2026, 10, 22, 10);
    await store.writeAll([
      makeNote('one', '永久删除我', now, archived: true),
      makeNote(
        'two',
        '一起清空',
        now.subtract(const Duration(minutes: 1)),
        archived: true,
      ),
    ]);
    await controller.load();
    await pumpHome(tester);
    await openTrash(tester);

    await tester.tap(find.byTooltip('永久删除').first);
    await tester.pumpAndSettle();
    expect(find.text('永久删除这条笔记？'), findsOneWidget);
    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();

    expect(controller.archivedNotes.single.uuid, 'two');
    expect(find.text('永久删除我'), findsNothing);

    await tester.tap(find.text('清空回收站'));
    await tester.pumpAndSettle();
    expect(find.text('清空回收站？'), findsOneWidget);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(controller.notes, isEmpty);
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  testWidgets('回收站支持多选后批量永久删除', (tester) async {
    final now = DateTime(2026, 10, 22, 10);
    await store.writeAll([
      makeNote('one', '多选一', now, archived: true),
      makeNote(
        'two',
        '多选二',
        now.subtract(const Duration(minutes: 1)),
        archived: true,
      ),
      makeNote(
        'three',
        '留下我',
        now.subtract(const Duration(minutes: 2)),
        archived: true,
      ),
    ]);
    await controller.load();
    await pumpHome(tester);
    await openTrash(tester);

    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 条'), findsOneWidget);

    await tester.tap(find.text('多选一'));
    await tester.tap(find.text('多选二'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 条'), findsOneWidget);

    await tester.tap(find.text('删除选中 (2)'));
    await tester.pumpAndSettle();
    expect(find.text('永久删除选中的 2 条笔记？'), findsOneWidget);
    await tester.tap(find.text('永久删除'));
    await settleIo(tester);

    expect(controller.archivedNotes.single.uuid, 'three');
    expect(find.text('多选一'), findsNothing);
    expect(find.text('留下我'), findsOneWidget);
    expect(find.text('多选'), findsOneWidget);
  });

  testWidgets('回收站全选后可以一次删除全部', (tester) async {
    final now = DateTime(2026, 10, 22, 10);
    await store.writeAll([
      makeNote('one', '全部一', now, archived: true),
      makeNote(
        'two',
        '全部二',
        now.subtract(const Duration(minutes: 1)),
        archived: true,
      ),
    ]);
    await controller.load();
    await pumpHome(tester);
    await openTrash(tester);

    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 条'), findsOneWidget);

    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 条'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 条'), findsOneWidget);

    await tester.tap(find.text('删除选中 (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除'));
    await settleIo(tester);

    expect(controller.notes, isEmpty);
    expect(find.text('回收站是空的'), findsOneWidget);
  });
}
