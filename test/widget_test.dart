import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shengwuji_desktop/models/note.dart';
import 'package:shengwuji_desktop/pages/notes_page.dart';
import 'package:shengwuji_desktop/state/notes_controller.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

import 'support/fake_clipboard.dart';
import 'support/memory_note_store.dart';

void main() {
  late Directory dir;
  late MemoryNoteStore store;
  late NotesController controller;
  late FakeClipboard clipboard;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shengwuji_widget_test_');
    store = MemoryNoteStore(rootDir: dir);
    controller = NotesController(store);
    await controller.load();
    clipboard = FakeClipboard();
  });

  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上测试结束时文件句柄可能还没释放，清理失败不影响断言。
    }
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NotesHomePage(controller: controller, clipboard: clipboard),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settleIo(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 700));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
  }

  Note makeNote(String uuid, String content, DateTime createdAt) {
    return Note(
      uuid: uuid,
      content: content,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
  }

  testWidgets('空状态展示并显示总数', (tester) async {
    await pumpHome(tester);
    expect(find.text('还没有笔记'), findsOneWidget);
    expect(find.text('共 0 条笔记'), findsOneWidget);
    expect(find.text('新建笔记'), findsWidgets);
  });

  testWidgets('新建笔记时输入框自动获得光标', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.text('新建笔记').first);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode?.hasPrimaryFocus, isTrue);
  });

  testWidgets('新建笔记、自动保存、返回后出现卡片', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.text('新建笔记').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '今天买牛奶\n顺便买鸡蛋');
    await settleIo(tester);

    expect(controller.notes, hasLength(1));
    expect(controller.notes.single.content, contains('牛奶'));

    await tester.tap(find.text('完成'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('今天买牛奶'), findsOneWidget);
    expect(find.text('顺便买鸡蛋'), findsOneWidget);
    expect(find.text('共 1 条笔记'), findsOneWidget);

    final loaded = await store.load();
    expect(loaded.single.content, '今天买牛奶\n顺便买鸡蛋');
  });

  testWidgets('搜索按正文过滤', (tester) async {
    final now = DateTime(2026, 10, 22, 10);
    await store.writeAll([
      makeNote('apple', '苹果笔记', now),
      makeNote('banana', '香蕉笔记', now.subtract(const Duration(minutes: 1))),
    ]);
    await controller.load();
    await pumpHome(tester);
    expect(find.text('苹果笔记'), findsOneWidget);
    expect(find.text('香蕉笔记'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '苹果');
    await tester.pump();

    expect(find.text('苹果笔记'), findsOneWidget);
    expect(find.text('香蕉笔记'), findsNothing);
    expect(find.text('找到 1 条'), findsOneWidget);
  });

  testWidgets('Ctrl+V 把剪贴板位图加成附件并保存', (tester) async {
    clipboard.image = Uint8List.fromList(
      img.encodePng(img.Image(width: 8, height: 8)),
    );
    await pumpHome(tester);
    await tester.tap(find.text('新建笔记').first);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleIo(tester);

    expect(controller.notes, hasLength(1));
    final images = controller.notes.single.images;
    expect(images, hasLength(1));
    expect(store.imageFile(images.single).existsSync(), isTrue);
  });

  testWidgets('在编辑页删除笔记后移入回收站', (tester) async {
    final now = DateTime(2026, 10, 22, 10);
    await store.writeAll([makeNote('a', '待删除笔记', now)]);
    await controller.load();
    await pumpHome(tester);

    await tester.tap(find.text('待删除笔记'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('移入回收站'));
    await tester.pumpAndSettle();
    expect(find.text('移入回收站？'), findsNothing);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有笔记'), findsOneWidget);
    expect(controller.activeNotes, isEmpty);
    expect(controller.archivedNotes.single.uuid, 'a');
  });

  testWidgets('卡片悬停后点复制，正文写入剪贴板并提示', (tester) async {
    final now = DateTime(2026, 10, 23, 12);
    await store.writeAll([makeNote('c', '标题行\n正文内容', now)]);
    await controller.load();
    await pumpHome(tester);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('标题行')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('复制正文'));
    await tester.pumpAndSettle();

    expect(copied, '标题行\n正文内容');
    expect(find.text('正文已复制'), findsOneWidget);
  });
}
