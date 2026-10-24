import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/image_payload.dart';
import '../models/quick_draft.dart';
import '../services/clipboard_reader.dart';
import '../state/notes_controller.dart';
import '../theme/app_theme.dart';

/// 快速记录窗：主窗口被压缩成 460x400 时展示的紧凑编辑页。
///
/// 设计成“随手写完就走”：Ctrl+Enter 保存并收起，Esc 收起但保留草稿。
/// 剪贴板里只有图片时，Ctrl+V 把图片存进数据目录并显示缩略图，保存时
/// 和正文一起写进同一条笔记。
class QuickCapturePage extends StatefulWidget {
  const QuickCapturePage({
    super.key,
    required this.controller,
    required this.initialDraft,
    required this.hotkeyLabel,
    required this.onChanged,
    required this.onSave,
    required this.onClose,
    required this.onOpenMain,
    this.clipboard = const SystemClipboardReader(),
    this.onDragStart,
    this.focusRequest = 0,
  });

  final NotesController controller;
  final QuickDraft initialDraft;
  final String hotkeyLabel;
  final ValueChanged<QuickDraft> onChanged;
  final Future<void> Function(QuickDraft draft) onSave;
  final VoidCallback onClose;
  final Future<void> Function(QuickDraft draft) onOpenMain;
  final ClipboardReader clipboard;
  final VoidCallback? onDragStart;

  /// 每次窗口重新呼出时由外层加一，用来把焦点重新放回输入框。
  final int focusRequest;

  @override
  State<QuickCapturePage> createState() => _QuickCapturePageState();
}

class _QuickCapturePageState extends State<QuickCapturePage>
    with WidgetsBindingObserver {
  late final TextEditingController _textController;
  final FocusNode _focusNode = FocusNode();
  late List<String> _images;
  bool _busy = false;
  bool _pasting = false;

  QuickDraft get _draft => QuickDraft(
    text: _textController.text,
    images: List<String>.unmodifiable(_images),
  );

  bool get _hasContent => !_draft.isEmpty;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialDraft.text)
      ..addListener(_onTextChanged);
    _images = List<String>.of(widget.initialDraft.images);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    WidgetsBinding.instance.addObserver(this);
    _focusEditorSoon();
  }

  @override
  void didUpdateWidget(QuickCapturePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusRequest != oldWidget.focusRequest) {
      _focusEditorSoon();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 窗口从隐藏/非激活状态回来时，系统会把 Flutter 焦点挂起再恢复，
    // 这里主动再聚焦一次，保证呼出后光标一定落在输入框里。
    if (state == AppLifecycleState.resumed) _focusEditorSoon();
  }

  void _focusEditorSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    _textController
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    widget.onChanged(_draft);
    setState(() {});
  }

  void _notifyChanged() {
    widget.onChanged(_draft);
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

  /// Ctrl+V：只在剪贴板没有文字时接管，文字仍交给输入框正常粘贴。
  Future<void> _pasteShortcut() async {
    if (_busy || _pasting) return;
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

  Future<void> _attachImages(List<Uint8List> bytesList) async {
    if (_pasting || bytesList.isEmpty) return;
    final remaining = kMaxNoteImages - _images.length;
    if (remaining <= 0) {
      _toast('一条笔记最多添加 $kMaxNoteImages 张图片');
      return;
    }
    final accepted = bytesList.take(remaining).toList();
    final tooMany = bytesList.length > remaining;

    setState(() => _pasting = true);
    final saved = <String>[];
    String? failure;
    try {
      for (final bytes in accepted) {
        try {
          saved.add(await widget.controller.saveImage(bytes));
        } on ImageTooLargeException catch (error) {
          failure = error.toString();
        } on UnsupportedImageException catch (error) {
          failure = error.message;
        } on FileSystemException catch (error) {
          failure = '保存图片失败：$error';
        }
      }
    } finally {
      if (mounted) setState(() => _pasting = false);
    }

    if (!mounted) return;
    if (saved.isEmpty) {
      _toast(failure ?? '没有可添加的图片');
      return;
    }

    setState(() => _images = [..._images, ...saved]);
    _notifyChanged();

    if (failure != null) {
      _toast(failure);
    } else if (tooMany) {
      _toast('已添加 ${saved.length} 张，最多 $kMaxNoteImages 张');
    }
    _focusEditorSoon();
  }

  Future<void> _removeImage(String name) async {
    setState(() {
      _images = _images.where((item) => item != name).toList();
    });
    _notifyChanged();
    _focusEditorSoon();
    try {
      await widget.controller.store.deleteImages([name]);
    } on FileSystemException catch (error) {
      debugPrint('删除速记图片失败：$error');
    }
  }

  Future<void> _save() async {
    final draft = _draft;
    if (_busy || draft.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.onSave(draft);
      if (!mounted) return;
      setState(() {
        _images = [];
        _busy = false;
      });
      _textController.clear();
      _focusEditorSoon();
    } catch (error) {
      if (!mounted) return;
      _toast('保存失败：$error');
      setState(() => _busy = false);
    }
  }

  Future<void> _openMain() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onOpenMain(_draft);
    } catch (error) {
      if (mounted) _toast('保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      // 这一层只给 CallbackShortcuts 当焦点宿主，不能 autofocus，
      // 否则会抢走下面 TextField 的 autofocus，呼出后没有光标。
      child: Focus(
        child: Scaffold(
          body: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) {
              return Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, (1 - value) * 8),
                  child: child,
                ),
              );
            },
            child: Column(
              children: [
                _buildHeader(theme),
                Expanded(child: _buildEditor(theme)),
                if (_images.isNotEmpty) _buildImageStrip(theme),
                _buildFooter(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: widget.onDragStart == null
          ? null
          : (_) => widget.onDragStart!(),
      child: Container(
        height: 56,
        padding: const EdgeInsets.only(left: 14, right: 8),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          border: Border(bottom: BorderSide(color: AppSurface.border(context))),
        ),
        child: Row(
          children: [
            Icon(
              Icons.drag_indicator_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF26A69A), Color(0xFF00796B)],
                ),
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 8),
            Text('快速记录', style: theme.textTheme.titleMedium),
            if (_pasting)
              const Padding(
                padding: EdgeInsets.only(left: 10),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                widget.hotkeyLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: '打开主界面',
              visualDensity: VisualDensity.compact,
              onPressed: _busy ? null : _openMain,
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
            ),
            IconButton(
              tooltip: '收起 (Esc)',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onClose,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: TextField(
        controller: _textController,
        focusNode: _focusNode,
        autofocus: true,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.7),
        decoration: InputDecoration(
          hintText: '记点什么…\n\nCtrl+V 粘贴文字或截图，Enter 换行。',
          contentPadding: const EdgeInsets.all(14),
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            height: 1.7,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  Widget _buildImageStrip(ThemeData theme) {
    return SizedBox(
      height: 74,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 14, 0),
        child: Row(
          children: [
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _images.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final name = _images[index];
                  final file = widget.controller.store.imageFile(name);
                  return _QuickImageTile(
                    file: file,
                    onRemove: () => _removeImage(name),
                    onPreview: () => _previewImage(file),
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${_images.length}/$kMaxNoteImages',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Ctrl+Enter 保存并收起 · Esc 收起且保留草稿',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _busy || _pasting || !_hasContent ? null : _save,
            icon: _busy
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded, size: 18),
            label: const Text('保存并收起'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _previewImage(File file) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.86),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              maxScale: 6,
              child: Image.file(
                file,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 56,
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton.filledTonal(
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickImageTile extends StatelessWidget {
  const _QuickImageTile({
    required this.file,
    required this.onRemove,
    required this.onPreview,
  });

  final File file;
  final VoidCallback onRemove;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 62,
      height: 62,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(9),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPreview,
              child: Image.file(
                file,
                fit: BoxFit.cover,
                cacheWidth: 124,
                errorBuilder: (context, error, stackTrace) => Icon(
                  Icons.broken_image_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
              ),
            ),
          ),
          Positioned(
            top: 3,
            right: 3,
            child: Tooltip(
              message: '移除图片',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.58),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 13,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
