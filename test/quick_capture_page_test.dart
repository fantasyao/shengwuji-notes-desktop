import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/pages/quick_capture_page.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

void main() {
  Future<void> pumpQuick(
    WidgetTester tester, {
    String initialText = '',
    required ValueChanged<String> onChanged,
    required Future<void> Function(String) onSave,
    required VoidCallback onClose,
    required Future<void> Function(String) onOpenMain,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: QuickCapturePage(
          initialText: initialText,
          hotkeyLabel: 'Ctrl + Alt + Space',
          onChanged: onChanged,
          onSave: onSave,
          onClose: onClose,
          onOpenMain: onOpenMain,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空输入时保存按钮不可用', (tester) async {
    await pumpQuick(
      tester,
      onChanged: (_) {},
      onSave: (_) async {},
      onClose: () {},
      onOpenMain: (_) async {},
    );

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存并收起'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Ctrl+Enter 保存并清空输入', (tester) async {
    String? saved;
    String? changed;
    await pumpQuick(
      tester,
      onChanged: (text) => changed = text,
      onSave: (text) async => saved = text,
      onClose: () {},
      onOpenMain: (_) async {},
    );

    await tester.enterText(find.byType(TextField), '买牛奶');
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(saved, '买牛奶');
    expect(changed, '');
    expect(find.text('买牛奶'), findsNothing);
    expect(find.textContaining('记点什么'), findsOneWidget);
  });

  testWidgets('点击保存按钮保存当前文本', (tester) async {
    String? saved;
    await pumpQuick(
      tester,
      initialText: '草稿保留',
      onChanged: (_) {},
      onSave: (text) async => saved = text,
      onClose: () {},
      onOpenMain: (_) async {},
    );

    await tester.tap(find.text('保存并收起'));
    await tester.pumpAndSettle();

    expect(saved, '草稿保留');
  });

  testWidgets('Esc 触发收起', (tester) async {
    var closed = false;
    await pumpQuick(
      tester,
      onChanged: (_) {},
      onSave: (_) async {},
      onClose: () => closed = true,
      onOpenMain: (_) async {},
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(closed, isTrue);
  });

  testWidgets('打开主界面时带上当前文本', (tester) async {
    String? received;
    await pumpQuick(
      tester,
      onChanged: (_) {},
      onSave: (_) async {},
      onClose: () {},
      onOpenMain: (text) async => received = text,
    );

    await tester.enterText(find.byType(TextField), '要继续写的');
    await tester.pump();
    await tester.tap(find.byTooltip('打开主界面'));
    await tester.pumpAndSettle();

    expect(received, '要继续写的');
  });
}
