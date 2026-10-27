import 'dart:io';

import 'package:flutter/material.dart';

import '../data/note_store.dart';
import '../models/note.dart';
import '../theme/app_theme.dart';
import '../utils/date_format.dart';
import 'link_text.dart';

/// 瀑布流里的一张笔记卡片。整卡可点开编辑，右上角删除按钮悬停时出现。
class NoteCard extends StatefulWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.store,
    required this.onOpen,
    required this.onCopy,
    required this.onDelete,
    this.onOpenLink,
  });

  final Note note;
  final NoteStore store;
  final VoidCallback onOpen;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  /// 打开正文里的 http(s) 链接；null 时用系统默认浏览器
  final LinkOpenCallback? onOpenLink;

  @override
  State<NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<NoteCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = widget.note;
    final title = note.title;
    final body = note.body;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: AppSurface.card(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hovered
                ? theme.colorScheme.primary.withValues(alpha: 0.55)
                : AppSurface.border(context),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: theme.brightness == Brightness.dark
                    ? (_hovered ? 0.28 : 0.14)
                    : (_hovered ? 0.10 : 0.045),
              ),
              blurRadius: _hovered ? 18 : 10,
              offset: Offset(0, _hovered ? 6 : 3),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: widget.onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (note.tag != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 7, right: 8),
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _tagColor(note.tag!),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                      Expanded(
                        child: LinkText(
                          text: title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          onOpenLink: widget.onOpenLink,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                            color: title == '空笔记'
                                ? theme.colorScheme.onSurfaceVariant
                                : null,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: IgnorePointer(
                          ignoring: !_hovered,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 120),
                            opacity: _hovered ? 1 : 0,
                            child: IconButton(
                              tooltip: '复制正文',
                              padding: EdgeInsets.zero,
                              iconSize: 20,
                              onPressed: widget.onCopy,
                              icon: Icon(
                                Icons.copy_rounded,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: IgnorePointer(
                          ignoring: !_hovered,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 120),
                            opacity: _hovered ? 1 : 0,
                            child: IconButton(
                              tooltip: '移入回收站',
                              padding: EdgeInsets.zero,
                              iconSize: 18,
                              onPressed: widget.onDelete,
                              icon: Icon(
                                Icons.delete_outline_rounded,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    LinkText(
                      text: body,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      onOpenLink: widget.onOpenLink,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.65,
                      ),
                    ),
                  ],
                  if (note.images.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _CardImages(note: note, store: widget.store),
                  ],
                  if (note.audios.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _CardAudio(note: note),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.schedule_rounded,
                        size: 13,
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.75,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        formatNoteTime(note.createdAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.85,
                          ),
                        ),
                      ),
                      if (note.images.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Icon(
                          Icons.image_outlined,
                          size: 13,
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '${note.images.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _tagColor(String tag) {
    switch (tag) {
      case 'urgent':
        return const Color(0xFFE53935);
      case 'star':
        return const Color(0xFFF9A825);
      case 'idea':
        return const Color(0xFF8E24AA);
      case 'task':
        return const Color(0xFF1E88E5);
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }
}

class _CardAudio extends StatelessWidget {
  const _CardAudio({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = note.audios.first;
    final label = note.audios.length > 1
        ? '录音 ${note.audios.length} 段'
        : '录音 ${formatAudioDurationMs(first.durationMs)}';
    final pending = note.audios.any((audio) => !audio.isDownloaded);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.graphic_eq_rounded,
            size: 15,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              pending ? '$label · 待下载' : label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: pending
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardImages extends StatelessWidget {
  const _CardImages({required this.note, required this.store});

  final Note note;
  final NoteStore store;

  @override
  Widget build(BuildContext context) {
    final shown = note.images.take(4).toList(growable: false);
    final single = shown.length == 1;

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 6.0;
        final width = single
            ? constraints.maxWidth
            : (constraints.maxWidth - spacing) / 2;
        final height = single ? 164.0 : 92.0;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var index = 0; index < shown.length; index++)
              SizedBox(
                width: width,
                height: height,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _LocalImage(
                        file: store.imageFile(shown[index]),
                        cacheWidth: single ? 900 : 420,
                      ),
                      if (index == 3 && note.images.length > 4)
                        ColoredBox(
                          color: Colors.black.withValues(alpha: 0.52),
                          child: Center(
                            child: Text(
                              '+${note.images.length - 4}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LocalImage extends StatelessWidget {
  const _LocalImage({required this.file, required this.cacheWidth});

  final File file;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    return Image.file(
      file,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) {
        return ColoredBox(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Icon(
            Icons.broken_image_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
