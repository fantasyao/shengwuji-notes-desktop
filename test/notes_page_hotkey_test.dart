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
}
