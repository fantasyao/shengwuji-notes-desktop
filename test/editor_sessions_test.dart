import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/models/note.dart';
import 'package:shengwuji_desktop/pages/note_editor_page.dart';
import 'package:shengwuji_desktop/pages/notes_page.dart';
import 'package:shengwuji_desktop/state/editor_sessions.dart';
import 'package:shengwuji_desktop/state/notes_controller.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

import 'support/memory_note_store.dart';

/// 主界面切到速记窗前要先把编辑页收掉：正文先落盘，再弹回首页，
/// 这样 460x400 的速记窗里只有速记页，不会带着主界面正在编辑的笔记。
void main() {
  late Directory dir;
  late MemoryNoteStore store;
  late NotesController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shengwuji_editor_sessions_');
    store = MemoryNoteStore(rootDir: dir);
    controller = NotesController(store);
    await controller.load();
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

  test('flushAll 逐个等待登记的回调，单个失败不影响其它', () async {
    final calls = <String>[];
    Future<void> failing() async {
      calls.add('失败');
      throw StateError('磁盘满了');
    }

    Future<void> ok() async => calls.add('成功');

    EditorSessions.register(failing);
    EditorSessions.register(ok);
    addTearDown(() {
      EditorSessions.unregister(failing);
      EditorSessions.unregister(ok);
    });

    await EditorSessions.flushAll();
    expect(calls, ['失败', '成功']);

    EditorSessions.unregister(ok);
    calls.clear();
    await EditorSessions.flushAll();
    expect(calls, ['失败']);
  });

  testWidgets('切到速记窗前自动落盘并收起编辑页', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final quickMode = ValueNotifier<bool>(false);
    addTearDown(quickMode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: AppTheme.light(),
        // 与 app.dart 一样：同一个导航栈，靠切换 home 在两个窗口间换页。
        home: ValueListenableBuilder<bool>(
          valueListenable: quickMode,
          builder: (context, quick, _) => quick
              ? const Scaffold(body: Center(child: Text('快速记录')))
              : NotesHomePage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建笔记').first);
    await tester.pumpAndSettle();
    expect(find.text('添加图片'), findsOneWidget);
    expect(EditorSessions.hasEditor, isTrue);

    await tester.enterText(find.byType(TextField), '主界面正在写的');
    // 只等 100ms，600ms 的自动保存还没到，验证的是切换前主动落盘。
    await tester.pump(const Duration(milliseconds: 100));

    quickMode.value = true;
    // 控制器在 setUp 里创建，写盘链属于真实 zone，假时钟下直接 await 会卡住。
    await tester.runAsync(() => closePagesAboveHome(navigatorKey.currentState!));
    await tester.pumpAndSettle();

    expect(find.text('快速记录'), findsOneWidget);
    expect(find.byType(NoteEditorPage), findsNothing);
    expect(find.text('添加图片'), findsNothing);
    expect(EditorSessions.hasEditor, isFalse);
    expect(controller.notes.single.content, '主界面正在写的');
    expect((await store.load()).single.content, '主界面正在写的');
  });

  testWidgets('编辑页正常关闭后不再登记', (tester) async {
    final now = DateTime(2026, 10, 28, 10);
    await store.writeAll([
      Note(uuid: 'n1', content: '正文', createdAt: now, updatedAt: now),
    ]);
    await controller.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NoteEditorPage(
          controller: controller,
          note: controller.notes.single,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(EditorSessions.hasEditor, isTrue);

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const SizedBox.shrink()),
    );
    await tester.pumpAndSettle();
    expect(EditorSessions.hasEditor, isFalse);
  });
}
