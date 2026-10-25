import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/image_payload.dart';
import '../data/note_backend.dart';
import '../data/note_store.dart';
import 'password_store.dart';
import 'sync_codec.dart';
import 'sync_config.dart';
import 'sync_exception.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'webdav_client.dart';
import 'webdav_request_counter.dart';

/// 同步状态，界面据此显示按钮与提示。
enum SyncStatus { disabled, idle, syncing, success, error }

typedef CloudStorageFactory =
    CloudStorage Function(SyncConfig config, String password);

/// WebDAV 双向同步：拉取 v1/v2、三方合并、写回本地并投影给手机端。
///
/// 同一时间只跑一次；本地改动只做延时排队，不打断正在进行的同步。
class SyncService extends ChangeNotifier {
  SyncService({
    required this.store,
    required this.passwordStore,
    required this.onSynced,
    SyncConfig config = const SyncConfig(),
    this.deviceId = '',
    CloudStorageFactory? clientFactory,
    DateTime Function()? clock,
    this.debounceDelay = const Duration(seconds: 25),
    this.requestCounter,
  }) : _config = config,
       _clock = clock ?? DateTime.now {
    _clientFactory = clientFactory ?? _createClient;
  }

  static const Duration lockRetryDelay = Duration(milliseconds: 400);

  /// 轮询只探测这两个文件：手机与桌面端同步都会更新它们。
  static const List<String> _probePaths = ['manifest.json', 'v2/manifest.json'];

  static final RegExp _shaPattern = RegExp(r'^[0-9a-f]{64}$');

  /// 单条录音的大小上限；手机语音一般几百 KB，超过这个值多半不是录音。
  static const int kMaxAudioBytes = 100 * 1024 * 1024;

  final NoteStore store;
  final PasswordStore passwordStore;

  /// 合并结果写回数据库后调用，用于刷新界面。
  final Future<void> Function() onSynced;
  final String deviceId;
  final Duration debounceDelay;

  /// 本机 WebDAV 请求预算；设置页据此显示最近 30 分钟的消耗。
  final WebDavRequestCounter? requestCounter;

  late final CloudStorageFactory _clientFactory;
  final DateTime Function() _clock;

  SyncConfig _config;
  SyncStatus _status = SyncStatus.idle;
  DateTime? _lastSyncAt;
  String? _lastError;
  SyncResult? _lastResult;
  Future<SyncResult?>? _running;
  Timer? _debounce;
  Timer? _pollTimer;
  bool _pendingSync = false;
  bool _pushPending = false;
  int _localRevision = 0;
  bool _disposed = false;
  int _epoch = 0;
  int _backupSerial = 0;

  CloudStorage _createClient(SyncConfig config, String password) {
    return WebDavClient(
      baseUrl: config.baseUrl,
      username: config.username,
      password: password,
      remoteDir: config.remoteDir,
      requestCounter: requestCounter,
    );
  }

  SyncConfig get config => _config;

  bool get isConfigured => _config.isConfigured;

  bool get isEnabled => _config.enabled && _config.isConfigured;

  bool get isBusy => _running != null;

  SyncStatus get status => isEnabled ? _status : SyncStatus.disabled;

  DateTime? get lastSyncAt => _lastSyncAt;

  String? get lastError => _lastError;

  SyncResult? get lastResult => _lastResult;

  String get device => deviceId.isEmpty ? 'desktop' : deviceId;

  /// 读取上次同步时间；失败不影响启动。
  Future<void> initialize() async {
    _restartPollTimer();
    try {
      final state = await _readState();
      _lastSyncAt = state.lastSyncAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(state.lastSyncAt!);
      _notify();
    } catch (error) {
      debugPrint('读取同步状态失败：$error');
    }
  }

  /// 设置页保存后调用；连接配置变化会让进行中的同步放弃后续写入。
  ///
  /// 只改自动同步间隔时不动 [epoch]，避免打断正在进行的同步。
  void configure(SyncConfig next) {
    final connectionChanged = !_sameConfig(_config, next);
    final intervalChanged = _config.autoSyncMinutes != next.autoSyncMinutes;
    if (!connectionChanged && !intervalChanged) return;
    _config = next;
    if (connectionChanged) {
      _epoch++;
      _debounce?.cancel();
      if (!isEnabled) {
        _status = SyncStatus.disabled;
        _lastError = null;
      } else if (_status == SyncStatus.disabled) {
        _status = SyncStatus.idle;
      }
    }
    _restartPollTimer();
    _notify();
  }

  void _restartPollTimer() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_disposed || !isEnabled) return;
    final interval = _config.autoSyncInterval;
    if (interval == null) return;
    _pollTimer = Timer.periodic(interval, (_) => unawaited(poll()));
  }

  /// 本地笔记发生变化：合并短时间内的多次改动，再自动推送。
  void noteLocalChange() {
    if (_disposed || !isEnabled) return;
    _localRevision++;
    _pushPending = true;
    _debounce?.cancel();
    _debounce = Timer(debounceDelay, () {
      unawaited(sync());
    });
  }

  /// 启动时静默同步一次；未配置或关闭时直接返回。
  Future<SyncResult?> syncOnStartup() => sync();

  /// 定时轮询入口：远端版本没变时只发元信息请求，不读正文也不写文件。
  ///
  /// 返回 null 表示本轮没有执行完整同步（未变化、正在同步或被顺延）。
  Future<SyncResult?> poll() async {
    if (_disposed || !isEnabled || _running != null) return null;
    // 本地改动已有防抖同步排队，轮询不必插队。
    if (_debounce?.isActive ?? false) return null;
    // 上次自动推送失败时，下一轮继续重试，而不是只检查云端。
    if (_pushPending) return sync();

    final epoch = _epoch;
    var changed = false;
    CloudStorage? client;
    try {
      final password = await passwordStore.read() ?? '';
      client = _clientFactory(_config, password);
      final state = await _readState();
      changed = await _remoteChanged(client, state);
    } on SyncException catch (error) {
      _lastError = error.message;
      _status = SyncStatus.error;
      _notify();
      return null;
    } catch (error) {
      _lastError = '自动同步失败：$error';
      _status = SyncStatus.error;
      _notify();
      return null;
    } finally {
      await client?.close();
    }

    if (_disposed || epoch != _epoch) return null;
    if (!changed) {
      // 探测成功说明网络与账号恢复；没有数据变化也清掉上次的失败提示。
      if (_status == SyncStatus.error) {
        _status = _lastSyncAt == null ? SyncStatus.idle : SyncStatus.success;
        _lastError = null;
        _notify();
      }
      return null;
    }
    return sync();
  }

  Future<bool> _remoteChanged(CloudStorage client, SyncState state) async {
    for (final path in _probePaths) {
      RemoteStat? stat;
      try {
        stat = await client.stat(path);
      } on UnsupportedError {
        // 不支持 PROPFIND 的服务器退回完整同步，行为与以前一致。
        return true;
      }
      if (stat == null) return true;
      final revision = stat.revision;
      if (revision == null) return true;
      if (state.remoteEtags[path] != revision) return true;
    }
    return false;
  }

  /// 执行一次同步。失败原因写入 [lastError]，同时返回 null。
  Future<SyncResult?> sync({bool manual = false}) {
    if (_disposed) return Future.value(null);
    final existing = _running;
    if (existing != null) {
      // 同步期间产生的本地改动不能丢，结束后补跑一次。
      _pendingSync = true;
      return existing;
    }
    if (!isEnabled) {
      _status = SyncStatus.disabled;
      if (manual) {
        _lastError = isConfigured ? '同步已关闭' : '还没有配置 WebDAV';
        _notify();
      }
      return Future.value(null);
    }

    final future = _execute();
    _running = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_running, future)) _running = null;
        if (_pendingSync) {
          _pendingSync = false;
          if (!_disposed) unawaited(sync());
        }
      }),
    );
    return future;
  }

  /// 验证地址与账号；成功返回 null，失败返回可读原因。
  Future<String?> testConnection(SyncConfig config, String password) async {
    if (!config.isConfigured) return '请先填写地址与账号';
    CloudStorage? client;
    try {
      client = _clientFactory(config, password);
      await client.ensureDirectory();
      await client.ping();
      return null;
    } on SyncException catch (error) {
      return error.message;
    } catch (error) {
      return '连接失败：$error';
    } finally {
      await client?.close();
    }
  }

  Future<SyncResult?> _execute() async {
    _status = SyncStatus.syncing;
    _lastError = null;
    _notify();

    final epoch = _epoch;
    final localRevision = _localRevision;
    CloudStorage? client;
    try {
      if (!await store.supportsSync()) {
        throw const SyncException('当前数据目录处于兼容模式，暂不支持同步');
      }
      final password = await passwordStore.read() ?? '';
      client = _clientFactory(_config, password);
      await client.ensureDirectory();

      SyncResult? result;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          result = await _syncOnce(client, epoch);
          break;
        } on LocalChangedDuringSync {
          if (attempt == 1) {
            throw const SyncException('同步期间本地一直在修改，请稍后再试');
          }
          _ensureCurrent(epoch);
        }
      }
      if (result == null) {
        throw const SyncException('同步未完成，请重试');
      }

      _lastSyncAt = result.at;
      _lastResult = result;
      _status = SyncStatus.success;
      _lastError = null;
      // 同步期间又有改动时保持待推送，结束后会补跑一轮。
      if (_localRevision == localRevision) _pushPending = false;
      _notify();
      if (!_disposed) await onSynced();
      return result;
    } on SyncException catch (error) {
      _lastError = error.message;
      _status = SyncStatus.error;
      _notify();
      return null;
    } catch (error) {
      _lastError = '同步失败：$error';
      _status = SyncStatus.error;
      _notify();
      return null;
    } finally {
      await client?.close();
    }
  }

  Future<SyncResult> _syncOnce(CloudStorage client, int epoch) async {
    _ensureCurrent(epoch);
    final startedAt = _clock();
    final nowMs = startedAt.millisecondsSinceEpoch;
    final state = await _readState();
    final raw = <String, String>{};

    final manifestFile = await client.read('manifest.json');
    if (manifestFile != null && manifestFile.text.trim().isNotEmpty) {
      raw['manifest.json'] = manifestFile.text;
    }
    final v1Manifest = _parseV1Manifest(manifestFile?.text);

    final lock = v1Manifest?.lock;
    if (lock != null && lock.deviceId != device && !lock.isStale(startedAt)) {
      throw const SyncException('另一台设备正在同步，请稍后再试');
    }

    var lockAcquired = false;
    var released = false;
    var releaseCounts = v1Manifest?.counts ?? <String, int>{};
    final warnings = <String>[];

    final lockManifest = SyncCodec.acquireLockV1(v1Manifest?.raw, device);
    try {
      await client.write(
        'manifest.json',
        utf8.encode(jsonEncode(lockManifest)),
      );
      lockAcquired = true;
      _ensureCurrent(epoch);

      final diaryFile = await client.read('diary.json');
      final v2ManifestFile = await client.read('v2/manifest.json');
      final v2NotesFile = await client.read('v2/notes.json');
      final v2TombFile = await client.read('v2/tombstones.json');
      final imageIndexFile = await client.read('image_index.json');
      _collectRaw(raw, 'diary.json', diaryFile?.text);
      _collectRaw(raw, 'v2/manifest.json', v2ManifestFile?.text);
      _collectRaw(raw, 'v2/notes.json', v2NotesFile?.text);
      _collectRaw(raw, 'v2/tombstones.json', v2TombFile?.text);
      _collectRaw(raw, 'image_index.json', imageIndexFile?.text);
      await _backupRemote(raw);

      final diary = _parseDiary(diaryFile?.text);
      final v2Manifest = _parseV2Manifest(v2ManifestFile?.text);
      if (v2Manifest != null) {
        try {
          SyncCodec.ensureSupported(v2Manifest);
        } on FormatException catch (error) {
          throw SyncException(error.message);
        }
      }
      final remoteV2Notes = _parseV2Notes(v2NotesFile?.text);
      final tombstoneParse = _parseTombstones(v2TombFile?.text);
      final imageIndex = _parseImageIndex(imageIndexFile?.text);
      if (imageIndex.malformed) {
        warnings.add('手机截图索引格式异常，本轮跳过截图附件');
      }
      if (imageIndex.skipped > 0) {
        warnings.add('跳过 ${imageIndex.skipped} 条无法解析的手机截图索引');
      }

      final snapshot = await _readLocalSnapshot();
      _ensureCurrent(epoch);

      // 本地旧数据可能把 audio/duration 放在 extras 里；先统一成附件，
      // 三方合并与载荷哈希才和远端解析出来的形态一致。
      final localNotes = [
        for (final note in snapshot.notes) SyncCodec.normalizeAudio(note),
      ];
      final merge = SyncMerger().merge(
        MergeInput(
          localNotes: localNotes,
          localTombstones: snapshot.tombstones,
          remoteV1Notes: diary.notes,
          remoteV1PreservedRows: diary.preservedRows,
          remoteV2Notes: remoteV2Notes,
          remoteTombstones: tombstoneParse.tombstones,
          bases: state.bases,
          nowMs: nowMs,
          v1Skipped: diary.skipped,
          remoteImages: imageIndex.entries,
          imageIndexPresent: imageIndex.present,
          localDeviceId: device,
        ),
      );
      warnings.addAll(merge.warnings);

      await store.applySync(
        expected: snapshot,
        finalState: SyncSnapshot(
          notes: merge.notes,
          tombstones: merge.tombstones,
        ),
      );
      await onSynced();
      _ensureCurrent(epoch);

      final assetOutcome = await _syncAssets(client, merge.notes, state);
      warnings.addAll(assetOutcome.warnings);
      var finalNotes = merge.notes;
      if (assetOutcome.blobs.isNotEmpty) {
        final current = await _readLocalSnapshot();
        final updatedNotes = [
          for (final note in current.notes)
            note.copyWith(
              attachments: [
                for (final attachment in note.attachments)
                  _withStorage(attachment, assetOutcome.blobs[attachment.uuid]),
              ],
            ),
        ];
        await store.applySync(
          expected: current,
          finalState: SyncSnapshot(
            notes: updatedNotes,
            tombstones: current.tombstones,
          ),
        );
        finalNotes = updatedNotes;
        await onSynced();
      }
      _ensureCurrent(epoch);

      // 反向发布：把电脑端笔记里的图片附件写进 image_index.json（本机
      // device_id 归属），手机端据此下载展示。索引损坏时跳过，绝不覆盖
      // 其它设备已写好的条目
      if (!imageIndex.malformed) {
        try {
          await _publishImageIndex(
            client,
            device: device,
            notes: finalNotes,
            remoteEntries: imageIndex.entries,
            previous: raw['image_index.json'],
          );
        } catch (error) {
          warnings.add('发布电脑端图片索引失败，手机端本轮看不到新图');
          debugPrint('发布 image_index.json 失败：$error');
        }
      }

      final sortedNotes = List<SyncNote>.from(finalNotes)
        ..sort((a, b) {
          final byTime = a.createdAt.compareTo(b.createdAt);
          return byTime != 0 ? byTime : a.uuid.compareTo(b.uuid);
        });
      final sortedTombstones = <String, NoteTombstone>{
        for (final item in (List<NoteTombstone>.from(
          merge.tombstones.values,
        )..sort((a, b) => a.uuid.compareTo(b.uuid))))
          item.uuid: item,
      };

      final v2NotesJson = SyncCodec.encodeNotesV2(
        notes: sortedNotes,
        deviceId: device,
        nowMs: nowMs,
      );
      await _writeIfChanged(
        client,
        'v2/notes.json',
        v2NotesJson,
        previous: raw['v2/notes.json'],
        ignoreKeys: const {'generated_at'},
      );

      final tombstonesJson = SyncCodec.encodeTombstonesV2(
        tombstones: sortedTombstones,
        preservedRows: tombstoneParse.preservedRows,
        nowMs: nowMs,
      );
      await _writeIfChanged(
        client,
        'v2/tombstones.json',
        tombstonesJson,
        previous: raw['v2/tombstones.json'],
        ignoreKeys: const {'generated_at'},
      );

      final manifestV2Json = SyncCodec.encodeManifestV2(
        previous: v2Manifest,
        deviceId: device,
        nowMs: nowMs,
        counts: {
          'notes': sortedNotes.length,
          'tombstones': sortedTombstones.length,
        },
      );
      await _writeIfChanged(
        client,
        'v2/manifest.json',
        manifestV2Json,
        previous: raw['v2/manifest.json'],
        ignoreKeys: const {'updated_at'},
        writerDevice: device,
      );

      final diaryRows = SyncCodec.encodeDiaryV1(
        sortedNotes,
        merge.preservedV1Rows,
      );
      releaseCounts = {...?v1Manifest?.counts, 'notes': sortedNotes.length};
      final diaryText = jsonEncode(diaryRows);
      if (raw['diary.json'] != diaryText) {
        await client.write('diary.json', utf8.encode(diaryText));
      }

      final releaseManifest = SyncCodec.releaseLockV1(
        v1Manifest?.raw,
        device,
        releaseCounts,
      );
      try {
        await client.write(
          'manifest.json',
          utf8.encode(jsonEncode(releaseManifest)),
        );
        released = true;
      } catch (error) {
        debugPrint('释放远端同步锁失败：$error');
        warnings.add('远端同步锁未能释放，10 分钟后会自动过期');
      }

      // 释放锁之后再记录版本，轮询才能直接与最新 ETag 比较。
      final nextState = SyncState(
        bases: {for (final note in sortedNotes) note.uuid: note.payloadHash},
        lastSyncAt: nowMs,
        remoteRevisions: assetOutcome.remoteRevisions,
        remoteEtags: await _refreshRemoteEtags(client, state.remoteEtags),
      );
      await store.writeSyncState(jsonEncode(nextState.toJson()));
      _ensureCurrent(epoch);

      return SyncResult(
        at: startedAt,
        stats: SyncStats(
          importedFromV1: merge.stats.importedFromV1,
          appliedRemote: merge.stats.appliedRemote,
          keptLocal: merge.stats.keptLocal,
          conflictCopies: merge.stats.conflictCopies,
          remoteDeletions: merge.stats.remoteDeletions,
          assetsUploaded: assetOutcome.uploaded,
          assetsDownloaded: assetOutcome.downloaded,
          audioDownloaded: assetOutcome.audioDownloaded,
        ),
        warnings: warnings,
      );
    } finally {
      if (lockAcquired && !released) {
        try {
          await client.write(
            'manifest.json',
            utf8.encode(
              jsonEncode(
                SyncCodec.releaseLockV1(v1Manifest?.raw, device, releaseCounts),
              ),
            ),
          );
        } catch (error) {
          debugPrint('失败后释放远端同步锁失败：$error');
        }
      }
    }
  }

  /// 把电脑端自己的图片附件发布到根目录 `image_index.json`。
  ///
  /// 所有权同手机端：其他设备的条目原样保留；本机条目在「笔记仍在本地」
  /// 时由本轮附件列表整体替换（删图/换图/重排都能同步），笔记已删除则
  /// 保留旧条目（P1 删除不跨端）。只发布非 `mobile` 来源的图片附件——
  /// 从手机下载来的附件不能以电脑端身份再发布，否则来源换图后旧图复活。
  Future<void> _publishImageIndex(
    CloudStorage client, {
    required String device,
    required List<SyncNote> notes,
    required List<SyncImageEntry> remoteEntries,
    required String? previous,
  }) async {
    final localUuids = {for (final note in notes) note.uuid};
    final merged = <String, SyncImageEntry>{};
    for (final entry in remoteEntries) {
      if (!entry.isValid) continue;
      if (entry.deviceId == device && localUuids.contains(entry.noteUuid)) {
        continue; // 本机条目由下面的本地附件重建
      }
      merged[entry.key] = entry;
    }

    for (final note in notes) {
      final images =
          note.attachments
              .where(
                (item) =>
                    item.isImage &&
                    item.origin != 'mobile' &&
                    item.storagePath != null &&
                    item.sha256 != null,
              )
              .toList()
            ..sort((a, b) {
              final byOrder = a.sortOrder.compareTo(b.sortOrder);
              return byOrder != 0 ? byOrder : a.uuid.compareTo(b.uuid);
            });
      var position = 0;
      for (final attachment in images) {
        final sha = attachment.sha256!;
        final name = attachment.assetFileName;
        if (name == null || name.isEmpty) continue;
        final entry = SyncImageEntry(
          noteUuid: note.uuid,
          deviceId: device,
          sha256: sha,
          name: name,
          mimeType: attachment.mimeType,
          byteSize: attachment.byteSize,
          updatedAt: note.updatedAt,
          position: position,
          source: 'desktop',
        );
        if (!entry.isValid) continue;
        merged[entry.key] = entry;
        position++;
      }
    }

    final text = SyncCodec.encodeImageIndex(merged.values.toList());
    Object? before;
    if (previous != null && previous.trim().isNotEmpty) {
      try {
        before = jsonDecode(previous);
      } on FormatException {
        before = null;
      }
    }
    if (before is List &&
        _canonicalJson(before) == _canonicalJson(jsonDecode(text))) {
      return;
    }
    await client.write('image_index.json', utf8.encode(text));
  }

  Future<_AssetOutcome> _syncAssets(
    CloudStorage client,
    List<SyncNote> notes,
    SyncState state,
  ) async {
    final warnings = <String>[];
    final revisions = Map<String, String>.from(state.remoteRevisions);
    final listings = <String, Set<String>?>{};
    final uploadByHash = <String, SyncAttachment>{};
    final downloadByHash = <String, List<SyncAttachment>>{};
    final audioDownloads = <String, List<SyncAttachment>>{};

    for (final note in notes) {
      for (final attachment in note.attachments) {
        if (attachment.isAudio) {
          final name = attachment.syncName;
          if (!_config.audioEnabled ||
              attachment.storagePath != null ||
              name == null ||
              name.isEmpty) {
            continue;
          }
          (audioDownloads[name] ??= []).add(attachment);
          continue;
        }
        if (!attachment.isImage) continue;
        final sha = attachment.sha256;
        if (sha == null || sha.isEmpty) continue;
        if (!_shaPattern.hasMatch(sha)) {
          warnings.add('图片索引信息异常，已跳过同步：${attachment.uuid}');
          continue;
        }
        if (attachment.storagePath == null) {
          (downloadByHash[sha] ??= []).add(attachment);
        } else {
          uploadByHash[sha] = attachment;
        }
      }
    }

    var uploaded = 0;
    for (final entry in uploadByHash.entries) {
      final attachment = entry.value;
      final storagePath = attachment.storagePath!;
      final fileName = attachment.assetFileName;
      if (fileName == null) continue;
      final remotePath = 'v2/assets/${entry.key.substring(0, 2)}/$fileName';
      final file = store.imageFile(storagePath);
      List<int> bytes;
      try {
        if (!await file.exists()) {
          warnings.add('本地图片缺失，已跳过上传：$storagePath');
          continue;
        }
        bytes = await file.readAsBytes();
      } on FileSystemException catch (error) {
        warnings.add('读取本地图片失败：${p.basename(storagePath)}');
        debugPrint('$error');
        continue;
      }
      if (bytes.length > kMaxImageBytes) {
        warnings.add('图片超过 20 MB，已跳过同步：${p.basename(storagePath)}');
        continue;
      }
      if (sha256.convert(bytes).toString() != entry.key) {
        warnings.add('本地图片内容与索引不一致，已跳过：${p.basename(storagePath)}');
        continue;
      }

      final listing = await _listingFor(client, listings, remotePath);
      final exists = listing != null
          ? listing.contains(p.basename(remotePath))
          : revisions.containsKey('asset:$remotePath');
      if (exists) continue;

      try {
        await _retry(
          () => client.write(
            remotePath,
            bytes,
            contentType: _mimeFor(remotePath),
          ),
        );
        uploaded++;
        revisions['asset:$remotePath'] = '1';
        if (listing != null) listing.add(p.basename(remotePath));
      } on SyncException catch (error) {
        warnings.add('上传图片失败：${error.message}');
      }
    }

    var downloaded = 0;
    final blobs = <String, _BlobInfo>{};
    for (final entry in downloadByHash.entries) {
      final first = entry.value.first;
      final fileName = first.assetFileName;
      if (fileName == null) continue;
      final remotePath = 'v2/assets/${entry.key.substring(0, 2)}/$fileName';
      RemoteFile? remote;
      try {
        remote = await _retry(() => client.read(remotePath));
      } on SyncException catch (error) {
        warnings.add('下载图片失败：${error.message}');
        continue;
      }
      if (remote == null || remote.bytes.isEmpty) {
        warnings.add('云端缺少图片：${p.basename(remotePath)}');
        continue;
      }
      try {
        final relative = await store.importBlob(entry.key, remote.bytes);
        downloaded++;
        final info = _BlobInfo(
          relative: relative,
          sha256: entry.key,
          byteSize: remote.bytes.length,
        );
        for (final attachment in entry.value) {
          blobs[attachment.uuid] = info;
        }
      } on ImageTooLargeException catch (error) {
        warnings.add(error.toString());
      } on UnsupportedImageException catch (error) {
        warnings.add(error.message);
      } on FormatException catch (error) {
        warnings.add(error.message);
      }
    }

    final audio = await _downloadAudio(client, audioDownloads, warnings);
    blobs.addAll(audio.blobs);

    return _AssetOutcome(
      blobs: blobs,
      uploaded: uploaded,
      downloaded: downloaded,
      audioDownloaded: audio.downloaded,
      warnings: warnings,
      remoteRevisions: revisions,
    );
  }

  /// 手机录音放在 `audio/<basename>`，`audio_index.json` 记录已上传完成的名字。
  ///
  /// 只有设置里开启音频同步才下载；索引里还没出现的文件不尝试，
  /// 避免录音刚录完、上传未完成时每轮同步都报 404。
  Future<_AudioOutcome> _downloadAudio(
    CloudStorage client,
    Map<String, List<SyncAttachment>> byName,
    List<String> warnings,
  ) async {
    if (byName.isEmpty) return const _AudioOutcome(blobs: {}, downloaded: 0);

    Set<String>? index;
    var hasIndex = false;
    try {
      final file = await _retry(() => client.read('audio_index.json'));
      if (file != null && file.text.trim().isNotEmpty) {
        final decoded = jsonDecode(file.text);
        if (decoded is List) {
          index = {
            for (final item in decoded)
              if (item is String && item.trim().isNotEmpty)
                SyncAttachment.safeBaseName(item),
          };
          hasIndex = true;
        } else {
          debugPrint('audio_index.json 顶层不是数组，按无索引处理');
        }
      }
    } on SyncException catch (error) {
      warnings.add('读取远端录音索引失败：${error.message}');
      return const _AudioOutcome(blobs: {}, downloaded: 0);
    } on FormatException catch (error) {
      debugPrint('audio_index.json 解析失败，尝试直接下载：$error');
    }

    final blobs = <String, _BlobInfo>{};
    final cache = <String, _BlobInfo>{};
    var downloaded = 0;
    for (final entry in byName.entries) {
      final name = SyncAttachment.safeBaseName(entry.key);
      if (name.isEmpty) continue;
      if (hasIndex && !index!.contains(name)) {
        debugPrint('录音尚未出现在 audio_index.json：$name');
        continue;
      }
      final cached = cache[name];
      if (cached != null) {
        for (final attachment in entry.value) {
          blobs[attachment.uuid] = cached;
        }
        continue;
      }

      RemoteFile? remote;
      try {
        remote = await _retry(() => client.read('audio/$name'));
      } on SyncException catch (error) {
        warnings.add('下载录音失败：${error.message}');
        continue;
      }
      if (remote == null || remote.bytes.isEmpty) {
        warnings.add('云端缺少录音：$name');
        continue;
      }
      if (remote.bytes.length > kMaxAudioBytes) {
        warnings.add('录音超过 100 MB，已跳过：$name');
        continue;
      }

      final hash = sha256.convert(remote.bytes).toString();
      try {
        final relative = await store.importAudioBlob(
          hash,
          remote.bytes,
          _extensionOf(name),
        );
        final info = _BlobInfo(
          relative: relative,
          sha256: hash,
          byteSize: remote.bytes.length,
        );
        cache[name] = info;
        downloaded++;
        for (final attachment in entry.value) {
          blobs[attachment.uuid] = info;
        }
      } on FormatException catch (error) {
        warnings.add(error.message);
      } on FileSystemException catch (error) {
        warnings.add('写入录音失败：$name');
        debugPrint('$error');
      }
    }
    return _AudioOutcome(blobs: blobs, downloaded: downloaded);
  }

  Future<Set<String>?> _listingFor(
    CloudStorage client,
    Map<String, Set<String>?> cache,
    String remotePath,
  ) async {
    final slash = remotePath.lastIndexOf('/');
    final dir = remotePath.substring(0, slash);
    if (!cache.containsKey(dir)) {
      try {
        cache[dir] = await client.list(dir);
      } on SyncException catch (error) {
        // 列目录不可用不算致命错误，退回“不确定是否存在”。
        debugPrint('读取远端资源目录失败：${error.message}');
        cache[dir] = null;
      }
    }
    return cache[dir];
  }

  Future<T> _retry<T>(Future<T> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await action();
      } on SyncException catch (error) {
        final code = error.statusCode;
        final retryable = code == 429 || (code != null && code >= 500);
        if (!retryable || attempt >= 2) rethrow;
        await Future<void>.delayed(lockRetryDelay * (attempt + 1));
      }
    }
  }

  SyncAttachment _withStorage(SyncAttachment attachment, _BlobInfo? blob) {
    if (blob == null) return attachment;
    return attachment.copyWith(
      storagePath: blob.relative,
      sha256: blob.sha256,
      byteSize: blob.byteSize,
    );
  }

  static String _extensionOf(String name) {
    final extension = p.extension(name).replaceFirst('.', '').toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(extension) ? extension : 'bin';
  }

  Future<SyncSnapshot> _readLocalSnapshot() async {
    final snapshot = await store.readSyncSnapshot();
    if (snapshot == null) {
      throw const SyncException('当前数据目录处于兼容模式，暂不支持同步');
    }
    return snapshot;
  }

  Future<SyncState> _readState() async {
    final raw = await store.readSyncState();
    if (raw == null || raw.trim().isEmpty) return SyncState();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return SyncState.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (error) {
      debugPrint('同步状态解析失败，按空状态处理：$error');
    }
    return SyncState();
  }

  ManifestV1? _parseV1Manifest(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final decoded = _decodeJson(text, 'manifest.json');
    try {
      return SyncCodec.parseManifestV1(decoded);
    } on FormatException {
      // manifest 损坏时重建一份，不因此永久卡住同步。
      return null;
    }
  }

  V1ParseResult _parseDiary(String? text) {
    if (text == null || text.trim().isEmpty) {
      return const V1ParseResult(notes: [], preservedRows: [], skipped: 0);
    }
    final decoded = _decodeJson(text, 'diary.json');
    try {
      return SyncCodec.parseDiaryV1(decoded);
    } on FormatException catch (error) {
      throw SyncException('远端 diary.json 格式不正确：${error.message}');
    }
  }

  ManifestV2? _parseV2Manifest(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final decoded = _decodeJson(text, 'v2/manifest.json');
    try {
      return SyncCodec.parseManifestV2(decoded);
    } on FormatException catch (error) {
      throw SyncException('远端 v2/manifest.json 格式不正确：${error.message}');
    }
  }

  List<SyncNote> _parseV2Notes(String? text) {
    if (text == null || text.trim().isEmpty) return const [];
    final decoded = _decodeJson(text, 'v2/notes.json');
    try {
      return SyncCodec.parseNotesV2(decoded);
    } on FormatException catch (error) {
      throw SyncException('远端 v2/notes.json 格式不正确：${error.message}');
    }
  }

  TombstoneParseResult _parseTombstones(String? text) {
    if (text == null || text.trim().isEmpty) {
      return const TombstoneParseResult(tombstones: {}, preservedRows: []);
    }
    final decoded = _decodeJson(text, 'v2/tombstones.json');
    try {
      return SyncCodec.parseTombstonesV2(decoded);
    } on FormatException catch (error) {
      throw SyncException('远端 v2/tombstones.json 格式不正确：${error.message}');
    }
  }

  /// 手机截图索引是旁路数据：解析失败只警告并当作“不可用”，不能当成空
  /// 索引，否则会把电脑端已挂接的手机截图全部摘掉。
  _ImageIndexParse _parseImageIndex(String? text) {
    if (text == null || text.trim().isEmpty) {
      return const _ImageIndexParse(
        entries: [],
        present: false,
        skipped: 0,
        malformed: false,
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const _ImageIndexParse(
        entries: [],
        present: false,
        skipped: 0,
        malformed: true,
      );
    }
    try {
      final parsed = SyncCodec.parseImageIndex(decoded);
      return _ImageIndexParse(
        entries: parsed.entries,
        present: true,
        skipped: parsed.skipped,
        malformed: false,
      );
    } on FormatException {
      return const _ImageIndexParse(
        entries: [],
        present: false,
        skipped: 0,
        malformed: true,
      );
    }
  }

  Object? _decodeJson(String text, String name) {
    try {
      return jsonDecode(text);
    } on FormatException catch (error) {
      throw SyncException('远端 $name 不是合法 JSON：${error.message}');
    }
  }

  /// 忽略时间戳等易变字段后内容仍相同，就不再上传。
  Future<void> _writeIfChanged(
    CloudStorage client,
    String path,
    Map<String, dynamic> data, {
    required String? previous,
    Set<String> ignoreKeys = const {},
    String? writerDevice,
  }) async {
    if (_samePayload(
      previous,
      data,
      ignoreKeys: ignoreKeys,
      writerDevice: writerDevice,
    )) {
      return;
    }
    await client.write(path, utf8.encode(jsonEncode(data)));
  }

  bool _samePayload(
    String? previous,
    Map<String, dynamic> next, {
    Set<String> ignoreKeys = const {},
    String? writerDevice,
  }) {
    if (previous == null || previous.trim().isEmpty) return false;
    Object? decoded;
    try {
      decoded = jsonDecode(previous);
    } on FormatException {
      return false;
    }
    if (decoded is! Map) return false;
    final before = _normalizedPayload(
      decoded.cast<String, dynamic>(),
      ignoreKeys,
      writerDevice,
    );
    final after = _normalizedPayload(next, ignoreKeys, writerDevice);
    return _canonicalJson(before) == _canonicalJson(after);
  }

  Map<String, dynamic> _normalizedPayload(
    Map<String, dynamic> source,
    Set<String> ignoreKeys,
    String? writerDevice,
  ) {
    final result = <String, dynamic>{};
    for (final entry in source.entries) {
      if (ignoreKeys.contains(entry.key)) continue;
      if (writerDevice != null &&
          entry.key == 'writers' &&
          entry.value is Map) {
        final writers = <String, dynamic>{};
        for (final writer in (entry.value as Map).entries) {
          final name = writer.key.toString();
          final value = writer.value;
          if (name == writerDevice && value is Map) {
            // 本机的 last_seen 每轮都在变，不代表数据变化。
            final copy = Map<String, dynamic>.from(
              value.cast<String, dynamic>(),
            )..remove('last_seen');
            writers[name] = copy;
          } else {
            writers[name] = value;
          }
        }
        result[entry.key] = writers;
        continue;
      }
      result[entry.key] = entry.value;
    }
    return result;
  }

  String _canonicalJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return '{${[for (final key in keys) '${jsonEncode(key)}:${_canonicalJson(value[key])}'].join(',')}}';
    }
    if (value is List) {
      return '[${[for (final item in value) _canonicalJson(item)].join(',')}]';
    }
    return jsonEncode(value);
  }

  /// 记录主数据文件当前的远端版本；失败只影响下一轮多同步一次。
  Future<Map<String, String>> _refreshRemoteEtags(
    CloudStorage client,
    Map<String, String> previous,
  ) async {
    final result = Map<String, String>.from(previous);
    for (final path in _probePaths) {
      try {
        final stat = await client.stat(path);
        final revision = stat?.revision;
        if (revision == null) {
          result.remove(path);
        } else {
          result[path] = revision;
        }
      } on UnsupportedError {
        result.remove(path);
      } catch (error) {
        debugPrint('读取远端版本失败：$error');
      }
    }
    return result;
  }

  void _collectRaw(Map<String, String> raw, String path, String? text) {
    if (text != null && text.trim().isNotEmpty) raw[path] = text;
  }

  /// 覆盖远端前把 JSON 留一份本地副本，最多保留 20 次。
  Future<void> _backupRemote(Map<String, String> files) async {
    if (files.isEmpty) return;
    final stamp =
        '${_clock().millisecondsSinceEpoch}-${_backupSerial++ % 1000}';
    final dir = Directory(p.join(store.rootDir.path, 'sync_backup', stamp));
    try {
      for (final entry in files.entries) {
        final target = File(p.joinAll([dir.path, ...entry.key.split('/')]));
        await target.parent.create(recursive: true);
        await target.writeAsString(entry.value, flush: true);
      }
      await _pruneBackups();
    } catch (error) {
      debugPrint('备份远端同步数据失败：$error');
    }
  }

  Future<void> _pruneBackups() async {
    final root = Directory(p.join(store.rootDir.path, 'sync_backup'));
    if (!await root.exists()) return;
    final dirs = await root
        .list(followLinks: false)
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    if (dirs.length <= 20) return;
    dirs.sort((a, b) => a.path.compareTo(b.path));
    for (final dir in dirs.take(dirs.length - 20)) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException catch (error) {
        debugPrint('清理同步备份失败：$error');
      }
    }
  }

  void _ensureCurrent(int epoch) {
    if (_disposed) throw const SyncException('同步已取消');
    if (epoch != _epoch) {
      throw const SyncException('同步配置已更改，本次同步已取消');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _debounce?.cancel();
    _debounce = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  static bool _sameConfig(SyncConfig a, SyncConfig b) {
    return a.baseUrl == b.baseUrl &&
        a.username == b.username &&
        a.remoteDir == b.remoteDir &&
        a.enabled == b.enabled &&
        a.audioEnabled == b.audioEnabled;
  }

  static String _mimeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      default:
        return 'application/octet-stream';
    }
  }
}

class _AssetOutcome {
  const _AssetOutcome({
    required this.blobs,
    required this.uploaded,
    required this.downloaded,
    required this.audioDownloaded,
    required this.warnings,
    required this.remoteRevisions,
  });

  /// 附件 uuid → 本地 blob 信息（图片与录音共用）。
  final Map<String, _BlobInfo> blobs;
  final int uploaded;
  final int downloaded;
  final int audioDownloaded;
  final List<String> warnings;
  final Map<String, String> remoteRevisions;
}

class _AudioOutcome {
  const _AudioOutcome({required this.blobs, required this.downloaded});

  final Map<String, _BlobInfo> blobs;
  final int downloaded;
}

class _BlobInfo {
  const _BlobInfo({
    required this.relative,
    required this.sha256,
    required this.byteSize,
  });

  final String relative;
  final String sha256;
  final int byteSize;
}

class _ImageIndexParse {
  const _ImageIndexParse({
    required this.entries,
    required this.present,
    required this.skipped,
    required this.malformed,
  });

  final List<SyncImageEntry> entries;
  final bool present;
  final int skipped;
  final bool malformed;
}
