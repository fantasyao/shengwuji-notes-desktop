import 'dart:convert';

/// 一条本地笔记。
///
/// 字段刻意与主 App 的 `diary.json` 保持兼容（uuid/content/created_at/tag/
/// archived），额外增加 `updated_at` 与 `images` 供电脑端本地使用。
/// `raw` 保存读入时的原始 Map，写回时先铺开再覆盖已知字段，未知字段不丢，
/// 为第二轮与手机同步留出余地。
/// 一条录音附件；[path] 为空表示云端有、本机还没下载。
class NoteAudio {
  const NoteAudio({
    required this.uuid,
    this.path,
    this.fileName,
    this.durationMs,
  });

  final String uuid;
  final String? path;
  final String? fileName;
  final int? durationMs;

  bool get isDownloaded => path != null && path!.isNotEmpty;

  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  factory NoteAudio.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final name = json['file_name'];
    final duration = json['duration_ms'];
    return NoteAudio(
      uuid: '${json['uuid'] ?? ''}',
      path: path is String && path.isNotEmpty ? path : null,
      fileName: name is String && name.isNotEmpty ? name : null,
      durationMs: duration is num ? duration.toInt() : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    if (path != null) 'path': path,
    if (fileName != null) 'file_name': fileName,
    if (durationMs != null) 'duration_ms': durationMs,
  };
}

class Note {
  const Note({
    required this.uuid,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.images = const [],
    this.audios = const [],
    this.tag,
    this.archived = false,
    this.raw = const {},
  });

  final String uuid;
  final String content;
  final List<String> images;
  final List<NoteAudio> audios;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? tag;
  final bool archived;
  final Map<String, dynamic> raw;

  bool get isEmpty => content.trim().isEmpty && images.isEmpty && audios.isEmpty;

  /// 正文首行，用于卡片标题；空笔记回退到占位文案。
  String get title {
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    if (images.isNotEmpty) return '图片笔记';
    if (audios.isNotEmpty) return '录音笔记';
    return '空笔记';
  }

  /// 卡片正文去掉首行标题后剩下的内容。
  String get body {
    final lines = content.split('\n');
    final index = lines.indexWhere((line) => line.trim().isNotEmpty);
    if (index < 0) return '';
    return lines.sublist(index + 1).join('\n').trim();
  }

  Note copyWith({
    String? content,
    List<String>? images,
    List<NoteAudio>? audios,
    DateTime? updatedAt,
    String? tag,
    bool clearTag = false,
    bool? archived,
  }) {
    return Note(
      uuid: uuid,
      content: content ?? this.content,
      images: images ?? this.images,
      audios: audios ?? this.audios,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tag: clearTag ? null : (tag ?? this.tag),
      archived: archived ?? this.archived,
      raw: raw,
    );
  }

  factory Note.fromJson(Map<String, dynamic> json) {
    final uuid = (json['uuid'] as String?)?.trim() ?? '';
    if (uuid.isEmpty) {
      throw const FormatException('笔记缺少 uuid');
    }
    final createdAt = _parseDate(json['created_at']);
    final updatedAt = _parseDate(json['updated_at']);
    return Note(
      uuid: uuid,
      content: (json['content'] as String?) ?? '',
      images: json['images'] is List
          ? (json['images'] as List)
                .whereType<String>()
                .where((name) => name.isNotEmpty)
                .toList(growable: false)
          : const [],
      audios: json['audios'] is List
          ? [
              for (final item in json['audios'] as List)
                if (item is Map)
                  NoteAudio.fromJson(
                    item.map((key, value) => MapEntry(key.toString(), value)),
                  ),
            ]
          : const [],
      createdAt:
          createdAt ??
          updatedAt ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: false),
      updatedAt:
          updatedAt ??
          createdAt ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: false),
      tag: json['tag'] is String ? json['tag'] as String : null,
      archived: json['archived'] == 1 || json['archived'] == true,
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      ...raw,
      'uuid': uuid,
      'content': content,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'images': List<String>.from(images),
      if (audios.isNotEmpty)
        'audios': [for (final audio in audios) audio.toJson()],
      'tag': tag,
      'archived': archived ? 1 : 0,
    };
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value);
  }
}

/// 云端/本地混用的 JSON 可能不是标准 Map 类型，统一在这里解码。
Map<String, dynamic>? decodeNoteMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

String encodeNotesPretty(List<Note> notes) {
  return const JsonEncoder.withIndent(
    '  ',
  ).convert(notes.map((note) => note.toJson()).toList());
}
