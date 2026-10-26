import 'package:flutter/material.dart';

import '../services/system_fonts.dart';
import '../theme/app_theme.dart';

/// 打开字体列表，返回选中的字体家族名。
///
/// 返回 `null` 表示取消；返回空字符串表示恢复默认字体。
Future<String?> showFontPicker(
  BuildContext context, {
  required List<SystemFont> fonts,
  required String currentFamily,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) =>
        _FontPickerDialog(fonts: fonts, currentFamily: currentFamily),
  );
}

class _FontPickerDialog extends StatefulWidget {
  const _FontPickerDialog({required this.fonts, required this.currentFamily});

  final List<SystemFont> fonts;
  final String currentFamily;

  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _listScroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  bool get _showDefault => _matchesDefault(_query);

  List<SystemFont> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.fonts;
    return widget.fonts
        .where(
          (font) =>
              font.family.toLowerCase().contains(query) ||
              font.label.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  static bool _matchesDefault(String query) {
    final text = query.trim().toLowerCase();
    if (text.isEmpty) return true;
    return '默认'.contains(text) ||
        kDefaultFontLabel.contains(text) ||
        'microsoft yahei'.contains(text) ||
        'yahei'.contains(text) ||
        '微软雅黑'.contains(text);
  }

  void _select(String family) => Navigator.of(context).pop(family);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fonts = _filtered;
    final showDefault = _showDefault;
    return AlertDialog(
      title: const Text('选择字体'),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      content: SizedBox(
        width: 460,
        height: 340,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: '搜索字体名，如「楷体」或 KaiTi',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '共 ${widget.fonts.length} 个已安装字体；列表里按字体自身样式预览。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: fonts.isEmpty && !showDefault
                  ? _EmptyHint(query: _query)
                  : Scrollbar(
                      controller: _listScroll,
                      child: ListView(
                        controller: _listScroll,
                        primary: false,
                        padding: const EdgeInsets.only(bottom: 8),
                        children: [
                          if (showDefault)
                            _FontTile(
                              key: const ValueKey('font-option-default'),
                              detail: '默认 · $kDefaultFontLabel（系统字体）',
                              fontFamily: null,
                              selected: widget.currentFamily.isEmpty,
                              onTap: () => _select(''),
                            ),
                          for (final font in fonts)
                            _FontTile(
                              key: ValueKey('font-option-${font.family}'),
                              detail: font.label == font.family
                                  ? font.family
                                  : '${font.label} · ${font.family}',
                              fontFamily: font.family,
                              selected: widget.currentFamily == font.family,
                              onTap: () => _select(font.family),
                            ),
                          if (fonts.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 16, 10, 8),
                              child: Text(
                                '没有读到其它字体。系统字体目录不可用时只能使用默认字体。',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _FontTile extends StatelessWidget {
  const _FontTile({
    super.key,
    required this.detail,
    required this.fontFamily,
    required this.selected,
    required this.onTap,
  });

  /// 字体名那一行。
  final String detail;

  /// 预览用的字体；为空时跟随主题默认字体。
  final String? fontFamily;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.09)
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '声物记 · 快速记录 AaBb 123',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontFamily: fontFamily,
                      fontSize: 15,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          query.trim().isEmpty ? '没有读到其它字体。' : '没有找到包含「${query.trim()}」的字体。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
