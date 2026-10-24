import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/sync/sync_codec.dart';
import 'package:shengwuji_desktop/sync/sync_merge.dart';
import 'package:shengwuji_desktop/sync/sync_models.dart';

void main() {
  SyncNote note(
    String uuid,
    String content,
    int updatedAt, {
    int? createdAt,
  }) {
    return SyncNote(
      uuid: uuid,
      content: content,
      createdAt: createdAt ?? 1000,
      updatedAt: updatedAt,
    );
  }

  MergeOutput merge({
    List<SyncNote> local = const [],
    Map<String, NoteTombstone> tombstones = const {},
    List<SyncNote> v1 = const [],
    List<SyncNote> v2 = const [],
    Map<String, NoteTombstone> remoteTombstones = const {},
    Map<String, String> bases = const {},
    int nowMs = 100000,
    List<SyncImageEntry> images = const [],
    bool imageIndexPresent = false,
    String localDeviceId = '',
  }) {
    return SyncMerger().merge(
      MergeInput(
        localNotes: local,
        localTombstones: tombstones,
        remoteV1Notes: v1,
        remoteV1PreservedRows: const [],
        remoteV2Notes: v2,
        remoteTombstones: remoteTombstones,
        bases: bases,
        nowMs: nowMs,
        remoteImages: images,
        imageIndexPresent: imageIndexPresent,
        localDeviceId: localDeviceId,
      ),
    );
  }

  test('吸收手机端新增笔记，uuid 与自然键都去重', () {
    final local = note('local', '本地', 2000);
    final sameNaturalKey = SyncNote(
      uuid: 'phone-copy',
      content: '本地',
      createdAt: 1000,
      updatedAt: 1000,
    );
    final fresh = SyncNote(
      uuid: 'phone-new',
      content: '手机新写的',
      createdAt: 3000,
      updatedAt: 3000,
    );

    final result = merge(local: [local], v1: [sameNaturalKey, fresh]);

    expect(result.notes.map((item) => item.uuid), containsAll(['local']));
    expect(result.notes.map((item) => item.uuid), contains('phone-new'));
    expect(result.notes.map((item) => item.uuid), isNot(contains('phone-copy')));
    expect(result.stats.importedFromV1, 1);
  });

  test('v2 记录更完整时，仍保留 v1 里的录音', () {
    final image = SyncAttachment(
      uuid: 'img',
      kind: 'image',
      sha256: 'a' * 64,
      syncName: 'cat.png',
    );
    final audio = SyncAttachment(
      uuid: 'aud',
      kind: 'audio',
      syncName: 'voice.wav',
      durationMs: 8000,
    );
    final richer = SyncNote(
      uuid: 'n1',
      content: '带图笔记',
      createdAt: 1000,
      updatedAt: 3000,
      attachments: [image],
    );
    final projected = SyncNote(
      uuid: 'n1',
      content: '带图笔记',
      createdAt: 1000,
      updatedAt: 1000,
      attachments: [audio],
    );

    final result = merge(v1: [projected], v2: [richer]);

    final note = result.notes.single;
    expect(note.content, '带图笔记');
    expect(note.attachments.map((item) => item.kind), containsAll([
      'image',
      'audio',
    ]));
    expect(note.attachments.singleWhere((item) => item.isAudio).syncName,
        'voice.wav');
  });

  test('墓碑阻止 v1 笔记回魂，但更晚的 v2 编辑可以复活', () {
    final tombstone = NoteTombstone(uuid: 'n1', deletedAt: 5000);

    final blocked = merge(
      tombstones: {'n1': tombstone},
      v1: [note('n1', '手机又发了一次', 4000)],
    );
    expect(blocked.notes, isEmpty);
    expect(blocked.tombstones, contains('n1'));

    final revived = merge(
      tombstones: {'n1': tombstone},
      v2: [note('n1', '桌面端明确恢复', 6000)],
    );
    expect(revived.notes.single.content, '桌面端明确恢复');
    expect(revived.tombstones, isEmpty);
    expect(revived.stats.appliedRemote, 1);
  });

  test('只有一侧改动时不做无谓冲突副本', () {
    final base = note('n1', '基线', 1000);
    final localChanged = note('n1', '本地改过', 2000);
    final remoteUnchanged = note('n1', '基线', 1000);

    final kept = merge(
      local: [localChanged],
      v2: [remoteUnchanged],
      bases: {'n1': base.payloadHash},
    );
    expect(kept.notes.single.content, '本地改过');
    expect(kept.stats.conflictCopies, 0);
    expect(kept.stats.keptLocal, 1);

    final remoteChanged = note('n1', '远端改过', 3000);
    final applied = merge(
      local: [base],
      v2: [remoteChanged],
      bases: {'n1': base.payloadHash},
    );
    expect(applied.notes.single.content, '远端改过');
    expect(applied.stats.conflictCopies, 0);
    expect(applied.stats.appliedRemote, 1);
  });

  test('双方都改且时间接近时保留本地内容为冲突副本', () {
    final base = note('n1', '基线', 1000);
    final local = note('n1', '本地版本', 2000);
    final remote = note('n1', '远端版本', 2100);

    final result = merge(
      local: [local],
      v2: [remote],
      bases: {'n1': base.payloadHash},
    );

    expect(result.stats.conflictCopies, 1);
    expect(result.notes, hasLength(2));
    final winner = result.notes.firstWhere((item) => item.uuid == 'n1');
    expect(winner.content, '远端版本');
    final copy = result.notes.firstWhere((item) => item.uuid != 'n1');
    expect(copy.content, '本地版本');
    expect(copy.extras['conflict_of'], 'n1');
  });

  test('双方都改但时间相差较远时按内容时间裁决，不生成副本', () {
    final base = note('n1', '基线', 1000);
    final local = note('n1', '本地版本', 2000);
    final remote = note('n1', '远端版本', 2000 + 6 * 60 * 1000);

    final result = merge(
      local: [local],
      v2: [remote],
      bases: {'n1': base.payloadHash},
    );

    expect(result.notes.single.content, '远端版本');
    expect(result.stats.conflictCopies, 0);
  });

  test('远端删除优先于更旧的本地编辑', () {
    final result = merge(
      local: [note('n1', '本地还在', 3000)],
      remoteTombstones: {
        'n1': const NoteTombstone(uuid: 'n1', deletedAt: 4000),
      },
    );

    expect(result.notes, isEmpty);
    expect(result.tombstones, contains('n1'));
    expect(result.stats.remoteDeletions, 1);
  });

  test('没有基线时远端更新的内容获胜', () {
    final local = note('n1', '旧', 2000);
    final remote = note('n1', '新', 3000);

    final result = merge(local: [local], v2: [remote]);
    expect(result.notes.single.content, '新');
    expect(result.stats.conflictCopies, 0);
  });

  test('时间相同用载荷哈希确定性裁决', () {
    final local = note('n1', 'A 版本', 2000);
    final remote = note('n1', 'B 版本', 2000);

    final first = merge(local: [local], v2: [remote]);
    final second = merge(local: [remote], v2: [local]);

    expect(first.notes.single.content, second.notes.single.content);
  });

  SyncImageEntry image(
    String sha, {
    String noteUuid = 'n1',
    String deviceId = 'phone-a',
    int updatedAt = 2000,
    int position = 0,
    String source = 'mobile',
  }) {
    return SyncImageEntry(
      noteUuid: noteUuid,
      deviceId: deviceId,
      sha256: sha,
      name: '$sha.png',
      mimeType: 'image/png',
      byteSize: 64,
      updatedAt: updatedAt,
      position: position,
      source: source,
    );
  }

  test('手机截图索引挂成附件，但不推进笔记 updated_at', () {
    final local = note('n1', '带截图的笔记', 2000);
    final sha = 'a' * 64;

    final result = merge(
      local: [local],
      images: [image(sha)],
      imageIndexPresent: true,
    );

    final restored = result.notes.single;
    expect(restored.updatedAt, local.updatedAt);
    expect(restored.attachments, hasLength(1));
    final attachment = restored.attachments.single;
    expect(attachment.kind, 'image');
    expect(attachment.origin, 'mobile');
    expect(attachment.sha256, sha);
    expect(attachment.syncName, '$sha.png');
    expect(attachment.storagePath, isNull);
    expect(
      attachment.uuid,
      SyncCodec.mobileImageAttachmentUuid('n1', sha),
    );
  });

  test('手机换图摘掉旧附件，同一张图保留已下载路径', () {
    final oldSha = 'a' * 64;
    final newSha = 'b' * 64;
    final local = SyncNote(
      uuid: 'n1',
      content: '换过图',
      createdAt: 1000,
      updatedAt: 2000,
      attachments: [
        SyncAttachment(
          uuid: SyncCodec.mobileImageAttachmentUuid('n1', oldSha),
          kind: 'image',
          origin: 'mobile',
          sha256: oldSha,
          storagePath: 'blobs/aa/$oldSha.png',
          syncName: '$oldSha.png',
          mimeType: 'image/png',
          byteSize: 64,
        ),
      ],
    );

    final replaced = merge(
      local: [local],
      images: [image(newSha)],
      imageIndexPresent: true,
    ).notes.single;
    expect(replaced.attachments.single.sha256, newSha);
    expect(replaced.attachments.single.storagePath, isNull);

    final kept = merge(
      local: [local],
      images: [image(oldSha)],
      imageIndexPresent: true,
    ).notes.single;
    expect(kept.attachments.single.storagePath, 'blobs/aa/$oldSha.png');

    final removed = merge(
      local: [local],
      imageIndexPresent: true,
    ).notes.single;
    expect(removed.attachments, isEmpty);
  });

  test('截图索引不可用时不动电脑端已有的手机附件', () {
    final sha = 'a' * 64;
    final local = SyncNote(
      uuid: 'n1',
      content: '图',
      createdAt: 1000,
      updatedAt: 2000,
      attachments: [
        SyncAttachment(
          uuid: SyncCodec.mobileImageAttachmentUuid('n1', sha),
          kind: 'image',
          origin: 'mobile',
          sha256: sha,
          syncName: '$sha.png',
        ),
      ],
    );

    final result = merge(local: [local]);

    expect(result.notes.single.attachments, hasLength(1));
  });

  test('多台手机各一张图都挂上，同 sha 去重', () {
    final local = note('n1', '两台手机', 2000);
    final sha = 'a' * 64;

    final result = merge(
      local: [local],
      images: [
        image(sha, deviceId: 'phone-a'),
        image(sha, deviceId: 'phone-b'),
        image('b' * 64, deviceId: 'phone-c'),
      ],
      imageIndexPresent: true,
    );

    expect(result.notes.single.attachments, hasLength(2));
  });

  test('同一设备多张图全部挂上，position 映射为 sortOrder', () {
    final local = note('n1', '电脑端多图', 2000);

    final result = merge(
      local: [local],
      images: [
        image('a' * 64, deviceId: 'pc', position: 1),
        image('b' * 64, deviceId: 'pc', position: 0),
      ],
      imageIndexPresent: true,
    );

    final attachments = result.notes.single.attachments
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    expect(attachments, hasLength(2));
    expect(attachments.first.sha256, 'b' * 64);
    expect(attachments.last.sha256, 'a' * 64);
  });

  test('跳过本机与电脑端来源的索引条目，避免重复附件', () {
    final local = note('n1', '电脑端自己的图', 2000);

    final result = merge(
      local: [local],
      images: [
        // 本机发布（localDeviceId 命中）
        image('a' * 64, deviceId: 'pc-a', source: 'desktop'),
        // 另一台电脑发布：图片随 v2 笔记附件到达，不再按手机索引挂接
        image('b' * 64, deviceId: 'pc-b', source: 'desktop'),
        // 手机截图照常挂接
        image('c' * 64, deviceId: 'phone-a'),
      ],
      imageIndexPresent: true,
      localDeviceId: 'pc-a',
    );

    final attachment = result.notes.single.attachments.single;
    expect(attachment.sha256, 'c' * 64);
    expect(attachment.origin, 'mobile');
  });
}
