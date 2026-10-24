import 'package:uuid/uuid.dart';

import 'sync_codec.dart';
import 'sync_models.dart';

class MergeInput {
  MergeInput({
    required this.localNotes,
    required this.localTombstones,
    required this.remoteV1Notes,
    required this.remoteV1PreservedRows,
    required this.remoteV2Notes,
    required this.remoteTombstones,
    required this.bases,
    required this.nowMs,
    this.v1Skipped = 0,
    this.remoteImages = const [],
    this.imageIndexPresent = false,
  });

  final List<SyncNote> localNotes;
  final Map<String, NoteTombstone> localTombstones;
  final List<SyncNote> remoteV1Notes;
  final List<Map<String, dynamic>> remoteV1PreservedRows;
  final List<SyncNote> remoteV2Notes;
  final Map<String, NoteTombstone> remoteTombstones;

  /// uuid → 上次成功同步时的载荷哈希。
  final Map<String, String> bases;
  final int nowMs;
  final int v1Skipped;

  /// 手机端 image_index.json 的条目（旁路附件，不参与 LWW）。
  final List<SyncImageEntry> remoteImages;

  /// 索引文件是否真实存在且解析成功。false = 不可用，本轮不增删手机附件，
  /// 避免索引暂时读不到时把电脑端已有的截图摘掉。
  final bool imageIndexPresent;
}

class MergeOutput {
  MergeOutput({
    required this.notes,
    required this.tombstones,
    required this.preservedV1Rows,
    required this.stats,
    required this.warnings,
  });

  final List<SyncNote> notes;
  final Map<String, NoteTombstone> tombstones;
  final List<Map<String, dynamic>> preservedV1Rows;
  final SyncStats stats;
  final List<String> warnings;
}

/// 三方合并：v1 只吸收新增，v2 用基线哈希 + LWW 收敛。
///
/// 时间戳只决定“谁赢”；只有在双方都改过、且时间接近时才生成冲突副本，
/// 避免手机端 P1 全量回传被误判成冲突。
class SyncMerger {
  SyncMerger({Uuid? uuid, this.conflictWindow = const Duration(minutes: 5)})
    : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;
  final Duration conflictWindow;

  MergeOutput merge(MergeInput input) {
    final notes = <String, SyncNote>{
      for (final note in input.localNotes) note.uuid: note,
    };
    final tombstones = <String, NoteTombstone>{
      for (final item in input.localTombstones.values) item.uuid: item,
    };
    final remoteTombstoneUuids = <String>{};

    for (final remote in input.remoteTombstones.values) {
      remoteTombstoneUuids.add(remote.uuid);
      final existing = tombstones[remote.uuid];
      if (existing == null || remote.deletedAt > existing.deletedAt) {
        tombstones[remote.uuid] = remote;
      }
    }

    // 墓碑优先于内容；只有远端有更晚的显式编辑才允许复活。
    var remoteDeletions = 0;
    for (final tombstone in List<NoteTombstone>.from(tombstones.values)) {
      final note = notes[tombstone.uuid];
      if (note == null) continue;
      if (note.updatedAt > tombstone.deletedAt) {
        tombstones.remove(tombstone.uuid);
        continue;
      }
      notes.remove(tombstone.uuid);
      if (remoteTombstoneUuids.contains(tombstone.uuid)) remoteDeletions++;
    }

    var importedV1 = 0;
    final naturalKeys = <String>{
      for (final note in notes.values) note.naturalKey,
    };
    final remoteV2ByUuid = {
      for (final remote in input.remoteV2Notes) remote.uuid: remote,
    };
    // 旧桌面写入的 v2 没有录音附件，v1 投影仍带 `audio`；记下来，等所有
    // 版本裁决结束后再补回，避免 v2 同 uuid 记录在后续循环里把它覆盖掉。
    final v1AudioByUuid = <String, List<SyncAttachment>>{
      for (final remote in input.remoteV1Notes)
        if (remote.attachments.any((item) => item.isAudio))
          remote.uuid: [
            for (final item in remote.attachments)
              if (item.isAudio) item,
          ],
    };
    for (final remote in input.remoteV1Notes) {
      if (tombstones.containsKey(remote.uuid)) continue;
      if (notes.containsKey(remote.uuid)) continue;
      if (!naturalKeys.add(remote.naturalKey)) continue;
      // v1 投影没有 updated_at 与附件信息；同 uuid 的 v2 记录更完整，优先采用，
      // 避免第二台电脑首次同步时把桌面端图片当成“旧记录”丢掉。
      final richer = remoteV2ByUuid[remote.uuid];
      notes[remote.uuid] =
          richer != null && richer.updatedAt >= remote.updatedAt
          ? richer
          : remote;
      importedV1++;
    }

    var appliedRemote = 0;
    var keptLocal = 0;
    var conflictCopies = 0;
    for (final remote in input.remoteV2Notes) {
      final local = notes[remote.uuid];
      if (local == null) {
        final tombstone = tombstones[remote.uuid];
        if (tombstone != null) {
          // 远端有更晚的显式编辑才允许复活，避免手机/旧设备把删除的笔记带回来。
          if (remote.updatedAt > tombstone.deletedAt) {
            tombstones.remove(remote.uuid);
            notes[remote.uuid] = remote;
            appliedRemote++;
          }
          continue;
        }
        notes[remote.uuid] = remote;
        appliedRemote++;
        continue;
      }

      final decision = _resolve(
        local: local,
        remote: remote,
        baseHash: input.bases[local.uuid],
      );
      if (decision.remoteWins) {
        if (decision.conflict) {
          final copy = _conflictCopy(
            decision.loser!,
            originalUuid: local.uuid,
            nowMs: input.nowMs,
          );
          notes[copy.uuid] = copy;
          conflictCopies++;
        }
        notes[remote.uuid] = remote;
        appliedRemote++;
      } else if (decision.changed) {
        keptLocal++;
      }
      if (tombstones.containsKey(remote.uuid)) {
        // 双方都存在时不应保留墓碑；防御异常输入。
        tombstones.remove(remote.uuid);
      }
    }

    // v1 里的录音补回到最终版本；v2 已有同名录音时不重复添加。
    for (final entry in v1AudioByUuid.entries) {
      final note = notes[entry.key];
      if (note == null) continue;
      notes[entry.key] = _withAudio(note, entry.value);
    }

    // 有笔记存在的 uuid 不再保留墓碑（复活或新插入）。
    for (final uuid in notes.keys) {
      tombstones.remove(uuid);
    }

    // 手机截图是旁路附件：不参与 LWW，也不推进 updated_at；索引可用时
    // 按笔记 uuid 挂接/摘除 origin='mobile' 的图片附件。
    if (input.imageIndexPresent) {
      _applyMobileImages(notes, input.remoteImages);
    }

    final warnings = <String>[];
    if (input.v1Skipped > 0) {
      warnings.add('跳过 ${input.v1Skipped} 条无法解析的 diary.json 记录');
    }
    if (conflictCopies > 0) {
      warnings.add('已生成 $conflictCopies 条冲突副本');
    }

    return MergeOutput(
      notes: List<SyncNote>.from(notes.values),
      tombstones: tombstones,
      preservedV1Rows: input.remoteV1PreservedRows,
      stats: SyncStats(
        importedFromV1: importedV1,
        appliedRemote: appliedRemote,
        keptLocal: keptLocal,
        conflictCopies: conflictCopies,
        remoteDeletions: remoteDeletions,
      ),
      warnings: warnings,
    );
  }

  /// 把只存在于 v1 投影里的录音附件补回最终版本。
  SyncNote _withAudio(SyncNote note, List<SyncAttachment> candidates) {
    final knownNames = {
      for (final item in note.attachments)
        if (item.isAudio && item.syncName != null) item.syncName,
    };
    final missing = [
      for (final item in candidates)
        if (item.syncName == null || !knownNames.contains(item.syncName)) item,
    ];
    if (missing.isEmpty) return note;
    return note.copyWith(attachments: [...note.attachments, ...missing]);
  }

  /// 把手机端 `image_index.json` 的截图挂到笔记附件（origin='mobile'）。
  ///
  /// - 同一设备同一笔记只认最新条目；不同设备同一 sha 只保留一个附件
  ///   （附件 uuid 由笔记 uuid + sha 推导，跨电脑稳定）
  /// - 已下载过的附件保留 storage_path / byte_size，只按索引校正文件名
  /// - 手机删图/换图时摘掉不再对得上的 origin='mobile' 附件
  /// - 不改笔记 updated_at：附件变化进了载荷哈希，但时间戳保持原值，
  ///   避免电脑端把“补图”当成一次编辑与手机 v1 投影发生 LWW 拉扯
  void _applyMobileImages(
    Map<String, SyncNote> notes,
    List<SyncImageEntry> entries,
  ) {
    final byNote = <String, List<SyncImageEntry>>{};
    for (final entry in entries) {
      if (!entry.isValid) continue;
      (byNote[entry.noteUuid] ??= []).add(entry);
    }

    for (final note in List<SyncNote>.from(notes.values)) {
      final images = byNote[note.uuid] ?? const <SyncImageEntry>[];
      final latestByDevice = <String, SyncImageEntry>{};
      for (final image in images) {
        final current = latestByDevice[image.deviceId];
        if (current == null ||
            (image.updatedAt ?? 0) >= (current.updatedAt ?? 0)) {
          latestByDevice[image.deviceId] = image;
        }
      }
      final desired = <String, SyncImageEntry>{};
      for (final image in latestByDevice.values) {
        desired.putIfAbsent(image.sha256, () => image);
      }

      final next = <SyncAttachment>[];
      final kept = <String>{};
      var changed = false;
      for (final attachment in note.attachments) {
        if (!attachment.isImage || attachment.origin != 'mobile') {
          next.add(attachment);
          continue;
        }
        final target = desired[attachment.sha256];
        if (target == null) {
          changed = true;
          continue;
        }
        final uuid = SyncCodec.mobileImageAttachmentUuid(
          note.uuid,
          target.sha256,
        );
        if (!kept.add(uuid)) {
          changed = true; // 重复附件（历史脏数据）去重
          continue;
        }
        if (attachment.syncName == target.name) {
          next.add(attachment);
          continue;
        }
        // 索引文件名与本地记录不一致时校正，保留已下载路径与大小。
        next.add(
          SyncAttachment(
            uuid: uuid,
            kind: 'image',
            origin: 'mobile',
            sha256: target.sha256,
            storagePath: attachment.storagePath,
            syncName: target.name,
            mimeType: attachment.mimeType ?? target.mimeType,
            byteSize: attachment.byteSize,
            sortOrder: attachment.sortOrder,
            rev: attachment.rev,
            extras: attachment.extras,
          ),
        );
        changed = true;
      }

      for (final image in desired.values) {
        final uuid = SyncCodec.mobileImageAttachmentUuid(
          note.uuid,
          image.sha256,
        );
        if (!kept.add(uuid)) continue;
        next.add(
          SyncAttachment(
            uuid: uuid,
            kind: 'image',
            origin: 'mobile',
            sha256: image.sha256,
            syncName: image.name,
            mimeType: image.mimeType,
            byteSize: image.byteSize,
          ),
        );
        changed = true;
      }

      if (changed) {
        notes[note.uuid] = note.copyWith(attachments: next);
      }
    }
  }

  _Decision _resolve({
    required SyncNote local,
    required SyncNote remote,
    required String? baseHash,
  }) {
    if (local.payloadHash == remote.payloadHash) {
      return const _Decision(remoteWins: false, changed: false);
    }

    if (baseHash != null) {
      final localChanged = local.payloadHash != baseHash;
      final remoteChanged = remote.payloadHash != baseHash;
      if (localChanged && !remoteChanged) {
        return const _Decision(remoteWins: false, changed: true);
      }
      if (!localChanged && remoteChanged) {
        return const _Decision(remoteWins: true, changed: true);
      }
      if (!localChanged && !remoteChanged) {
        // 基线相同但载荷不同，说明基线本身不可靠：按时间裁决。
        return _lww(local: local, remote: remote, mayConflict: false);
      }
      // 双方都改过。
      return _lww(local: local, remote: remote, mayConflict: true);
    }

    // 没有基线（首次同步或状态丢失）：只做 LWW，时间相同才视为冲突。
    return _lww(local: local, remote: remote, mayConflict: false);
  }

  _Decision _lww({
    required SyncNote local,
    required SyncNote remote,
    required bool mayConflict,
  }) {
    var remoteWins = remote.updatedAt > local.updatedAt;
    var tie = false;
    if (remote.updatedAt == local.updatedAt) {
      // 平局用载荷哈希做确定性裁决，所有设备算出的赢家一致。
      remoteWins = remote.payloadHash.compareTo(local.payloadHash) < 0;
      tie = true;
    }
    if (!remoteWins) {
      return const _Decision(remoteWins: false, changed: true);
    }
    final close =
        tie ||
        (remote.updatedAt - local.updatedAt).abs() <=
            conflictWindow.inMilliseconds;
    return _Decision(
      remoteWins: true,
      changed: true,
      conflict: mayConflict && close,
      loser: local,
    );
  }

  /// 冲突副本只由“本地版本输掉”的设备生成一次，避免两台设备各建一条。
  SyncNote _conflictCopy(
    SyncNote loser, {
    required String originalUuid,
    required int nowMs,
  }) {
    return SyncNote(
      uuid: _uuid.v4(),
      content: loser.content,
      createdAt: loser.createdAt,
      updatedAt: nowMs,
      mark: loser.mark,
      archived: false,
      locked: loser.locked,
      rev: 1,
      extras: {
        for (final entry in loser.extras.entries)
          if (entry.key != 'conflict_of') entry.key: entry.value,
        'conflict_of': originalUuid,
      },
      attachments: [
        for (final attachment in loser.attachments)
          SyncAttachment(
            uuid: _uuid.v4(),
            kind: attachment.kind,
            origin: attachment.origin,
            sha256: attachment.sha256,
            syncName: attachment.syncName,
            mimeType: attachment.mimeType,
            byteSize: attachment.byteSize,
            durationMs: attachment.durationMs,
            sortOrder: attachment.sortOrder,
            rev: 1,
            extras: attachment.extras,
          ),
      ],
    );
  }
}

class _Decision {
  const _Decision({
    required this.remoteWins,
    required this.changed,
    this.conflict = false,
    this.loser,
  });

  final bool remoteWins;
  final bool changed;
  final bool conflict;
  final SyncNote? loser;
}
