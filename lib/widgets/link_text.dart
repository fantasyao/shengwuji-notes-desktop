import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/link_opener.dart';
import '../theme/app_theme.dart';
import '../utils/link_text.dart';

/// 打开链接的回调；返回 false 表示没打开，[LinkText] 会给出提示。
typedef LinkOpenCallback = Future<bool> Function(Uri uri);

Future<bool> _openInSystemBrowser(Uri uri) async => openUrlInBrowser(uri);

/// 只读正文里的 http(s) 链接：蓝色下划线，鼠标悬停显示手型，点击交给
/// 系统默认浏览器。
///
/// 卡片整体有「点开笔记」的手势，链接用独立的 TapGestureRecognizer 命中时
/// 会先赢得手势竞技场，因此点网址只会打开浏览器，不会顺带打开笔记。
/// 没有任何链接时退回普通 [Text]，不改原有排版与省略号行为。
class LinkText extends StatefulWidget {
  const LinkText({
    super.key,
    required this.text,
    this.style,
    this.maxLines,
    this.overflow,
    this.onOpenLink,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  /// 测试或特殊场景可接管打开动作；null 时用系统默认浏览器
  final LinkOpenCallback? onOpenLink;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final GlobalKey _textKey = GlobalKey();
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];
  List<TextLink> _links = const <TextLink>[];
  bool _hoveringLink = false;

  @override
  void initState() {
    super.initState();
    _rebuildLinks();
  }

  @override
  void didUpdateWidget(LinkText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) _rebuildLinks();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _rebuildLinks() {
    _disposeRecognizers();
    _links = findTextLinks(widget.text);
    for (final link in _links) {
      _recognizers.add(TapGestureRecognizer()..onTap = () => _openLink(link));
    }
    _hoveringLink = false;
  }

  Future<void> _openLink(TextLink link) async {
    final uri = Uri.tryParse(link.url);
    if (uri == null) return;

    bool opened;
    try {
      opened = await (widget.onOpenLink ?? _openInSystemBrowser)(uri);
    } catch (error) {
      debugPrint('打开链接失败：$error');
      opened = false;
    }
    if (opened || !mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('无法打开链接：$uri'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  void _onHover(PointerHoverEvent event) {
    final renderObject = _textKey.currentContext?.findRenderObject();
    if (renderObject is! RenderParagraph) return;
    final position = renderObject.getPositionForOffset(
      renderObject.globalToLocal(event.position),
    );
    final overLink = _links.any(
      (link) => position.offset >= link.start && position.offset < link.end,
    );
    _setHoveringLink(overLink);
  }

  void _setHoveringLink(bool value) {
    if (_hoveringLink == value) return;
    setState(() => _hoveringLink = value);
  }

  @override
  Widget build(BuildContext context) {
    if (_links.isEmpty) {
      return Text(
        widget.text,
        style: widget.style,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
      );
    }

    final linkColor = AppSurface.link(context);
    final linkStyle = TextStyle(
      color: linkColor,
      decoration: combineUnderline(widget.style?.decoration),
      decorationColor: linkColor,
    );

    final spans = <TextSpan>[];
    var lastEnd = 0;
    for (var index = 0; index < _links.length; index++) {
      final link = _links[index];
      if (link.start > lastEnd) {
        spans.add(TextSpan(text: widget.text.substring(lastEnd, link.start)));
      }
      spans.add(
        TextSpan(
          text: link.raw,
          style: linkStyle,
          recognizer: _recognizers[index],
        ),
      );
      lastEnd = link.end;
    }
    if (lastEnd < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(lastEnd)));
    }

    return MouseRegion(
      cursor: _hoveringLink ? SystemMouseCursors.click : MouseCursor.defer,
      onHover: _onHover,
      onExit: (_) => _setHoveringLink(false),
      child: Text.rich(
        TextSpan(children: spans),
        key: _textKey,
        style: widget.style,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
      ),
    );
  }
}
