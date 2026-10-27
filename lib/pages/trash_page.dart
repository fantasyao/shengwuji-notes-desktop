import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/note.dart';
import '../state/notes_controller.dart';
import '../theme/app_theme.dart';
import '../utils/date_format.dart';
import '../widgets/link_text.dart';

/// 回收站：删除的笔记先留在这里，可以恢复或永久删除。
class TrashPage extends StatefulWidget {
  const TrashPage({super.key, required this.controller});

  final NotesController controller;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  final FocusNode _pageFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final Set<String> _selected = <String>{};
  bool _selecting = false;

  @override
  void dispose() {
    _pageFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _close() {
    if (_selecting) {
      _toggleSelecting();
      return;
    }
    Navigator.of(context).maybePop();
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  void _toggleSelected(Note note) {
    setState(() {
      if (!_selected.remove(note.uuid)) _selected.add(note.uuid);
    });
  }

  void _selectAll(List<Note> notes) {
    setState(() {
      if (_selected.length == notes.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(notes.map((note) => note.uuid));
      }
    });
  }

  Future<void> _deleteSelected(List<Note> notes) async {
    final selected = notes
        .where((note) => _selected.contains(note.uuid))
        .toList(growable: false);
    if (selected.isEmpty) return;
    final confirmed = await _confirm(
      title: '永久删除选中的 ${selected.length} 条笔记？',
      message: '删除后无法恢复，笔记里的图片也会一并删除。',
      action: '永久删除',
    );
    if (confirmed != true) return;
    try {
      await widget.controller.deletePermanentlyMany(selected);
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _selecting = false;
      });
      _toast('已永久删除 ${selected.length} 条笔记');
    } catch (error) {
      _toast('删除失败：$error');
    }
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

  Future<void> _restore(Note note) async {
    try {
      await widget.controller.restore(note);
      _toast('笔记已恢复');
    } catch (error) {
      _toast('恢复失败：$error');
    }
  }

  Future<void> _deleteForever(Note note) async {
    final confirmed = await _confirm(
      title: '永久删除这条笔记？',
      message: '删除后无法恢复，笔记里的图片也会一并删除。',
      action: '永久删除',
    );
    if (confirmed != true) return;
    try {
      await widget.controller.deletePermanently(note);
      _toast('笔记已永久删除');
    } catch (error) {
      _toast('删除失败：$error');
    }
  }

  Future<void> _emptyTrash(List<Note> notes) async {
    if (notes.isEmpty) return;
    final confirmed = await _confirm(
      title: '清空回收站？',
      message: '${notes.length} 条笔记将被永久删除，无法恢复，笔记里的图片也会一并删除。',
      action: '清空',
    );
    if (confirmed != true) return;
    try {
      await widget.controller.emptyTrash();
      _toast('回收站已清空');
    } catch (error) {
      _toast('清空失败：$error');
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String action,
  }) {
    final theme = Theme.of(context);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
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
            child: Text(action),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        focusNode: _pageFocus,
        autofocus: true,
        child: Scaffold(
          body: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              final notes = widget.controller.archivedNotes;
              final uuids = notes.map((note) => note.uuid).toSet();
              _selected.removeWhere((uuid) => !uuids.contains(uuid));
              if (notes.isEmpty) _selecting = false;
              return Column(
                children: [
                  _buildHeader(theme, notes),
                  Expanded(child: _buildBody(theme, notes)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, List<Note> notes) {
    if (_selecting) return _buildSelectionHeader(theme, notes);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 20, 12),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: AppSurface.border(context))),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回 (Esc)',
            onPressed: _close,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('回收站', style: theme.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                notes.isEmpty ? '删除的笔记会保留在这里' : '共 ${notes.length} 条，可恢复或永久删除',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: notes.isEmpty ? null : _toggleSelecting,
            icon: const Icon(Icons.checklist_rounded, size: 18),
            label: const Text('多选'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: notes.isEmpty ? null : () => _emptyTrash(notes),
            icon: const Icon(Icons.delete_sweep_rounded, size: 18),
            label: const Text('清空回收站'),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionHeader(ThemeData theme, List<Note> notes) {
    final allSelected = notes.isNotEmpty && _selected.length == notes.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 20, 12),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: AppSurface.border(context))),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '退出多选 (Esc)',
            onPressed: _toggleSelecting,
            icon: const Icon(Icons.close_rounded),
          ),
          const SizedBox(width: 6),
          Text('已选择 ${_selected.length} 条', style: theme.textTheme.titleMedium),
          const Spacer(),
          TextButton(
            onPressed: notes.isEmpty ? null : () => _selectAll(notes),
            child: Text(allSelected ? '取消全选' : '全选'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: _selected.isEmpty ? null : () => _deleteSelected(notes),
            icon: const Icon(Icons.delete_forever_rounded, size: 18),
            label: Text(
              _selected.isEmpty ? '删除选中' : '删除选中 (${_selected.length})',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme, List<Note> notes) {
    if (widget.controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (notes.isEmpty) {
      return _EmptyTrash(theme: theme);
    }
    return Scrollbar(
      controller: _scroll,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: ListView.separated(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
            itemCount: notes.length,
            separatorBuilder: (context, index) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final note = notes[index];
              return _TrashTile(
                key: ValueKey(note.uuid),
                note: note,
                selecting: _selecting,
                selected: _selected.contains(note.uuid),
                onToggle: () => _toggleSelected(note),
                onRestore: () => _restore(note),
                onDeleteForever: () => _deleteForever(note),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TrashTile extends StatelessWidget {
  const _TrashTile({
    super.key,
    required this.note,
    required this.selecting,
    required this.selected,
    required this.onToggle,
    required this.onRestore,
    required this.onDeleteForever,
  });

  final Note note;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onRestore;
  final VoidCallback onDeleteForever;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = note.body;
    final muted = theme.colorScheme.onSurfaceVariant;

    final card = Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
      decoration: BoxDecoration(
        color: AppSurface.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.55)
              : AppSurface.border(context),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.14 : 0.04,
            ),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          if (selecting)
            Checkbox(
              value: selected,
              onChanged: (_) => onToggle(),
              visualDensity: VisualDensity.compact,
            )
          else ...[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.description_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                LinkText(
                  text: note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  LinkText(
                    text: body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.schedule_rounded, size: 12, color: muted),
                    const SizedBox(width: 4),
                    Text(
                      formatNoteTime(note.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                    if (note.images.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Icon(Icons.image_outlined, size: 12, color: muted),
                      const SizedBox(width: 3),
                      Text(
                        '${note.images.length} 张图片',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (!selecting) ...[
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: onRestore,
              icon: const Icon(Icons.restore_rounded, size: 18),
              label: const Text('恢复'),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '永久删除',
              onPressed: onDeleteForever,
              icon: Icon(
                Icons.delete_forever_rounded,
                size: 20,
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );

    if (!selecting) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: card,
      ),
    );
  }
}

class _EmptyTrash extends StatelessWidget {
  const _EmptyTrash({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
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
                color: theme.colorScheme.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.delete_outline_rounded,
                size: 38,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text('回收站是空的', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '在笔记卡片或编辑页删除的笔记会先放到这里，\n随时可以恢复。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
