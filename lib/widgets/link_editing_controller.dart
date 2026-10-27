import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/link_text.dart';

/// 编辑框用的文本控制器：把正文里的 http(s) 链接渲染成蓝色下划线。
///
/// 只改颜色与装饰，字宽、行高、光标和选区都不变；输入法组字范围仍按
/// [TextEditingController] 的规则加下划线。链接识别与卡片共用
/// [findTextLinks]，所以两处显示的可点范围一致。
class LinkEditingController extends TextEditingController {
  LinkEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final links = findTextLinks(text);
    if (links.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final hasComposing = composing.isValid && !composing.isCollapsed;
    final linkColor = AppSurface.link(context);
    final composingStyle =
        style?.merge(const TextStyle(decoration: TextDecoration.underline)) ??
        const TextStyle(decoration: TextDecoration.underline);

    // 以链接、组字范围的边界切段，保证每段只属于一种样式；组字和链接
    // 重叠时链接色优先，但组字下划线也保留。
    final boundaries = <int>{0, text.length};
    for (final link in links) {
      boundaries
        ..add(link.start)
        ..add(link.end);
    }
    if (hasComposing) {
      boundaries
        ..add(composing.start)
        ..add(composing.end);
    }
    final sorted =
        boundaries
            .where((offset) => offset >= 0 && offset <= text.length)
            .toList()
          ..sort();

    final spans = <TextSpan>[];
    for (var index = 0; index < sorted.length - 1; index++) {
      final start = sorted[index];
      final end = sorted[index + 1];
      if (start == end) continue;

      final isLink = links.any(
        (link) => start >= link.start && start < link.end,
      );
      final isComposing =
          hasComposing && start >= composing.start && end <= composing.end;

      TextStyle? segmentStyle;
      if (isLink) {
        final base = isComposing ? composingStyle : style;
        segmentStyle = (base ?? const TextStyle()).copyWith(
          color: linkColor,
          decoration: combineUnderline(base?.decoration),
          decorationColor: linkColor,
        );
      } else if (isComposing) {
        segmentStyle = composingStyle;
      }
      spans.add(
        TextSpan(text: text.substring(start, end), style: segmentStyle),
      );
    }

    return TextSpan(style: style, children: spans);
  }
}
