import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/image_payload.dart';
import '../models/note.dart';
import '../services/clipboard_reader.dart';
import '../state/notes_controller.dart';
import '../theme/app_theme.dart';
import '../utils/date_format.dart';

/// 笔记编辑页：多行文本 + 图片附件。
///
/// 文本输完 600ms 自动保存；图片增删立即保存。Ctrl+V 在剪贴板只有图片时
/// 把图片加成附件，有文字时仍走 TextField 默认粘贴，两者不打架。
class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    super.key,
    required this.controller,
    this.note,
    this.clipboard = const SystemClipboardReader(),
  });

  final NotesController controller;

  /// null 表示新建。
  final Note? note;
  final ClipboardReader clipboard;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  static const int _maxImages = 12;
  static const XTypeGroup _imageGroup = XTypeGroup(
    label: '图片',
    extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
  );

  late Note _note;
  late final TextEditingController _textController;
  late final FocusNode _focusNode;
  late final AppLifecycleListener _lifecycleListener;
  final ScrollController _scrollController = ScrollController();

  Timer? _saveTimer;
  Future<void> _saveQueue = Future.value();
  late String _lastObservedText;
  bool _dirty = false;
  bool _saving = false;
  bool _persisted = false;
  bool _addingImages = false;
  bool _closing = false;
  String? _saveError;
  DateTime? _savedAt;

  bool get _isNew => widget.note == null;

  @override
  void initState() {
    super.initState();
    _note = widget.note ?? widget.controller.createDraft();
    _persisted = widget.note != null;
    _savedAt = widget.note?.updatedAt;
    _lastObservedText = _note.content;
    _textController = TextEditingController(text: _note.content);
    _textController.addListener(_onTextChanged);
    _focusNode = FocusNode();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _lifecycleListener = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _lifecycleListener.dispose();
    _textController
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<AppExitResponse> _onExitRequested() async {
    await _flushSave();
    return AppExitResponse.exit;
  }

  void _onTextChanged() {
    // TextEditingController 在光标移动时也会通知，只有文本真的变化才算改动。
    if (_textController.text == _lastObservedText) return;
    _lastObservedText = _textController.text;
    _markDirty();
  }

  void _markDirty({bool schedule = true}) {
    if (mounted) {
      setState(() {
        _dirty = true;
        _saveError = null;
      });
    } else {
      _dirty = true;
      _saveError = null;
    }
    _saveTimer?.cancel();
    if (schedule) {
      _saveTimer = Timer(const Duration(milliseconds: 600), () {
        _flushSave();
      });
    }
  }

  Future<bool> _flushSave() {
    _saveTimer?.cancel();
    final next = _saveQueue.then((_) => _saveOnce());
    _saveQueue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next.then((_) => _saveError == null && !_dirty);
  }

  Future<void> _saveOnce() async {
    if (!_dirty) return;
    final content = _textController.text;
    final updated = _note.copyWith(
      content: content,
      updatedAt: DateTime.now(),
    );

    // 全新的空白笔记先不落盘，关闭时自然消失。
    if (updated.isEmpty && !_persisted) {
      _dirty = false;
      return;
    }

    if (mounted) {
      setState(() {
        _saving = true;
        _dirty = false;
        _saveError = null;
      });
    }
    try {
      await widget.controller.upsert(updated);
      _persisted = true;
      _note = updated;
      _savedAt = DateTime.now();
      if (_textController.text != content) {
        _dirty = true;
        _scheduleSaveIfNeeded();
      }
    } catch (error) {
      _dirty = true;
      _saveError = '保存失败：$error';
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _scheduleSaveIfNeeded() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      _flushSave();
    });
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyV) {
      _pasteShortcut();
    }
    return false;
  }

  /// Ctrl+V：只在剪贴板没有文字时接管，避免和文本框默认粘贴重复。
  Future<void> _pasteShortcut() async {
    final text = await widget.clipboard.readText();
    if (text != null && text.trim().isNotEmpty) return;

    final bitmap = await widget.clipboard.readImage();
    if (bitmap != null) {
      await _attachImages([bitmap]);
      return;
    }
    final paths = await widget.clipboard.readImageFilePaths();
    final files = await readClipboardFiles(paths);
    if (files.isNotEmpty) {
      await _attachImages(files);
    }
  }

  Future<void> _pasteImageButton() async {
    final bitmap = await widget.clipboard.readImage();
    if (bitmap != null) {
      await _attachImages([bitmap]);
      return;
    }
    final paths = await widget.clipboard.readImageFilePaths();
    final files = await readClipboardFiles(paths);
    if (files.isNotEmpty) {
      await _attachImages(files);
      return;
    }
    _toast('剪贴板里没有图片');
  }

  Future<void> _pickImages() async {
    List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: const [_imageGroup]);
    } catch (error) {
      _toast('打开图片选择器失败：$error');
      return;
    }
    if (files.isEmpty) return;
    final bytes = <Uint8List>[];
    for (final file in files) {
      try {
        bytes.add(await file.readAsBytes());
      } on FileSystemException {
        _toast('读取图片失败：${file.name}');
      }
    }
    if (bytes.isNotEmpty) {
      await _attachImages(bytes);
    }
  }

  Future<void> _attachImages(List<Uint8List> bytesList) async {
    if (_addingImages || bytesList.isEmpty) return;
    final remaining = _maxImages - _note.images.length;
    if (remaining <= 0) {
      _toast('一条笔记最多添加 $_maxImages 张图片');
      return;
    }
    final accepted = bytesList.take(remaining).toList();
    final tooMany = bytesList.length > remaining;

    setState(() => _addingImages = true);
    final names = <String>[];
    String? failure;
    try {
      for (final bytes in accepted) {
        try {
          names.add(await widget.controller.saveImage(bytes));
        } on ImageTooLargeException catch (error) {
          failure = error.toString();
        } on UnsupportedImageException catch (error) {
          failure = error.message;
        } on FileSystemException catch (error) {
          failure = '保存图片失败：$error';
        }
      }
    } finally {
      if (mounted) setState(() => _addingImages = false);
    }

    if (!mounted) return;
    if (names.isEmpty) {
      _toast(failure ?? '没有可添加的图片');
      return;
    }

    setState(() {
      _note = _note.copyWith(
        images: [..._note.images, ...names],
        updatedAt: DateTime.now(),
      );
    });
    _markDirty(schedule: false);
    await _flushSave();

    if (failure != null) {
      _toast(failure);
    } else if (tooMany) {
      _toast('已添加 ${names.length} 张，最多 $_maxImages 张');
    }
    if (mounted) _focusNode.requestFocus();
  }

  Future<void> _removeImage(String name) async {
    setState(() {
      _note = _note.copyWith(
        images: _note.images.where((item) => item != name).toList(),
        updatedAt: DateTime.now(),
      );
    });
    _markDirty(schedule: false);
    await _flushSave();
  }

  Future<void> _copyContent() async {
    final text = _textController.text;
    if (text.isEmpty) {
      _toast('正文还是空的');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _toast('正文已复制');
  }

  Future<void> _deleteNote() async {
    if (!_persisted) return;
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
      await widget.controller.delete(_note);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _toast('删除失败：$error');
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    final saved = await _flushSave();
    if (!mounted) return;

    if (!saved) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('还没保存成功'),
          content: Text(_saveError ?? '本次修改可能还没写入磁盘。仍要关闭吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('仍然关闭'),
            ),
          ],
        ),
      );
      if (leave != true) {
        _closing = false;
        return;
      }
    }

    if (!_persisted) {
      await widget.controller.discardDraft(_note);
    }
    if (mounted) Navigator.of(context).pop();
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

  String get _statusText {
    if (_saveError != null) return _saveError!;
    if (_saving) return '正在保存…';
    if (_dirty) return '未保存';
    if (_savedAt != null) return '已保存 ${formatClock(_savedAt!)}';
    return '空白笔记不会保存';
  }

  Color? _statusColor(BuildContext context) {
    if (_saveError != null) return Theme.of(context).colorScheme.error;
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            _flushSave,
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              _buildTopBar(theme),
              Expanded(
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(32, 28, 32, 48),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 880),
                        child: _buildEditorCard(theme),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(ThemeData theme) {
    return Container(
      height: 70,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(color: AppSurface.border(context)),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回 (Esc)',
            onPressed: _close,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _persisted || !_isNew ? '编辑笔记' : '新建笔记',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  _statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _statusColor(context),
                  ),
                ),
              ],
            ),
          ),
          if (_addingImages)
            const Padding(
              padding: EdgeInsets.only(right: 10),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          TextButton.icon(
            onPressed: _addingImages ? null : _pickImages,
            icon: const Icon(Icons.image_outlined, size: 18),
            label: const Text('添加图片'),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '从剪贴板粘贴图片',
            onPressed: _addingImages ? null : _pasteImageButton,
            icon: const Icon(Icons.content_paste_rounded, size: 19),
          ),
          IconButton(
            tooltip: '复制正文',
            onPressed: _copyContent,
            icon: const Icon(Icons.copy_rounded, size: 19),
          ),
          IconButton(
            tooltip: '删除笔记',
            onPressed: _persisted ? _deleteNote : null,
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 20,
              color: _persisted ? theme.colorScheme.onSurfaceVariant : null,
            ),
          ),
          const SizedBox(width: 6),
          FilledButton.tonal(
            onPressed: _close,
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorCard(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: AppSurface.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppSurface.border(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.18 : 0.04,
            ),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _textController,
            focusNode: _focusNode,
            autofocus: true,
            maxLines: null,
            minLines: 14,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              height: 1.8,
            ),
            decoration: InputDecoration(
              hintText: '写下此刻的想法…\n\nCtrl+V 可直接粘贴截图或图片。',
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintStyle: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 16,
                height: 1.8,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.55,
                ),
              ),
            ),
          ),
          if (_note.images.isNotEmpty) ...[
            const SizedBox(height: 18),
            Divider(color: AppSurface.border(context)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final name in _note.images)
                  _EditorImageTile(
                    file: widget.controller.store.imageFile(name),
                    onRemove: () => _removeImage(name),
                    onPreview: () => _previewImage(
                      widget.controller.store.imageFile(name),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '支持 Ctrl+V 粘贴截图，或点「添加图片」；一条最多 $_maxImages 张。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.8,
                    ),
                  ),
                ),
              ),
              Text(
                'Ctrl+S 保存 · Esc 返回',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.55,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _previewImage(File file) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(28),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              maxScale: 5,
              child: Image.file(
                file,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 64,
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton.filledTonal(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditorImageTile extends StatefulWidget {
  const _EditorImageTile({
    required this.file,
    required this.onRemove,
    required this.onPreview,
  });

  final File file;
  final VoidCallback onRemove;
  final VoidCallback onPreview;

  @override
  State<_EditorImageTile> createState() => _EditorImageTileState();
}

class _EditorImageTileState extends State<_EditorImageTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 136,
        height: 102,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _hovered
                ? Theme.of(context).colorScheme.primary
                : AppSurface.border(context),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Stack(
            fit: StackFit.expand,
            children: [
              InkWell(
                onTap: widget.onPreview,
                child: Image.file(
                  widget.file,
                  fit: BoxFit.cover,
                  cacheWidth: 420,
                  errorBuilder: (context, error, stackTrace) => ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 5,
                right: 5,
                child: Tooltip(
                  message: '移除图片',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onRemove,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
