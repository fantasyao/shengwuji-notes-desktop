import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';
import 'package:shengwuji_desktop/widgets/link_editing_controller.dart';

/// 编辑框的链接样式：蓝色下划线只落在网址上，组字范围仍保留下划线，
/// 不改动原文与其它文字的样式。
void main() {
  late BuildContext context;

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (builderContext) {
            context = builderContext;
            return const SizedBox();
          },
        ),
      ),
    );
  }

  List<TextSpan> spansOf(TextSpan root) =>
      root.children?.cast<TextSpan>().toList() ?? <TextSpan>[root];

  testWidgets('链接单独成段，使用蓝色下划线', (tester) async {
    await pumpContext(tester);
    final controller = LinkEditingController(text: '看 https://a.com/x 吧');
    addTearDown(controller.dispose);

    const base = TextStyle(fontSize: 16, color: Colors.black87);
    final root = controller.buildTextSpan(
      context: context,
      style: base,
      withComposing: false,
    );

    expect(root.toPlainText(), '看 https://a.com/x 吧');
    expect(root.style, base);

    final spans = spansOf(root);
    final link = spans.firstWhere((span) => span.text == 'https://a.com/x');
    expect(link.style?.color, AppSurface.link(context));
    expect(link.style?.decoration, TextDecoration.underline);
    expect(link.style?.decorationColor, AppSurface.link(context));

    final plain = spans.firstWhere((span) => span.text == '看 ');
    expect(plain.style, isNull);
  });

  testWidgets('没有链接时退回父类实现', (tester) async {
    await pumpContext(tester);
    final controller = LinkEditingController(text: '普通文本');
    addTearDown(controller.dispose);

    final root = controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 16),
      withComposing: false,
    );
    expect(root.text, '普通文本');
    expect(root.children, isNull);
  });

  testWidgets('输入法组字范围保留下划线，与链接重叠时仍显示蓝色', (tester) async {
    await pumpContext(tester);
    const text = '看 https://a.com/x 吧';
    final controller = LinkEditingController(text: text);
    addTearDown(controller.dispose);
    controller.value = const TextEditingValue(
      text: text,
      composing: TextRange(start: 6, end: 10),
    );

    const base = TextStyle(fontSize: 16, color: Colors.black87);
    final root = controller.buildTextSpan(
      context: context,
      style: base,
      withComposing: true,
    );

    expect(root.toPlainText(), text);
    final spans = spansOf(root);
    expect(
      spans.any(
        (span) =>
            span.style?.decoration == TextDecoration.underline &&
            span.style?.color == AppSurface.link(context),
      ),
      isTrue,
    );
    // 组字段与链接重叠时下划线仍然存在，不会被链接样式抹掉。
    final composingText = TextRange(start: 6, end: 10).textInside(text);
    expect(
      spans.any(
        (span) =>
            span.text == composingText &&
            span.style?.decoration == TextDecoration.underline,
      ),
      isTrue,
    );
  });

  testWidgets('withComposing=false 时不套用组字样式', (tester) async {
    await pumpContext(tester);
    const text = 'abc https://a.com/x';
    final controller = LinkEditingController(text: text);
    addTearDown(controller.dispose);
    controller.value = const TextEditingValue(
      text: text,
      composing: TextRange(start: 0, end: 3),
    );

    final root = controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 16),
      withComposing: false,
    );
    expect(root.toPlainText(), text);
    final spans = spansOf(root);
    expect(spans.first.text, 'abc ');
    expect(spans.first.style, isNull);
  });
}
