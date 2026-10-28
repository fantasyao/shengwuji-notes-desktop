import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../models/note.dart';
import '../services/clipboard_reader.dart';
import '../state/notes_controller.dart';
import '../sync/sync_models.dart';
import '../sync/sync_service.dart';
import '../theme/app_theme.dart';
import '../utils/date_format.dart';
import '../widgets/note_card.dart';
import '../widgets/window_entrance.dart';
import 'note_editor_page.dart';
import 'trash_page.dart';

/// 主页面：顶部搜索 + 新建，下面按时间倒序铺瀑布流卡片。
class NotesHomePage extends StatefulWidget {
  const NotesHomePage({
    super.key,
    required this.controller,
    this.syncService,
    this.clipboard = const SystemClipboardReader(),
    this.hotkeyLabel = '',
    this.onOpenSettings,
    this.onQuickCapture,
  });

  final NotesController controller;
  final SyncService? syncService;
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
    widget.syncService?.addListener(_onControllerChanged);
    if (widget.controller.isLoading) {
      widget.controller.load();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.syncService?.removeListener(_onControllerChanged);
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

  Future<void> _copyNote(Note note) async {
    if (note.content.trim().isEmpty) {
      _toast('正文还是空的');
      return;
    }
    await Clipboard.setData(ClipboardData(text: note.content));
    _toast('正文已复制');
  }

  /// 移入回收站可恢复，不再二次确认。
  Future<void> _deleteNote(Note note) async {
    try {
      await widget.controller.moveToTrash(note);
      _toast('已移入回收站');
    } catch (error) {
      _toast('删除失败：$error');
    }
  }

  Future<void> _openTrash() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TrashPage(controller: widget.controller),
      ),
    );
    if (mounted) _pageFocus.requestFocus();
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

  void _toast(String message, {VoidCallback? onViewDetails}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          action: onViewDetails == null
              ? null
              : SnackBarAction(label: '查看', onPressed: onViewDetails),
        ),
      );
  }

  Future<void> _syncNow() async {
    final service = widget.syncService;
    if (service == null || service.isBusy) return;
    final result = await service.sync(manual: true);
    if (!mounted) return;
    final error = service.lastError;
    if (error != null) {
      _toast('同步失败：$error');
      return;
    }
    if (result == null) {
      _toast('同步未进行，请先在设置里配置 WebDAV');
      return;
    }
    final warnings = result.warnings;
    _toast(
      warnings.isEmpty
          ? _describeSync(result)
          : '${_describeSync(result)} · ${warnings.length} 条提醒',
      onViewDetails: warnings.isEmpty ? null : () => _showWarnings(warnings),
    );
  }

  Future<void> _showWarnings(List<String> warnings) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('同步提醒'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final warning in warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('· $warning'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  String _describeSync(SyncResult result) {
    final stats = result.stats;
    final parts = <String>[];
    if (stats.importedFromV1 > 0) parts.add('吸收手机笔记 ${stats.importedFromV1}');
    if (stats.appliedRemote > 0) parts.add('更新 ${stats.appliedRemote}');
    if (stats.assetsDownloaded + stats.assetsUploaded > 0) {
      parts.add('图片 ${stats.assetsDownloaded + stats.assetsUploaded}');
    }
    if (stats.audioDownloaded > 0) parts.add('录音 ${stats.audioDownloaded}');
    if (stats.conflictCopies > 0) parts.add('冲突副本 ${stats.conflictCopies}');
    if (parts.isEmpty) return '同步完成，已是最新';
    return '同步完成 · ${parts.join(' · ')}';
  }

  String _syncSubtitle(SyncService service) {
    switch (service.status) {
      case SyncStatus.disabled:
        return '电脑版 · 本地笔记';
      case SyncStatus.syncing:
        return '电脑版 · 正在同步…';
      case SyncStatus.error:
        return '电脑版 · 同步失败';
      case SyncStatus.success:
      case SyncStatus.idle:
        final at = service.lastSyncAt;
        return at == null ? '电脑版 · 本地笔记' : '电脑版 · 已同步 ${formatClock(at)}';
    }
  }

  String _syncTooltip(SyncService service) {
    final budget = _requestBudgetHint(service);
    switch (service.status) {
      case SyncStatus.disabled:
        return 'WebDAV 未配置或已关闭，点击打开设置';
      case SyncStatus.syncing:
        return '正在同步…$budget';
      case SyncStatus.error:
        return '同步失败：${service.lastError ?? '未知错误'}\n点击重试$budget';
      case SyncStatus.success:
      case SyncStatus.idle:
        final at = service.lastSyncAt;
        return at == null
            ? '点击立即同步$budget'
            : '上次同步 ${formatClock(at)}\n点击立即同步$budget';
    }
  }

  String _requestBudgetHint(SyncService service) {
    if (!service.isEnabled) return '';
    final used = service.requestCounter?.recentCount ?? 0;
    return used == 0 ? '' : '\n本机最近 30 分钟请求 $used 次';
  }

  Widget _buildSyncButton(ThemeData theme) {
    final service = widget.syncService!;
    final busy = service.status == SyncStatus.syncing;
    final failed = service.status == SyncStatus.error;
    final disabled = service.status == SyncStatus.disabled;
    return IconButton(
      tooltip: _syncTooltip(service),
      onPressed: busy ? null : (disabled ? widget.onOpenSettings : _syncNow),
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              disabled
                  ? Icons.cloud_off_rounded
                  : failed
                  ? Icons.sync_problem_rounded
                  : Icons.cloud_done_outlined,
              size: 20,
              color: failed ? theme.colorScheme.error : null,
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
          body: WindowEntrance(
            child: Column(
              children: [
                _buildHeader(theme),
                _buildSummary(theme),
                Expanded(child: _buildBody(theme)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 放大到 125% / 150% 时逻辑宽度会明显变窄：收起副标题和按钮文字，
        // 把横向空间留给搜索框，避免 Row 溢出。
        final compact = constraints.maxWidth < 760;
        final padding = compact ? 16.0 : 24.0;
        return Container(
          padding: EdgeInsets.fromLTRB(padding, 6, padding, 14),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border(
              bottom: BorderSide(color: AppSurface.border(context)),
            ),
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
              if (compact)
                Text('声物记', style: theme.textTheme.titleLarge)
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('声物记', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 1),
                    Text(
                      widget.syncService == null
                          ? '电脑版 · 本地笔记'
                          : _syncSubtitle(widget.syncService!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, searchConstraints) {
                    final width = searchConstraints.maxWidth < 320
                        ? searchConstraints.maxWidth
                        : 320.0;
                    return Align(
                      alignment: Alignment.centerRight,
                      heightFactor: 1,
                      child: SizedBox(
                        width: width,
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocus,
                          onChanged: widget.controller.setQuery,
                          textInputAction: TextInputAction.search,
                          style: theme.textTheme.bodyMedium,
                          decoration: InputDecoration(
                            hintText: '搜索笔记…',
                            isDense: true,
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 19,
                            ),
                            suffixIcon: widget.controller.query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清除搜索',
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 17,
                                    ),
                                    onPressed: _clearSearch,
                                  ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '回收站',
                onPressed: _openTrash,
                icon: Badge.count(
                  count: widget.controller.archivedNotes.length,
                  isLabelVisible: widget.controller.archivedNotes.isNotEmpty,
                  child: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ),
              if (widget.syncService != null) _buildSyncButton(theme),
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
                child: compact
                    ? IconButton.filledTonal(
                        onPressed: () => _openEditor(),
                        icon: const Icon(Icons.add_rounded, size: 19),
                      )
                    : FilledButton.icon(
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
      },
    );
  }

  Widget _buildSummary(ThemeData theme) {
    final visible = widget.controller.visibleNotes.length;
    final total = widget.controller.activeNotes.length;
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
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.hotkeyLabel.isEmpty
                  ? 'Ctrl+N 新建 · Ctrl+F 搜索'
                  : '${widget.hotkeyLabel} 快速记录 · Ctrl+N 新建 · Ctrl+F 搜索',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.6,
                ),
              ),
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
    if (controller.activeNotes.isEmpty) {
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
                onCopy: () => _copyNote(note),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 64),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        color: (iconColor ?? theme.colorScheme.primary)
                            .withValues(alpha: 0.10),
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
                    FilledButton.tonal(
                      onPressed: onAction,
                      child: Text(actionLabel),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
