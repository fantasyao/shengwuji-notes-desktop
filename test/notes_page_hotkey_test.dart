import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/pages/notes_page.dart';
import 'package:shengwuji_desktop/state/notes_controller.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

import 'support/memory_note_store.dart';

void main() {
  late Directory dir;
  late NotesController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shengwuji_home_test_');
    controller = NotesController(MemoryNoteStore(rootDir: dir));
    await controller.load();
  });

  tearDown(() async {
    controller.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('头部展示快速记录快捷键并提供设置入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var settingsOpened = 0;
    var quickOpened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NotesHomePage(
          controller: controller,
          hotkeyLabel: 'Ctrl + Alt + Space',
          onOpenSettings: () => settingsOpened++,
          onQuickCapture: () => quickOpened++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Ctrl + Alt + Space 快速记录 · Ctrl+N 新建 · Ctrl+F 搜索'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('设置快捷键'));
    expect(settingsOpened, 1);

    await tester.tap(find.byTooltip('快速记录 (Ctrl + Alt + Space)'));
    expect(quickOpened, 1);
  });

  testWidgets('放大后逻辑宽度变窄时头部收成紧凑样式', (tester) async {
    await tester.binding.setSurfaceSize(const Size(586, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NotesHomePage(
          controller: controller,
          hotkeyLabel: 'Ctrl + Alt + Space',
          onOpenSettings: () {},
          onQuickCapture: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('声物记'), findsOneWidget);
    expect(find.text('电脑版 · 本地笔记'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    // 紧凑头部把按钮文字收成图标；页面空状态里的「新建笔记」按钮仍在。
    expect(find.text('新建笔记'), findsOneWidget);
    expect(find.byTooltip('新建笔记 (Ctrl+N)'), findsOneWidget);
  });
}
