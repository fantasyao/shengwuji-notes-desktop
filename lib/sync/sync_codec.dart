import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'sync_models.dart';

/// v1 / v2 的 JSON 编解码。时间格式、布尔写法和字段集合以手机端 v17 为准。
class SyncCodec {
  static const int protocolVersion = 2;
  static const int minReaderVersion = 2;

  static const Uuid _uuid = Uuid();

  /// v1 只给文件名，没有附件 uuid；用笔记 uuid + 文件名生成稳定 id，
  /// 避免每次同步都当新附件插入、把已下载的本地路径丢掉。
  static String audioAttachmentUuid(String noteUuid, String syncName) {
    return _uuid.v5(Namespace.url.value, 'shengwuji/audio/$noteUuid/$syncName');
  }

  /// 手机截图附件的稳定 id：同一 (笔记, sha) 在任何电脑上算出同一 uuid，
  /// 下载回填本地路径后不会因 uuid 变化被当成新附件重新合并。
  static String mobileImageAttachmentUuid(String noteUuid, String sha256) {
    return _uuid.v5(
      Namespace.url.value,
      'shengwuji/image/$noteUuid/$sha256',
    );
  }

  /// 把 v1 的 `audio` / `duration` 与 v2 的音频附件统一成附件列表。
  ///
  /// 统一后 extras 里不再保留这两个字段，v1 投影时再从附件反写，保证两边
  /// 只有一份事实、载荷哈希也不会因为“下载后补了 sha256”而变化。
  static SyncNote normalizeAudio(SyncNote note) {
    final extras = Map<String, dynamic>.from(note.extras);
    final rawAudio = extras.remove('audio');
    final rawDuration = extras.remove('duration');
    final audioName = rawAudio is String
        ? SyncAttachment.safeBaseName(rawAudio)
        : '';
    final durationMs = _durationMs(rawDuration);

    final attachments = List<SyncAttachment>.from(note.attachments);
    final index = attachments.indexWhere((item) => item.isAudio);
    if (index >= 0) {
      final current = attachments[index];
      final name = current.syncName != null && current.syncName!.isNotEmpty
          ? current.syncName
          : (audioName.isEmpty ? null : audioName);
      final duration = current.durationMs ?? durationMs;
      final mime = current.mimeType ?? _audioMimeType(name);
      if (name != current.syncName ||
          duration != current.durationMs ||
          mime != current.mimeType) {
        attachments[index] = current.copyWith(
          syncName: name,
          durationMs: duration,
          mimeType: mime,
        );
      }
    } else if (audioName.isNotEmpty) {
      attachments.add(
        SyncAttachment(
          uuid: audioAttachmentUuid(note.uuid, audioName),
          kind: 'audio',
          origin: 'download',
          syncName: audioName,
          mimeType: _audioMimeType(audioName),
          durationMs: durationMs,
          sortOrder: 0,
        ),
      );
    }

    return note.copyWith(extras: extras, attachments: attachments);
  }

  /// v1 的 `duration` 是秒；兼容字符串形式的旧数据。
  static int? _durationMs(Object? value) {
    final seconds = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value.trim())
        : null;
    if (seconds == null || seconds < 0) return null;
    return (seconds * 1000).round();
  }

  static String? _audioMimeType(String? name) {
    if (name == null || name.isEmpty) return null;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    switch (name.substring(dot + 1).toLowerCase()) {
      case 'wav':
        return 'audio/wav';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      case 'flac':
        return 'audio/flac';
      default:
        return null;
    }
  }

  static const Set<String> _knownV1Keys = {
    'uuid',
    'content',
    'created_at',
    'updated_at',
    'archived',
    'locked',
    'tag',
    'sort_order',
  };

  static const Set<String> _knownV2NoteKeys = {
    'uuid',
    'content',
    'created_at',
    'updated_at',
    'rev',
    'mark',
    'archived',
    'locked',
    'sort_order',
    'tags',
    'attachments',
    'extras',
  };

  static const Set<String> _knownV2AttachmentKeys = {
    'uuid',
    'kind',
    'origin',
    'sha256',
    'name',
    'sync_name',
    'mime',
    'mime_type',
    'size',
    'byte_size',
    'duration_ms',
    'sort_order',
    'rev',
    'extras',
  };

  /// 手机端格式：本地时间、无 `Z`、毫秒。展示时会被当作本地时间。
  static String formatLocalNoZone(int milliseconds) {
    return DateTime.fromMillisecondsSinceEpoch(milliseconds).toIso8601String();
  }

  /// v2 格式：UTC、带 `Z`。
  static String formatUtc(int milliseconds) {
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
      isUtc: true,
    ).toIso8601String();
  }

  static int? parseIsoMs(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim())?.toUtc().millisecondsSinceEpoch;
  }

  static String nowLocal() => DateTime.now().toIso8601String();

  // ----- v1 manifest -----

  static ManifestV1 parseManifestV1(Object? decoded) {
    if (decoded is! Map) {
      throw const FormatException('manifest.json 顶层不是对象');
    }
    final raw = decoded.map((key, value) => MapEntry(key.toString(), value));
    final v = raw['v'] is num ? (raw['v'] as num).toInt() : 1;
    SyncLock? lock;
    final rawLock = raw['lock'];
    if (rawLock is Map) {
      final deviceId = rawLock['device_id'];
      final at = rawLock['at'];
      if (deviceId is String && at is String) {
        lock = SyncLock(deviceId: deviceId, at: at);
      }
    }
    final counts = <String, int>{};
    final rawCounts = raw['counts'];
    if (rawCounts is Map) {
      rawCounts.forEach((key, value) {
        if (value is num) counts[key.toString()] = value.toInt();
      });
    }
    return ManifestV1(raw: raw, v: v, lock: lock, counts: counts);
  }

  /// 获取锁：保留 manifest 其它字段，只改 lock / updated_at / device_id。
  static Map<String, dynamic> acquireLockV1(
    Map<String, dynamic>? existing,
    String deviceId,
  ) {
    final now = nowLocal();
    final next = <String, dynamic>{...(existing ?? const {})};
    next['v'] = existing?['v'] is num ? existing!['v'] : 1;
    next['device_id'] = deviceId;
    next['updated_at'] = now;
    next['lock'] = {'device_id': deviceId, 'at': now};
    return next;
  }

  static Map<String, dynamic> releaseLockV1(
    Map<String, dynamic>? existing,
    String deviceId,
    Map<String, int> counts,
  ) {
    final next = <String, dynamic>{...(existing ?? const {})};
    next['v'] = existing?['v'] is num ? existing!['v'] : 1;
    next['device_id'] = deviceId;
    next['updated_at'] = nowLocal();
    next['lock'] = null;
    next['counts'] = counts;
    return next;
  }

  // ----- v1 diary -----

  static V1ParseResult parseDiaryV1(Object? decoded) {
    final notes = <SyncNote>[];
    final preserved = <Map<String, dynamic>>[];
    var skipped = 0;
    if (decoded == null) {
      return const V1ParseResult(notes: [], preservedRows: [], skipped: 0);
    }
    if (decoded is! List) {
      throw const FormatException('diary.json 顶层不是数组');
    }
    for (final item in decoded) {
      if (item is! Map) {
        skipped++;
        continue;
      }
      final raw = item.map((key, value) => MapEntry(key.toString(), value));
      final uuid = (raw['uuid'] as String?)?.trim() ?? '';
      final content = raw['content'];
      final createdAt = parseIsoMs(raw['created_at']);
      if (uuid.isEmpty || content is! String || createdAt == null) {
        preserved.add(raw);
        skipped++;
        continue;
      }
      final extras = <String, dynamic>{};
      for (final entry in raw.entries) {
        if (_knownV1Keys.contains(entry.key)) continue;
        extras[entry.key] = entry.value;
      }
      for (final key in const ['audio', 'duration']) {
        if (raw[key] != null) extras[key] = raw[key];
      }
      notes.add(
        normalizeAudio(
          SyncNote(
            uuid: uuid,
            content: content,
            createdAt: createdAt,
            updatedAt: createdAt,
            mark: raw['tag'] is String ? raw['tag'] as String : null,
            archived: _isOne(raw['archived']),
            locked: _isOne(raw['locked']),
            sortOrder: raw['sort_order'] is num
                ? (raw['sort_order'] as num).toInt()
                : null,
            rev: 1,
            extras: extras,
          ),
        ),
      );
    }
    return V1ParseResult(
      notes: notes,
      preservedRows: preserved,
      skipped: skipped,
    );
  }

  /// 生成给手机 v17 看的投影。只写它认识的字段，布尔必须是 1 或省略。
  static List<Map<String, dynamic>> encodeDiaryV1(
    List<SyncNote> notes,
    List<Map<String, dynamic>> preservedRows,
  ) {
    final sorted = List<SyncNote>.from(notes)
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.uuid.compareTo(b.uuid);
      });
    final rows = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final source in sorted) {
      final note = normalizeAudio(source);
      final row = <String, dynamic>{};
      for (final entry in note.extras.entries) {
        if (_knownV1Keys.contains(entry.key)) continue;
        row[entry.key] = entry.value;
      }
      row['uuid'] = note.uuid;
      row['content'] = note.content;
      row['created_at'] = formatLocalNoZone(note.createdAt);
      if (note.archived) row['archived'] = 1;
      if (note.locked) row['locked'] = 1;
      if (note.mark != null && note.mark!.isNotEmpty) row['tag'] = note.mark;
      if (!note.archived && note.sortOrder != null) {
        row['sort_order'] = note.sortOrder;
      }
      final audio = _firstAudio(note);
      if (audio != null) {
        final name = audio.syncName ?? audio.assetFileName;
        if (name != null && name.isNotEmpty) row['audio'] = name;
        if (audio.durationMs != null) {
          row['duration'] = (audio.durationMs! / 1000).round();
        }
      }
      rows.add(row);
      seen.add(note.uuid);
    }
    for (final row in preservedRows) {
      final uuid = row['uuid'];
      if (uuid is String && uuid.isNotEmpty && seen.contains(uuid)) continue;
      rows.add(Map<String, dynamic>.from(row));
    }
    return rows;
  }

  // ----- v2 manifest -----

  static ManifestV2 parseManifestV2(Object? decoded) {
    if (decoded is! Map) {
      throw const FormatException('v2/manifest.json 顶层不是对象');
    }
    final raw = decoded.map((key, value) => MapEntry(key.toString(), value));
    final protocol = raw['protocol_version'] is num
        ? (raw['protocol_version'] as num).toInt()
        : 1;
    final minReader = raw['min_reader_version'] is num
        ? (raw['min_reader_version'] as num).toInt()
        : 1;
    final writers = raw['writers'] is Map
        ? (raw['writers'] as Map).map(
            (key, value) => MapEntry(key.toString(), value),
          )
        : <String, dynamic>{};
    return ManifestV2(
      raw: raw,
      protocolVersion: protocol,
      minReaderVersion: minReader,
      writers: writers,
    );
  }

  static void ensureSupported(ManifestV2 manifest) {
    if (manifest.protocolVersion > protocolVersion ||
        manifest.minReaderVersion > minReaderVersion) {
      throw const FormatException('远端同步协议版本高于本机支持，已停止同步');
    }
  }

  static Map<String, dynamic> encodeManifestV2({
    required ManifestV2? previous,
    required String deviceId,
    required int nowMs,
    required Map<String, int> counts,
  }) {
    final writers = <String, dynamic>{...(previous?.writers ?? const {})};
    writers[deviceId] = {
      'protocol': protocolVersion,
      'last_seen': formatUtc(nowMs),
    };
    return {
      ...(previous?.raw ?? const {}),
      'format': 'shengwuji.manifest',
      'protocol_version': protocolVersion,
      'min_reader_version': minReaderVersion,
      'device_id': deviceId,
      'updated_at': formatUtc(nowMs),
      'last_writer': deviceId,
      'writers': writers,
      'counts': counts,
    };
  }

  // ----- v2 notes -----

  static List<SyncNote> parseNotesV2(Object? decoded) {
    if (decoded == null) return const [];
    if (decoded is! Map) {
      throw const FormatException('v2/notes.json 顶层不是对象');
    }
    final rawNotes = decoded['notes'];
    if (rawNotes is! List) {
      throw const FormatException('v2/notes.json 缺少 notes 数组');
    }
    final notes = <SyncNote>[];
    for (final item in rawNotes) {
      if (item is! Map) continue;
      final raw = item.map((key, value) => MapEntry(key.toString(), value));
      final uuid = (raw['uuid'] as String?)?.trim() ?? '';
      final content = raw['content'];
      final createdAt = parseIsoMs(raw['created_at']);
      final updatedAt = parseIsoMs(raw['updated_at']) ?? createdAt;
      if (uuid.isEmpty ||
          content is! String ||
          createdAt == null ||
          updatedAt == null) {
        continue;
      }
      final extras = <String, dynamic>{};
      final rawExtras = raw['extras'];
      if (rawExtras is Map) {
        rawExtras.forEach((key, value) {
          extras[key.toString()] = value;
        });
      }
      for (final entry in raw.entries) {
        if (_knownV2NoteKeys.contains(entry.key)) continue;
        extras[entry.key] = entry.value;
      }
      final tags = raw['tags'];
      if (tags is List && tags.isNotEmpty) {
        extras['tags'] = List<dynamic>.from(tags);
      }
      notes.add(
        normalizeAudio(
          SyncNote(
            uuid: uuid,
            content: content,
            createdAt: createdAt,
            updatedAt: updatedAt,
            mark: raw['mark'] is String ? raw['mark'] as String : null,
            archived: _isTrue(raw['archived']),
            locked: _isTrue(raw['locked']),
            sortOrder: raw['sort_order'] is num
                ? (raw['sort_order'] as num).toInt()
                : null,
            rev: raw['rev'] is num ? (raw['rev'] as num).toInt() : 1,
            extras: extras,
            attachments: _parseAttachments(raw['attachments']),
          ),
        ),
      );
    }
    return notes;
  }

  static Map<String, dynamic> encodeNotesV2({
    required List<SyncNote> notes,
    required String deviceId,
    required int nowMs,
  }) {
    return {
      'format': 'shengwuji.notes',
      'version': protocolVersion,
      'generated_at': formatUtc(nowMs),
      'device_id': deviceId,
      'notes': [for (final note in notes) _encodeNoteV2(note)],
    };
  }

  static Map<String, dynamic> _encodeNoteV2(SyncNote source) {
    final note = normalizeAudio(source);
    final extras = <String, dynamic>{};
    for (final entry in note.extras.entries) {
      if (_knownV2NoteKeys.contains(entry.key)) continue;
      extras[entry.key] = entry.value;
    }
    final tags = note.extras['tags'];
    return {
      'uuid': note.uuid,
      'content': note.content,
      'created_at': formatUtc(note.createdAt),
      'updated_at': formatUtc(note.updatedAt),
      'rev': note.rev,
      'mark': note.mark,
      'archived': note.archived,
      'locked': note.locked,
      'sort_order': note.sortOrder,
      'tags': tags is List ? tags : const [],
      'attachments': [
        for (final attachment in note.attachments)
          _encodeAttachmentV2(attachment),
      ],
      'extras': extras,
    };
  }

  // ----- v2 tombstones -----

  static TombstoneParseResult parseTombstonesV2(Object? decoded) {
    if (decoded == null) {
      return const TombstoneParseResult(tombstones: {}, preservedRows: []);
    }
    if (decoded is! Map) {
      throw const FormatException('v2/tombstones.json 顶层不是对象');
    }
    final rawTombstones = decoded['tombstones'];
    if (rawTombstones is! List) {
      return const TombstoneParseResult(tombstones: {}, preservedRows: []);
    }
    final tombstones = <String, NoteTombstone>{};
    final preserved = <Map<String, dynamic>>[];
    for (final item in rawTombstones) {
      if (item is! Map) continue;
      final raw = item.map((key, value) => MapEntry(key.toString(), value));
      if (raw['entity'] != 'note') {
        preserved.add(raw);
        continue;
      }
      final uuid = (raw['uuid'] as String?)?.trim() ?? '';
      final deletedAt = parseIsoMs(raw['deleted_at']);
      if (uuid.isEmpty || deletedAt == null) continue;
      tombstones[uuid] = NoteTombstone(
        uuid: uuid,
        deletedAt: deletedAt,
        rev: raw['rev'] is num ? (raw['rev'] as num).toInt() : 1,
        origin: raw['origin'] is String ? raw['origin'] as String : 'remote',
      );
    }
    return TombstoneParseResult(
      tombstones: tombstones,
      preservedRows: preserved,
    );
  }

  static Map<String, dynamic> encodeTombstonesV2({
    required Map<String, NoteTombstone> tombstones,
    required List<Map<String, dynamic>> preservedRows,
    required int nowMs,
  }) {
    return {
      'format': 'shengwuji.tombstones',
      'version': protocolVersion,
      'generated_at': formatUtc(nowMs),
      'tombstones': [
        for (final item in preservedRows) item,
        for (final tombstone in tombstones.values)
          {
            'entity': 'note',
            'uuid': tombstone.uuid,
            'deleted_at': formatUtc(tombstone.deletedAt),
            'rev': tombstone.rev,
            'origin': tombstone.origin,
          },
      ],
    };
  }

  // ----- 手机截图索引（image_index.json） -----

  /// 解析 `image_index.json`。顶层必须是数组；坏行跳过计数，不抛错。
  /// 调用方需区分「文件不存在」（present=false）与「存在但解析失败」，
  /// 后者不能当成空索引，否则会误摘本机已有的手机附件。
  static ImageIndexParseResult parseImageIndex(Object? decoded) {
    if (decoded is! List) {
      throw const FormatException('image_index.json 顶层不是数组');
    }
    final byKey = <String, SyncImageEntry>{};
    var skipped = 0;
    for (final item in decoded) {
      if (item is! Map) {
        skipped++;
        continue;
      }
      final raw = item.map((key, value) => MapEntry(key.toString(), value));
      final noteUuid = (raw['note_uuid'] ?? raw['uuid'] ?? '')
          .toString()
          .trim();
      final sha = (raw['sha256'] ?? '').toString().trim().toLowerCase();
      final rawName = (raw['name'] ?? '').toString();
      final name = rawName.isEmpty
          ? ''
          : SyncAttachment.safeBaseName(rawName);
      final entry = SyncImageEntry(
        noteUuid: noteUuid,
        deviceId: (raw['device_id'] ?? '').toString().trim(),
        sha256: sha,
        name: name,
        mimeType: raw['mime'] is String
            ? (raw['mime'] as String).trim()
            : null,
        byteSize: raw['size'] is num ? (raw['size'] as num).toInt() : null,
        updatedAt: parseIsoMs(raw['updated_at']),
        position: raw['position'] is num
            ? (raw['position'] as num).toInt().clamp(0, 100000)
            : 0,
        source: (raw['source'] ?? '').toString().trim() == 'desktop'
            ? 'desktop'
            : 'mobile',
      );
      if (!entry.isValid) {
        skipped++;
        continue;
      }
      // 同一 (笔记, 设备, sha) 只认最新一条；不同 sha 可并存（多图）。
      final current = byKey[entry.key];
      if (current == null ||
          (entry.updatedAt ?? 0) >= (current.updatedAt ?? 0)) {
        byKey[entry.key] = entry;
      }
    }
    return ImageIndexParseResult(
      entries: List<SyncImageEntry>.unmodifiable(byKey.values),
      skipped: skipped,
    );
  }

  /// 编码图片索引：按 (note_uuid, device_id, position, sha256) 稳定排序，
  /// 避免顺序抖动导致每轮都重写。
  static String encodeImageIndex(List<SyncImageEntry> entries) {
    final sorted = List<SyncImageEntry>.from(entries)
      ..sort((a, b) {
        final byNote = a.noteUuid.compareTo(b.noteUuid);
        if (byNote != 0) return byNote;
        final byDevice = a.deviceId.compareTo(b.deviceId);
        if (byDevice != 0) return byDevice;
        final byPosition = a.position.compareTo(b.position);
        return byPosition != 0 ? byPosition : a.sha256.compareTo(b.sha256);
      });
    return const JsonEncoder.withIndent('  ').convert([
      for (final entry in sorted) entry.toJson(),
    ]);
  }

  // ----- helpers -----

  /// v1 只能表达一条音频；多条时取排序最靠前的一条。
  static SyncAttachment? _firstAudio(SyncNote note) {
    final audios = note.attachments.where((item) => item.isAudio).toList()
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.uuid.compareTo(b.uuid);
      });
    return audios.isEmpty ? null : audios.first;
  }

  static List<SyncAttachment> _parseAttachments(Object? value) {
    if (value is! List) return const [];
    final attachments = <SyncAttachment>[];
    for (final item in value) {
      if (item is! Map) continue;
      final raw = item.map((key, source) => MapEntry(key.toString(), source));
      final uuid = (raw['uuid'] as String?)?.trim() ?? '';
      final kind = raw['kind'] is String ? raw['kind'] as String : 'file';
      if (uuid.isEmpty) continue;
      final extras = <String, dynamic>{};
      final rawExtras = raw['extras'];
      if (rawExtras is Map) {
        rawExtras.forEach((key, source) {
          extras[key.toString()] = source;
        });
      }
      for (final entry in raw.entries) {
        if (_knownV2AttachmentKeys.contains(entry.key)) continue;
        extras[entry.key] = entry.value;
      }
      final sha = raw['sha256'];
      final name = raw['name'] ?? raw['sync_name'];
      attachments.add(
        SyncAttachment(
          uuid: uuid,
          kind: kind,
          origin: raw['origin'] is String
              ? raw['origin'] as String
              : 'download',
          sha256: sha is String && sha.isNotEmpty ? sha : null,
          syncName: name is String && name.isNotEmpty ? name : null,
          mimeType: raw['mime'] is String
              ? raw['mime'] as String
              : raw['mime_type'] is String
              ? raw['mime_type'] as String
              : null,
          byteSize: raw['size'] is num
              ? (raw['size'] as num).toInt()
              : raw['byte_size'] is num
              ? (raw['byte_size'] as num).toInt()
              : null,
          durationMs: raw['duration_ms'] is num
              ? (raw['duration_ms'] as num).toInt()
              : null,
          sortOrder: raw['sort_order'] is num
              ? (raw['sort_order'] as num).toInt()
              : 0,
          rev: raw['rev'] is num ? (raw['rev'] as num).toInt() : 1,
          extras: extras,
        ),
      );
    }
    return attachments;
  }

  static Map<String, dynamic> _encodeAttachmentV2(SyncAttachment attachment) {
    return {
      'uuid': attachment.uuid,
      'kind': attachment.kind,
      'origin': attachment.origin,
      'sha256': attachment.sha256,
      'name': attachment.syncName ?? attachment.assetFileName,
      'mime': attachment.mimeType,
      'size': attachment.byteSize,
      'duration_ms': attachment.durationMs,
      'sort_order': attachment.sortOrder,
      'rev': attachment.rev,
      'extras': attachment.extras,
    };
  }

  static bool _isOne(Object? value) => value == 1;

  static bool _isTrue(Object? value) => value == true || value == 1;

  static Object? tryDecode(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return jsonDecode(trimmed);
  }
}

class SyncLock {
  const SyncLock({required this.deviceId, required this.at});

  final String deviceId;
  final String at;

  static const Duration staleAfter = Duration(minutes: 10);

  /// `at` 解析失败按过期处理，避免一个坏锁永久挡住同步。
  bool isStale(DateTime now) {
    final parsed = DateTime.tryParse(at);
    if (parsed == null) return true;
    return now.difference(parsed) > staleAfter;
  }
}

class ManifestV1 {
  const ManifestV1({
    required this.raw,
    required this.v,
    required this.lock,
    required this.counts,
  });

  final Map<String, dynamic> raw;
  final int v;
  final SyncLock? lock;
  final Map<String, int> counts;
}

class ManifestV2 {
  const ManifestV2({
    required this.raw,
    required this.protocolVersion,
    required this.minReaderVersion,
    required this.writers,
  });

  final Map<String, dynamic> raw;
  final int protocolVersion;
  final int minReaderVersion;
  final Map<String, dynamic> writers;
}

class V1ParseResult {
  const V1ParseResult({
    required this.notes,
    required this.preservedRows,
    required this.skipped,
  });

  final List<SyncNote> notes;
  final List<Map<String, dynamic>> preservedRows;
  final int skipped;
}

class TombstoneParseResult {
  const TombstoneParseResult({
    required this.tombstones,
    required this.preservedRows,
  });

  final Map<String, NoteTombstone> tombstones;
  final List<Map<String, dynamic>> preservedRows;
}

class ImageIndexParseResult {
  const ImageIndexParseResult({required this.entries, required this.skipped});

  final List<SyncImageEntry> entries;
  final int skipped;
}
