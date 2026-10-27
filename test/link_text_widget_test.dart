import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';
import 'package:shengwuji_desktop/widgets/link_text.dart';

/// 卡片正文链接的渲染与点击：蓝色下划线、悬停手型、点击交给回调，
/// 打开失败时给出可手动复制的完整地址。
void main() {
  Future<void> pumpLinkText(
    WidgetTester tester, {
    required String text,
    LinkOpenCallback? onOpenLink,
    TextStyle? style,
    int? maxLines,
    TextOverflow? overflow,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: LinkText(
                text: text,
                style: style,
                maxLines: maxLines,
                overflow: overflow,
                onOpenLink: onOpenLink,
              ),
            ),
          ),
        ),
      ),
    );
  }

  TextSpan linkSpanOf(WidgetTester tester, String raw) {
    final text = tester.widget<Text>(
      find.descendant(of: find.byType(LinkText), matching: find.byType(Text)),
    );
    final root = text.textSpan! as TextSpan;
    return root.children!.cast<TextSpan>().firstWhere(
      (span) => span.text == raw,
    );
  }

  testWidgets('链接显示为蓝色下划线，普通文字保持原样式', (tester) async {
    await pumpLinkText(
      tester,
      text: '看 https://a.com/x 吧',
      onOpenLink: (_) async => true,
      style: const TextStyle(color: Colors.black87),
    );

    final context = tester.element(find.byType(LinkText));
    final link = linkSpanOf(tester, 'https://a.com/x');
    expect(link.style?.color, AppSurface.link(context));
    expect(link.style?.decoration, TextDecoration.underline);
    expect(link.style?.decorationColor, AppSurface.link(context));
    expect(link.recognizer, isNotNull);

    final plain = linkSpanOf(tester, '看 ');
    expect(plain.style, isNull);
  });

  testWidgets('深色主题用更亮的蓝色', (tester) async {
    await pumpLinkText(
      tester,
      text: 'https://a.com/x',
      onOpenLink: (_) async => true,
      brightness: Brightness.dark,
    );

    final context = tester.element(find.byType(LinkText));
    expect(
      linkSpanOf(tester, 'https://a.com/x').style?.color,
      AppSurface.link(context),
    );
    expect(AppSurface.link(context), const Color(0xFF64B5F6));
  });

  testWidgets('点击链接交给回调，www. 自动补 https://', (tester) async {
    final opened = <Uri>[];
    await pumpLinkText(
      tester,
      text: '去 www.example.com/a 看看',
      onOpenLink: (uri) async {
        opened.add(uri);
        return true;
      },
    );

    await tester.tapOnText(find.textRange.ofSubstring('www.example.com/a'));
    await tester.pumpAndSettle();

    expect(opened, [Uri.parse('https://www.example.com/a')]);
  });

  testWidgets('没有链接时退回普通 Text，不改省略号参数', (tester) async {
    await pumpLinkText(
      tester,
      text: '普通文本没有网址',
      onOpenLink: (_) async => true,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );

    expect(
      find.descendant(
        of: find.byType(LinkText),
        matching: find.byType(MouseRegion),
      ),
      findsNothing,
    );
    final text = tester.widget<Text>(
      find.descendant(of: find.byType(LinkText), matching: find.byType(Text)),
    );
    expect(text.data, '普通文本没有网址');
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('打开失败时提示完整地址', (tester) async {
    await pumpLinkText(
      tester,
      text: '看 https://a.com/x',
      onOpenLink: (_) async => false,
    );

    await tester.tapOnText(find.textRange.ofSubstring('https://a.com/x'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('无法打开链接：https://a.com/x'), findsOneWidget);
  });
}
