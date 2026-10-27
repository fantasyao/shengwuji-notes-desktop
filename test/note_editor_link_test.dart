import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/models/note.dart';
import 'package:shengwuji_desktop/pages/note_editor_page.dart';
import 'package:shengwuji_desktop/state/notes_controller.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';
import 'package:shengwuji_desktop/widgets/link_text.dart';

import 'support/memory_note_store.dart';

/// 编辑页的链接：正文里显示蓝色下划线，单击链接打开浏览器；单击普通文字、
/// 拖选或 Shift+点击仍走原来的编辑行为。
void main() {
  late Directory dir;
  late MemoryNoteStore store;
  late NotesController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shengwuji_editor_link_test_');
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

  Future<void> pumpEditor(
    WidgetTester tester,
    String content, {
    LinkOpenCallback? onOpenLink,
  }) async {
    final now = DateTime(2026, 10, 27, 10);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NoteEditorPage(
          controller: controller,
          note: Note(
            uuid: 'n1',
            content: content,
            createdAt: now,
            updatedAt: now,
          ),
          onOpenLink: onOpenLink,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  RenderEditable editableOf(WidgetTester tester) {
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    return state.renderEditable;
  }

  /// 点正文第 [offset] 个字符后面的 1.5px，模拟鼠标落在该字符上。
  Future<void> tapAtOffset(WidgetTester tester, int offset) async {
    final editable = editableOf(tester);
    final caret = editable.getLocalRectForCaret(TextPosition(offset: offset));
    await tester.tapAt(
      editable.localToGlobal(caret.center + const Offset(1.5, 0)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('编辑框里的链接显示为蓝色下划线', (tester) async {
    const content = '看 https://a.com/x 和 https://b.com/y';
    await pumpEditor(tester, content);

    final context = tester.element(find.byType(NoteEditorPage));
    final root = editableOf(tester).text! as TextSpan;
    final spans = root.children!.cast<TextSpan>();
    final link = spans.firstWhere((span) => span.text == 'https://a.com/x');
    expect(link.style?.color, AppSurface.link(context));
    expect(link.style?.decoration, TextDecoration.underline);
    expect(root.toPlainText(), content);
  });

  testWidgets('单击链接打开浏览器，正文保持不变', (tester) async {
    const content = '看 https://a.com/x 和 https://b.com/y';
    final opened = <Uri>[];
    await pumpEditor(
      tester,
      content,
      onOpenLink: (uri) async {
        opened.add(uri);
        return true;
      },
    );

    await tapAtOffset(tester, content.indexOf('https://a.com/x') + 3);
    await tapAtOffset(tester, content.indexOf('https://b.com/y') + 3);

    expect(opened, [
      Uri.parse('https://a.com/x'),
      Uri.parse('https://b.com/y'),
    ]);
    final editable = editableOf(tester);
    expect(editable.text!.toPlainText(), content);
  });

  testWidgets('单击普通文字仍只是移动光标，不打开浏览器', (tester) async {
    final opened = <Uri>[];
    await pumpEditor(
      tester,
      '看 https://a.com/x',
      onOpenLink: (uri) async {
        opened.add(uri);
        return true;
      },
    );

    await tapAtOffset(tester, 0);
    expect(opened, isEmpty);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.selection.isCollapsed, isTrue);
  });

  testWidgets('Shift+点击链接用于扩展选区，不打开浏览器', (tester) async {
    const content = '看 https://a.com/x';
    final opened = <Uri>[];
    await pumpEditor(
      tester,
      content,
      onOpenLink: (uri) async {
        opened.add(uri);
        return true;
      },
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tapAtOffset(tester, content.indexOf('https://a.com/x') + 3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(opened, isEmpty);
  });
}
