import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/models/quick_draft.dart';
import 'package:shengwuji_desktop/pages/quick_capture_page.dart';
import 'package:shengwuji_desktop/state/notes_controller.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

import 'support/fake_clipboard.dart';
import 'support/memory_note_store.dart';

void main() {
  late Directory dir;
  late MemoryNoteStore store;
  late NotesController controller;
  late FakeClipboard clipboard;

  final Uint8List onePixelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shengwuji_quick_test_');
    store = MemoryNoteStore(rootDir: dir);
    controller = NotesController(store);
    await controller.load();
    clipboard = FakeClipboard();
  });

  tearDown(() async {
    controller.dispose();
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上测试结束时文件句柄可能还没释放，清理失败不影响断言。
    }
  });

  Future<void> pumpQuick(
    WidgetTester tester, {
    QuickDraft initialDraft = const QuickDraft(),
    int focusRequest = 0,
    ValueChanged<QuickDraft>? onChanged,
    Future<void> Function(QuickDraft draft)? onSave,
    VoidCallback? onClose,
    Future<void> Function(QuickDraft draft)? onDiscard,
    Future<void> Function(QuickDraft draft)? onOpenMain,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: QuickCapturePage(
          controller: controller,
          initialDraft: initialDraft,
          hotkeyLabel: 'Ctrl + Alt + Space',
          focusRequest: focusRequest,
          clipboard: clipboard,
          onChanged: onChanged ?? (_) {},
          onSave: onSave ?? (_) async {},
          onClose: onClose ?? () {},
          onDiscard: onDiscard ?? (_) async {},
          onOpenMain: onOpenMain ?? (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  FocusNode editorFocusNode(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).focusNode!;

  Future<void> pressPaste(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> pressCtrlD(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('空输入时保存按钮不可用', (tester) async {
    await pumpQuick(tester);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存并收起'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Ctrl+Enter 保存并清空输入', (tester) async {
    QuickDraft? saved;
    QuickDraft? changed;
    await pumpQuick(
      tester,
      onChanged: (draft) => changed = draft,
      onSave: (draft) async => saved = draft,
    );

    await tester.enterText(find.byType(TextField), '买牛奶');
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(saved?.text, '买牛奶');
    expect(changed?.text, '');
    expect(find.text('买牛奶'), findsNothing);
    expect(find.textContaining('记点什么'), findsOneWidget);
  });

  testWidgets('点击保存按钮保存当前文本', (tester) async {
    QuickDraft? saved;
    await pumpQuick(
      tester,
      initialDraft: const QuickDraft(text: '草稿保留'),
      onSave: (draft) async => saved = draft,
    );

    await tester.tap(find.text('保存并收起'));
    await tester.pumpAndSettle();

    expect(saved?.text, '草稿保留');
  });

  testWidgets('Esc 触发收起', (tester) async {
    var closed = false;
    await pumpQuick(tester, onClose: () => closed = true);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(closed, isTrue);
  });

  testWidgets('Ctrl+D 丢弃正文并收起，不留草稿', (tester) async {
    QuickDraft? discarded;
    QuickDraft? changed;
    var closed = false;
    await pumpQuick(
      tester,
      onChanged: (draft) => changed = draft,
      onDiscard: (draft) async => discarded = draft,
      onClose: () => closed = true,
    );

    await tester.enterText(find.byType(TextField), '写到一半不要了');
    await tester.pump();
    await pressCtrlD(tester);

    expect(discarded?.text, '写到一半不要了');
    expect(changed?.text, isEmpty);
    expect(find.text('写到一半不要了'), findsNothing);
    expect(find.textContaining('记点什么'), findsOneWidget);
    // 丢弃走 onDiscard 而不是 Esc 的收起通道，避免草稿留在内存。
    expect(closed, isFalse);
  });

  testWidgets('Ctrl+D 把未保存的图片一起交出去丢弃', (tester) async {
    clipboard.image = onePixelPng;
    QuickDraft? discarded;
    await pumpQuick(tester, onDiscard: (draft) async => discarded = draft);

    await pressPaste(tester);
    expect(find.byTooltip('移除图片'), findsOneWidget);

    await pressCtrlD(tester);

    expect(discarded?.images, hasLength(1));
    expect(find.byTooltip('移除图片'), findsNothing);
  });

  testWidgets('空内容时 Ctrl+D 也直接收起', (tester) async {
    var discards = 0;
    await pumpQuick(tester, onDiscard: (_) async => discards++);

    await pressCtrlD(tester);

    expect(discards, 1);
  });

  testWidgets('打开主界面时带上当前文本', (tester) async {
    QuickDraft? received;
    await pumpQuick(tester, onOpenMain: (draft) async => received = draft);

    await tester.enterText(find.byType(TextField), '要继续写的');
    await tester.pump();
    await tester.tap(find.byTooltip('打开主界面'));
    await tester.pumpAndSettle();

    expect(received?.text, '要继续写的');
  });

  testWidgets('首次呼出时光标已在输入框，无需先点一下', (tester) async {
    await pumpQuick(tester);

    expect(editorFocusNode(tester).hasPrimaryFocus, isTrue);
  });

  testWidgets('每次重新呼出都会把光标放回输入框', (tester) async {
    await pumpQuick(tester);

    editorFocusNode(tester).unfocus();
    await tester.pump();
    expect(editorFocusNode(tester).hasPrimaryFocus, isFalse);

    await pumpQuick(tester, focusRequest: 1);

    expect(editorFocusNode(tester).hasPrimaryFocus, isTrue);
  });

  testWidgets('Ctrl+V 粘贴截图后显示缩略图，空正文也能保存成图片笔记', (tester) async {
    clipboard.image = onePixelPng;
    QuickDraft? changed;
    QuickDraft? saved;
    await pumpQuick(
      tester,
      onChanged: (draft) => changed = draft,
      onSave: (draft) async => saved = draft,
    );

    await pressPaste(tester);

    expect(find.byTooltip('移除图片'), findsOneWidget);
    expect(changed?.images, hasLength(1));
    expect(store.imageFile(changed!.images.single).existsSync(), isTrue);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存并收起'),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.text('保存并收起'));
    await tester.pumpAndSettle();

    expect(saved?.text, '');
    expect(saved?.images, hasLength(1));
    expect(find.byTooltip('移除图片'), findsNothing);
  });

  testWidgets('剪贴板有文字时不接管，不生成缩略图', (tester) async {
    clipboard
      ..text = '一段文字'
      ..image = onePixelPng;
    QuickDraft? changed;
    await pumpQuick(tester, onChanged: (draft) => changed = draft);

    await pressPaste(tester);

    expect(find.byTooltip('移除图片'), findsNothing);
    expect(changed?.images ?? const <String>[], isEmpty);
  });

  testWidgets('移除缩略图会删除已落盘的图片文件', (tester) async {
    clipboard.image = onePixelPng;
    QuickDraft? changed;
    await pumpQuick(tester, onChanged: (draft) => changed = draft);

    await pressPaste(tester);
    final name = changed!.images.single;
    expect(store.imageFile(name).existsSync(), isTrue);

    await tester.tap(find.byTooltip('移除图片'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('移除图片'), findsNothing);
    expect(changed?.images, isEmpty);
    expect(store.imageFile(name).existsSync(), isFalse);
  });
}
