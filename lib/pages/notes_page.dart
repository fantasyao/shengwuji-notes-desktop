import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../models/note.dart';
import '../services/clipboard_reader.dart';
import '../state/notes_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/note_card.dart';
import 'note_editor_page.dart';

/// 主页面：顶部搜索 + 新建，下面按时间倒序铺瀑布流卡片。
class NotesHomePage extends StatefulWidget {
  const NotesHomePage({
    super.key,
    required this.controller,
    this.clipboard = const SystemClipboardReader(),
    this.hotkeyLabel = '',
    this.onOpenSettings,
    this.onQuickCapture,
  });

  final NotesController controller;
  final ClipboardReader clipboard;

  /// 全局快速记录快捷键，用于提示文案；为空表示不展示。
  final String hotkeyLabel;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onQuickCapture;

  @override
  State<NotesHomePage> createState() => _NotesHomePageState();
}

class _NotesHomePageState extends State<NotesHomePage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _pageFocus = FocusNode();
  final ScrollController _gridScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    if (widget.controller.isLoading) {
      widget.controller.load();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    _pageFocus.dispose();
    _gridScroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openEditor([Note? note]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => NoteEditorPage(
          controller: widget.controller,
          note: note,
          clipboard: widget.clipboard,
        ),
      ),
    );
    if (mounted) _pageFocus.requestFocus();
  }

  Future<void> _deleteNote(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: const Text('删除这条笔记？'),
          content: const Text('删除后无法恢复，笔记里的图片也会一并删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    try {
      await widget.controller.delete(note);
      _toast('笔记已删除');
    } catch (error) {
      _toast('删除失败：$error');
    }
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
  }

  void _clearSearch() {
    _searchController.clear();
    widget.controller.setQuery('');
    _pageFocus.requestFocus();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
          _openEditor();
        },
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (widget.controller.query.isNotEmpty) {
            _clearSearch();
          } else {
            _pageFocus.requestFocus();
          }
        },
      },
      child: Focus(
        focusNode: _pageFocus,
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              _buildHeader(theme),
              _buildSummary(theme),
              Expanded(child: _buildBody(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: AppSurface.border(context))),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF26A69A), Color(0xFF00796B)],
              ),
              boxShadow: [
                BoxShadow(
                  color: kSeedColor.withValues(alpha: 0.28),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(
              Icons.sticky_note_2_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('声物记', style: theme.textTheme.titleLarge),
              const SizedBox(height: 1),
              Text(
                '电脑版 · 本地笔记',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const Spacer(),
          SizedBox(
            width: 320,
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              onChanged: widget.controller.setQuery,
              textInputAction: TextInputAction.search,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: '搜索笔记…',
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                suffixIcon: widget.controller.query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        icon: const Icon(Icons.close_rounded, size: 17),
                        onPressed: _clearSearch,
                      ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (widget.onQuickCapture != null)
            IconButton(
              tooltip: widget.hotkeyLabel.isEmpty
                  ? '快速记录'
                  : '快速记录 (${widget.hotkeyLabel})',
              onPressed: widget.onQuickCapture,
              icon: const Icon(Icons.bolt_rounded, size: 21),
            ),
          if (widget.onOpenSettings != null)
            IconButton(
              tooltip: '设置快捷键',
              onPressed: widget.onOpenSettings,
              icon: const Icon(Icons.settings_rounded, size: 20),
            ),
          const SizedBox(width: 12),
          Tooltip(
            message: '新建笔记 (Ctrl+N)',
            child: FilledButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add_rounded, size: 19),
              label: const Text('新建笔记'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(ThemeData theme) {
    final visible = widget.controller.visibleNotes.length;
    final total = widget.controller.notes.length;
    final searching = widget.controller.query.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 16, 26, 8),
      child: Row(
        children: [
          Text(
            searching ? '找到 $visible 条' : '共 $total 条笔记',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            widget.hotkeyLabel.isEmpty
                ? 'Ctrl+N 新建 · Ctrl+F 搜索'
                : '${widget.hotkeyLabel} 快速记录 · Ctrl+N 新建 · Ctrl+F 搜索',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final controller = widget.controller;
    if (controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.error != null) {
      return _CenteredMessage(
        icon: Icons.error_outline_rounded,
        iconColor: theme.colorScheme.error,
        title: '读取笔记失败',
        message: controller.error!,
        actionLabel: '重试',
        onAction: controller.load,
      );
    }
    if (controller.notes.isEmpty) {
      return _CenteredMessage(
        icon: Icons.edit_note_rounded,
        title: '还没有笔记',
        message: '写下第一条想法吧。\n可以在笔记里直接粘贴截图。',
        actionLabel: '新建笔记',
        onAction: () => _openEditor(),
      );
    }
    final notes = controller.visibleNotes;
    if (notes.isEmpty) {
      return _CenteredMessage(
        icon: Icons.search_off_rounded,
        title: '没有匹配的笔记',
        message: '换个关键词试试，或清除搜索。',
        actionLabel: '清除搜索',
        onAction: _clearSearch,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1500
            ? 4
            : width >= 1100
            ? 3
            : width >= 720
            ? 2
            : 1;
        return Scrollbar(
          controller: _gridScroll,
          child: MasonryGridView.count(
            controller: _gridScroll,
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 36),
            crossAxisCount: columns,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            itemCount: notes.length,
            itemBuilder: (context, index) {
              final note = notes[index];
              return NoteCard(
                key: ValueKey(note.uuid),
                note: note,
                store: controller.store,
                onOpen: () => _openEditor(note),
                onDelete: () => _deleteNote(note),
              );
            },
          ),
        );
      },
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: (iconColor ?? theme.colorScheme.primary).withValues(
                  alpha: 0.10,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 38,
                color: iconColor ?? theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
