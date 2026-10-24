import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 一条参与同步的笔记（本地 SQLite 或远端 v2 的统一形态）。
class SyncNote {
  SyncNote({
    required this.uuid,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.mark,
    this.archived = false,
    this.locked = false,
    this.sortOrder,
    this.rev = 1,
    Map<String, dynamic>? extras,
    List<SyncAttachment>? attachments,
  }) : extras = extras ?? const {},
       attachments = attachments ?? const [];

  final String uuid;
  final String content;
  final int createdAt;
  final int updatedAt;
  final String? mark;
  final bool archived;
  final bool locked;
  final int? sortOrder;
  final int rev;

  /// 协议不认识的字段；v1 的 `audio` / `duration` 也暂存在这里。
  final Map<String, dynamic> extras;
  final List<SyncAttachment> attachments;

  /// 用于三方合并的载荷指纹：内容、标注、归档、锁定、排序、附件集合、未知字段。
  late final String payloadHash = _hashPayload();

  SyncNote copyWith({
    String? uuid,
    String? content,
    int? createdAt,
    int? updatedAt,
    String? mark,
    bool clearMark = false,
    bool? archived,
    bool? locked,
    int? sortOrder,
    bool clearSortOrder = false,
    int? rev,
    Map<String, dynamic>? extras,
    List<SyncAttachment>? attachments,
  }) {
    return SyncNote(
      uuid: uuid ?? this.uuid,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      mark: clearMark ? null : (mark ?? this.mark),
      archived: archived ?? this.archived,
      locked: locked ?? this.locked,
      sortOrder: clearSortOrder ? null : (sortOrder ?? this.sortOrder),
      rev: rev ?? this.rev,
      extras: extras ?? this.extras,
      attachments: attachments ?? this.attachments,
    );
  }

  String _hashPayload() {
    final attachmentKeys = attachments.map(_attachmentKey).toList()..sort();
    final extraKeys = extras.keys.toList()..sort();
    final payload = jsonEncode([
      content,
      mark,
      archived,
      locked,
      sortOrder,
      attachmentKeys,
      [
        for (final key in extraKeys) [key, extras[key]],
      ],
    ]);
    return sha256.convert(utf8.encode(payload)).toString();
  }

  /// 音频的远端文件名（basename）跨设备稳定；下载后回填的 sha256 不能让
  /// 载荷看起来“变过”，否则每轮同步都会把它当成远端新改动重新覆盖。
  String _attachmentKey(SyncAttachment item) {
    if (item.isAudio) {
      final name = item.syncName;
      if (name != null && name.isNotEmpty) return 'audio:$name';
    }
    return '${item.kind}:${item.sha256 ?? item.syncName ?? ''}';
  }

  /// 自然键：吸收“备份导入后重新生成 uuid”的历史数据。
  String get naturalKey => '$content|$createdAt';
}

class SyncAttachment {
  const SyncAttachment({
    required this.uuid,
    required this.kind,
    this.origin = 'import',
    this.sha256,
    this.storagePath,
    this.syncName,
    this.mimeType,
    this.byteSize,
    this.durationMs,
    this.sortOrder = 0,
    this.rev = 1,
    this.extras = const {},
  });

  final String uuid;
  final String kind;
  final String origin;
  final String? sha256;

  /// 本地相对路径；为空表示“云端有、本机未下载”。
  final String? storagePath;

  /// 与手机端兼容的 basename（v1 音频），也是资源的远端文件名。
  final String? syncName;
  final String? mimeType;
  final int? byteSize;
  final int? durationMs;
  final int sortOrder;
  final int rev;
  final Map<String, dynamic> extras;

  bool get isImage => kind == 'image';

  bool get isAudio => kind == 'audio';

  SyncAttachment copyWith({
    String? uuid,
    String? kind,
    String? origin,
    String? sha256,
    String? storagePath,
    String? syncName,
    String? mimeType,
    int? byteSize,
    int? durationMs,
    int? sortOrder,
    int? rev,
    Map<String, dynamic>? extras,
  }) {
    return SyncAttachment(
      uuid: uuid ?? this.uuid,
      kind: kind ?? this.kind,
      origin: origin ?? this.origin,
      sha256: sha256 ?? this.sha256,
      storagePath: storagePath ?? this.storagePath,
      syncName: syncName ?? this.syncName,
      mimeType: mimeType ?? this.mimeType,
      byteSize: byteSize ?? this.byteSize,
      durationMs: durationMs ?? this.durationMs,
      sortOrder: sortOrder ?? this.sortOrder,
      rev: rev ?? this.rev,
      extras: extras ?? this.extras,
    );
  }

  /// 内容寻址的远端文件名：`<sha>.<ext>`；没有哈希时退回 basename。
  String? get assetFileName {
    final hash = sha256;
    if (hash != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      final extension = _extension;
      return extension.isEmpty ? hash : '$hash.$extension';
    }
    final name = syncName;
    if (name != null && name.isNotEmpty) return safeBaseName(name);
    return null;
  }

  String get _extension {
    for (final candidate in [syncName, storagePath]) {
      if (candidate == null) continue;
      final dot = candidate.lastIndexOf('.');
      if (dot >= 0 && dot < candidate.length - 1) {
        return candidate.substring(dot + 1).toLowerCase();
      }
    }
    final mime = mimeType;
    if (mime != null && mime.contains('/')) {
      final subtype = mime.split('/').last.toLowerCase();
      if (subtype == 'jpeg') return 'jpg';
      if (subtype == 'svg+xml') return '';
      return subtype.replaceAll(RegExp(r'[^a-z0-9]'), '');
    }
    return '';
  }

  /// 远端路径或完整文件名都收敛成安全的 basename。
  static String safeBaseName(String value) {
    final normalized = value.trim().replaceAll(r'\', '/');
    final last = normalized.split('/').last;
    return last.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
  }
}

/// 手机端 `image_index.json` 的一条截图索引（手机 → 电脑单向）。
///
/// 图片本体在 `v2/assets/<sha 前两位>/<sha>.<ext>`（与桌面端内容寻址同
/// 目录）；这里只保留挂接信息。手机端按 (note_uuid, device_id) 归属，
/// 电脑端只读不改，因此不需要回写。
class SyncImageEntry {
  SyncImageEntry({
    required this.noteUuid,
    required this.deviceId,
    required this.sha256,
    required this.name,
    this.mimeType,
    this.byteSize,
    this.updatedAt,
  });

  final String noteUuid;
  final String deviceId;

  /// 小写 64 位十六进制内容哈希。
  final String sha256;

  /// 云端文件名（已收敛为 basename），通常是 `<sha>.<ext>`。
  final String name;

  final String? mimeType;
  final int? byteSize;

  /// 手机写入时间（线上是 ISO UTC 字符串，解析后为毫秒）；同一笔记多设备时取最新一张。
  final int? updatedAt;

  static final RegExp _shaPattern = RegExp(r'^[0-9a-f]{64}$');

  bool get isValid =>
      noteUuid.isNotEmpty &&
      _shaPattern.hasMatch(sha256) &&
      name.isNotEmpty &&
      !name.contains('/') &&
      !name.contains(r'\') &&
      !name.contains('..');

  /// 远端相对路径（桌面端按同规则推导资产地址）。
  String get remotePath => 'v2/assets/${sha256.substring(0, 2)}/$name';
}

class NoteTombstone {
  const NoteTombstone({
    required this.uuid,
    required this.deletedAt,
    this.rev = 1,
    this.origin = 'local',
  });

  final String uuid;
  final int deletedAt;
  final int rev;
  final String origin;
}

/// 本地同步状态：上次成功同步的载荷基线，以及远端版本标记。
class SyncState {
  SyncState({
    Map<String, String>? bases,
    this.lastSyncAt,
    Map<String, String>? remoteRevisions,
    Map<String, String>? remoteEtags,
  }) : bases = bases ?? {},
       remoteRevisions = remoteRevisions ?? {},
       remoteEtags = remoteEtags ?? {};

  /// uuid → 上次同步成功时该笔记的 [SyncNote.payloadHash]。
  final Map<String, String> bases;
  final int? lastSyncAt;

  /// 远端路径 → ETag/Last-Modified，用来跳过未变化的文件。
  final Map<String, String> remoteRevisions;

  /// 主数据文件 → 上次同步结束时的远端版本，供定时轮询做轻量比较。
  final Map<String, String> remoteEtags;

  Map<String, dynamic> toJson() => {
    'bases': bases,
    if (lastSyncAt != null) 'last_sync_at': lastSyncAt,
    'remote_revisions': remoteRevisions,
    if (remoteEtags.isNotEmpty) 'remote_etags': remoteEtags,
  };

  factory SyncState.fromJson(Map<String, dynamic> json) {
    final rawBases = json['bases'];
    final rawRevisions = json['remote_revisions'];
    final rawEtags = json['remote_etags'];
    final lastSyncAt = json['last_sync_at'];
    Map<String, String> strings(Object? raw) => raw is Map
        ? {
            for (final entry in raw.entries)
              if (entry.value is String)
                entry.key.toString(): entry.value as String,
          }
        : {};
    return SyncState(
      bases: strings(rawBases),
      lastSyncAt: lastSyncAt is num ? lastSyncAt.toInt() : null,
      remoteRevisions: strings(rawRevisions),
      remoteEtags: strings(rawEtags),
    );
  }
}

class SyncStats {
  const SyncStats({
    this.importedFromV1 = 0,
    this.appliedRemote = 0,
    this.keptLocal = 0,
    this.conflictCopies = 0,
    this.remoteDeletions = 0,
    this.assetsUploaded = 0,
    this.assetsDownloaded = 0,
    this.audioDownloaded = 0,
  });

  final int importedFromV1;
  final int appliedRemote;
  final int keptLocal;
  final int conflictCopies;
  final int remoteDeletions;
  final int assetsUploaded;
  final int assetsDownloaded;
  final int audioDownloaded;
}

class SyncResult {
  const SyncResult({
    required this.at,
    this.stats = const SyncStats(),
    this.warnings = const [],
  });

  final DateTime at;
  final SyncStats stats;
  final List<String> warnings;
}
