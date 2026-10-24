import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import '../sync/sync_models.dart';
import 'db_schema.dart';
import 'image_payload.dart';
import 'note_backend.dart';

/// `notes.json` 无法迁移时抛出，`NoteStore` 据此进入 JSON 兼容模式。
class LegacyMigrationException implements Exception {
  const LegacyMigrationException(this.cause);

  final Object cause;

  @override
  String toString() => 'notes.json 迁移失败：$cause';
}

/// SQLite 后端：笔记、附件索引与墓碑都在同一个事务里维护。
class NoteDatabase implements NoteBackend, SyncCapableNoteBackend {
  NoteDatabase._(this.rootDir, this._db);

  static const Uuid _uuid = Uuid();
  static const Set<String> _knownKeys = {
    'uuid',
    'content',
    'created_at',
    'updated_at',
    'images',
    'tag',
    'archived',
    'locked',
    'sort_order',
  };

  static bool _ffiReady = false;

  final Directory rootDir;
  final Database _db;

  File get databaseFile => File(p.join(rootDir.path, 'shengwuji.db'));

  static Future<NoteDatabase> open(Directory rootDir) async {
    if (!_ffiReady) {
      sqfliteFfiInit();
      _ffiReady = true;
    }
    await rootDir.create(recursive: true);

    final dbFile = File(p.join(rootDir.path, 'shengwuji.db'));
    if (!await dbFile.exists()) {
      final legacyNotes = File(p.join(rootDir.path, 'notes.json'));
      if (await legacyNotes.exists()) {
        await _migrateLegacy(rootDir);
      }
    }

    final db = await databaseFactoryFfi.openDatabase(
      dbFile.path,
      options: OpenDatabaseOptions(
        version: kDatabaseSchemaVersion,
        singleInstance: false,
        onConfigure: (db) async {
          // foreign_keys 是连接级开关，每次打开都要重新设置。
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA busy_timeout = 5000');
        },
        onCreate: (db, version) async {
          for (final statement in kSchemaV1Statements) {
            await db.execute(statement);
          }
        },
      ),
    );

    try {
      await db.execute('PRAGMA journal_mode = WAL');
      await db.execute('PRAGMA synchronous = NORMAL');
    } catch (error) {
      debugPrint('设置 SQLite WAL 失败：$error');
    }

    final database = NoteDatabase._(rootDir, db);
    await database._ensureMeta();
    return database;
  }

  @override
  Future<List<Note>> load() async {
    final rows = await _db.query('notes', orderBy: 'created_at DESC, uuid ASC');
    final attachmentRows = await _db.query(
      'attachments',
      columns: ['note_uuid', 'storage_path', 'sync_name', 'sort_order', 'uuid'],
      where: "kind = 'image'",
      orderBy: 'note_uuid, sort_order, uuid',
    );

    final imagesByNote = <String, List<String>>{};
    for (final row in attachmentRows) {
      // 云端已登记但尚未下载的图片没有本地文件，等同步下载后再显示。
      final path = row['storage_path'];
      if (path is! String || path.isEmpty) continue;
      final noteUuid = row['note_uuid'] as String;
      (imagesByNote[noteUuid] ??= []).add(path);
    }

    // 录音保留“云端有、本机未下载”的条目，界面据此提示开启音频同步。
    final audioRows = await _db.query(
      'attachments',
      columns: [
        'note_uuid',
        'uuid',
        'storage_path',
        'sync_name',
        'duration_ms',
        'sort_order',
      ],
      where: "kind = 'audio'",
      orderBy: 'note_uuid, sort_order, uuid',
    );
    final audiosByNote = <String, List<NoteAudio>>{};
    for (final row in audioRows) {
      final uuid = row['uuid'] as String?;
      if (uuid == null || uuid.isEmpty) continue;
      final path = row['storage_path'];
      final name = row['sync_name'];
      if ((path is! String || path.isEmpty) &&
          (name is! String || name.isEmpty)) {
        continue;
      }
      (audiosByNote[row['note_uuid'] as String] ??= []).add(
        NoteAudio(
          uuid: uuid,
          path: path is String && path.isNotEmpty ? path : null,
          fileName: name is String && name.isNotEmpty ? name : null,
          durationMs: row['duration_ms'] as int?,
        ),
      );
    }

    return rows
        .map(
          (row) => _noteFromRow(
            row,
            imagesByNote[row['uuid'] as String] ?? const [],
            audiosByNote[row['uuid'] as String] ?? const [],
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> writeAll(List<Note> notes) async {
    await _db.transaction((txn) async {
      final existing = <String, Map<String, Object?>>{
        for (final row in await txn.query('notes')) row['uuid'] as String: row,
      };
      final imageRows = await txn.query(
        'attachments',
        where: "kind = 'image'",
        orderBy: 'note_uuid, sort_order, uuid',
      );
      final imagesByNote = <String, List<Map<String, Object?>>>{};
      for (final row in imageRows) {
        (imagesByNote[row['note_uuid'] as String] ??= []).add(row);
      }

      final incoming = <String>{};

      for (final note in notes) {
        if (note.uuid.isEmpty || !incoming.add(note.uuid)) continue;
        final values = _noteValues(note);
        final old = existing[note.uuid];
        if (old == null) {
          await txn.insert('notes', {'uuid': note.uuid, ...values, 'rev': 1});
        } else if (_noteChanged(old, values)) {
          await txn.update(
            'notes',
            {...values, 'rev': ((old['rev'] as int?) ?? 1) + 1},
            where: 'uuid = ?',
            whereArgs: [note.uuid],
          );
        }

        final rows = imagesByNote[note.uuid] ?? const [];
        final desired = _desiredImages(note);
        if (old == null || !_sameImages(rows, desired)) {
          await _syncAttachments(txn, note, rows, desired);
        }

        // 同 uuid 的笔记被重新创建时，旧墓碑必须让位。
        await txn.delete(
          'tombstones',
          where: "entity = 'note' AND uuid = ?",
          whereArgs: [note.uuid],
        );
      }

      for (final entry in existing.entries) {
        if (incoming.contains(entry.key)) continue;
        await txn.delete('notes', where: 'uuid = ?', whereArgs: [entry.key]);
        await txn.insert('tombstones', {
          'entity': 'note',
          'uuid': entry.key,
          'deleted_at': DateTime.now().millisecondsSinceEpoch,
          'rev': ((entry.value['rev'] as int?) ?? 1) + 1,
          'origin': 'local',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      await _bumpDataRevision(txn);
    });
  }

  @override
  Future<String> saveImage(Uint8List bytes) async {
    final payload = normalizeImage(bytes);
    if (payload.bytes.length > kMaxImageBytes) {
      throw const ImageTooLargeException(kMaxImageBytes);
    }
    final digest = sha256.convert(payload.bytes).toString();
    final relative =
        'blobs/${digest.substring(0, 2)}/$digest.${payload.extension}';
    final file = _fileFor(relative);
    if (await file.exists()) return relative;

    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.${_uuid.v4().substring(0, 8)}.tmp');
    try {
      await tmp.writeAsBytes(payload.bytes, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        // 另一个写入者抢先落盘时目标已存在，直接复用。
        if (!await file.exists()) rethrow;
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 临时文件清理失败不影响已落盘的数据。
      }
    }
    return relative;
  }

  @override
  Future<void> deleteImage(String name) async {
    final relative = sanitizeAttachmentPath(name);
    if (!isManagedAttachmentPath(relative)) return;

    final rows = await _db.rawQuery(
      'SELECT COUNT(*) FROM attachments WHERE storage_path = ?',
      [relative],
    );
    final refs = (rows.first.values.first as int?) ?? 0;
    if (refs > 0) return;

    final file = _fileFor(relative);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint('删除附件失败 $name：$error');
    }
  }

  @override
  Future<int> copyTo(Directory target) async {
    await target.create(recursive: true);
    final targetDb = File(p.join(target.path, 'shengwuji.db'));
    final tmp = File(p.join(target.path, 'shengwuji.db.copying'));
    await _deleteDatabaseFiles(tmp.path);

    try {
      try {
        await _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (error) {
        debugPrint('WAL checkpoint 失败，继续复制：$error');
      }
      final escaped = tmp.path.replaceAll("'", "''");
      await _db.execute("VACUUM INTO '$escaped'");

      final check = await databaseFactoryFfi.openDatabase(
        tmp.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        final result = await check.rawQuery('PRAGMA integrity_check');
        final value = result.isEmpty ? null : result.first.values.first;
        if (value != 'ok') {
          throw FormatException('目标数据库校验失败：$value');
        }
      } finally {
        await check.close();
      }

      final copiedBlobs = await _copyBlobs(target);
      await _deleteDatabaseFiles(targetDb.path);
      try {
        await tmp.rename(targetDb.path);
      } on FileSystemException {
        await tmp.copy(targetDb.path);
        await tmp.delete();
      }
      return copiedBlobs + 1;
    } catch (error) {
      await _deleteDatabaseFiles(tmp.path);
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    try {
      await _db.close();
    } catch (error) {
      debugPrint('关闭数据库失败：$error');
    }
  }

  @override
  Future<SyncSnapshot> readSyncSnapshot() async {
    final noteRows = await _db.query('notes');
    final attachmentRows = await _db.query(
      'attachments',
      orderBy: 'note_uuid, sort_order, uuid',
    );
    final byNote = <String, List<SyncAttachment>>{};
    for (final row in attachmentRows) {
      final attachment = _syncAttachmentFromRow(row);
      if (attachment == null) continue;
      (byNote[row['note_uuid'] as String] ??= []).add(attachment);
    }
    final tombstoneRows = await _db.query(
      'tombstones',
      where: "entity = 'note'",
    );
    return SyncSnapshot(
      notes: [
        for (final row in noteRows)
          SyncNote(
            uuid: row['uuid'] as String,
            content: row['content'] as String? ?? '',
            createdAt: (row['created_at'] as int?) ?? 0,
            updatedAt: (row['updated_at'] as int?) ?? 0,
            mark: row['mark'] as String?,
            archived: (row['is_archived'] as int? ?? 0) == 1,
            locked: (row['is_locked'] as int? ?? 0) == 1,
            sortOrder: row['sort_order'] as int?,
            rev: (row['rev'] as int?) ?? 1,
            extras: _decodeExtras(row['extras_json']),
            attachments: byNote[row['uuid'] as String] ?? const [],
          ),
      ],
      tombstones: {
        for (final row in tombstoneRows)
          row['uuid'] as String: NoteTombstone(
            uuid: row['uuid'] as String,
            deletedAt: (row['deleted_at'] as int?) ?? 0,
            rev: (row['rev'] as int?) ?? 1,
            origin: row['origin'] as String? ?? 'local',
          ),
      },
    );
  }

  @override
  Future<void> applySync({
    required SyncSnapshot expected,
    required SyncSnapshot finalState,
  }) async {
    await _db.transaction((txn) async {
      await _verifyUnchanged(txn, expected);

      final existingRows = <String, Map<String, Object?>>{
        for (final row in await txn.query('notes')) row['uuid'] as String: row,
      };
      final finalUuids = <String>{};
      for (final note in finalState.notes) {
        if (note.uuid.isEmpty || !finalUuids.add(note.uuid)) continue;
        final old = existingRows[note.uuid];
        final values = {
          'content': note.content,
          'mark': note.mark,
          'is_archived': note.archived ? 1 : 0,
          'is_locked': note.locked ? 1 : 0,
          'sort_order': note.sortOrder,
          'created_at': note.createdAt,
          'updated_at': note.updatedAt,
          'extras_json': jsonEncode(note.extras),
        };
        if (old == null) {
          await txn.insert('notes', {
            'uuid': note.uuid,
            ...values,
            'rev': note.rev <= 0 ? 1 : note.rev,
          });
        } else if (_noteChanged(old, values)) {
          await txn.update(
            'notes',
            {...values, 'rev': ((old['rev'] as int?) ?? 1) + 1},
            where: 'uuid = ?',
            whereArgs: [note.uuid],
          );
        }
        await _syncAttachmentsExact(txn, note);
      }

      for (final uuid in existingRows.keys) {
        if (finalUuids.contains(uuid)) continue;
        await txn.delete('notes', where: 'uuid = ?', whereArgs: [uuid]);
      }

      await txn.delete('tombstones', where: "entity = 'note'");
      for (final tombstone in finalState.tombstones.values) {
        await txn.insert('tombstones', {
          'entity': 'note',
          'uuid': tombstone.uuid,
          'deleted_at': tombstone.deletedAt,
          'rev': tombstone.rev,
          'origin': tombstone.origin,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      await _bumpDataRevision(txn);
    });
  }

  @override
  Future<String?> readSyncState() async {
    final rows = await _db.query(
      'app_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['sync_state'],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<void> writeSyncState(String json) async {
    await _db.insert('app_meta', {
      'key': 'sync_state',
      'value': json,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _verifyUnchanged(
    Transaction txn,
    SyncSnapshot expected,
  ) async {
    final rows = await txn.query(
      'notes',
      columns: ['uuid', 'updated_at', 'rev'],
    );
    if (rows.length != expected.notes.length) {
      throw const LocalChangedDuringSync();
    }
    final current = {
      for (final row in rows)
        row['uuid'] as String: (
          row['updated_at'] as int?,
          row['rev'] as int?,
        ),
    };
    for (final note in expected.notes) {
      final value = current[note.uuid];
      if (value == null ||
          value.$1 != note.updatedAt ||
          value.$2 != note.rev) {
        throw const LocalChangedDuringSync();
      }
    }

    final tombstoneRows = await txn.query(
      'tombstones',
      columns: ['uuid', 'deleted_at'],
      where: "entity = 'note'",
    );
    if (tombstoneRows.length != expected.tombstones.length) {
      throw const LocalChangedDuringSync();
    }
    final currentTombstones = {
      for (final row in tombstoneRows)
        row['uuid'] as String: row['deleted_at'] as int?,
    };
    for (final tombstone in expected.tombstones.values) {
      if (currentTombstones[tombstone.uuid] != tombstone.deletedAt) {
        throw const LocalChangedDuringSync();
      }
    }
  }

  Future<void> _syncAttachmentsExact(
    Transaction txn,
    SyncNote note,
  ) async {
    final existingRows = await txn.query(
      'attachments',
      where: 'note_uuid = ?',
      whereArgs: [note.uuid],
    );
    final existing = <String, Map<String, Object?>>{
      for (final row in existingRows) row['uuid'] as String: row,
    };
    final desired = <String>{};
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final attachment in note.attachments) {
      final storagePath = attachment.storagePath;
      final syncName = attachment.syncName ?? attachment.assetFileName;
      if (storagePath == null && (syncName == null || syncName.isEmpty)) {
        continue;
      }
      if (storagePath != null &&
          (attachment.sha256 == null || attachment.byteSize == null)) {
        continue;
      }
      desired.add(attachment.uuid);
      final values = <String, Object?>{
        'kind': attachment.kind,
        'origin': attachment.origin,
        'sha256': attachment.sha256,
        'storage_path': storagePath,
        'sync_name': syncName,
        'mime_type': attachment.mimeType,
        'byte_size': attachment.byteSize,
        'duration_ms': attachment.durationMs,
        'sort_order': attachment.sortOrder,
        'extras_json': jsonEncode(attachment.extras),
      };
      final old = existing[attachment.uuid];
      if (old == null) {
        await txn.insert('attachments', {
          'uuid': attachment.uuid,
          'note_uuid': note.uuid,
          ...values,
          'created_at': now,
          'updated_at': now,
          'rev': attachment.rev <= 0 ? 1 : attachment.rev,
        });
      } else {
        var changed = false;
        for (final entry in values.entries) {
          if (old[entry.key] != entry.value) {
            changed = true;
            break;
          }
        }
        if (changed) {
          await txn.update(
            'attachments',
            {
              ...values,
              'updated_at': now,
              'rev': ((old['rev'] as int?) ?? 1) + 1,
            },
            where: 'uuid = ?',
            whereArgs: [attachment.uuid],
          );
        }
      }
    }

    for (final row in existingRows) {
      final uuid = row['uuid'] as String;
      if (desired.contains(uuid)) continue;
      await txn.delete('attachments', where: 'uuid = ?', whereArgs: [uuid]);
    }
  }

  SyncAttachment? _syncAttachmentFromRow(Map<String, Object?> row) {
    final uuid = row['uuid'];
    final kind = row['kind'];
    if (uuid is! String || uuid.isEmpty || kind is! String) return null;
    return SyncAttachment(
      uuid: uuid,
      kind: kind,
      origin: row['origin'] as String? ?? 'import',
      sha256: row['sha256'] as String?,
      storagePath: row['storage_path'] as String?,
      syncName: row['sync_name'] as String?,
      mimeType: row['mime_type'] as String?,
      byteSize: row['byte_size'] as int?,
      durationMs: row['duration_ms'] as int?,
      sortOrder: (row['sort_order'] as int?) ?? 0,
      rev: (row['rev'] as int?) ?? 1,
      extras: _decodeExtras(row['extras_json']),
    );
  }

  Future<void> _ensureMeta() async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      await txn.insert('app_meta', {
        'key': 'created_at',
        'value': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.insert('app_meta', {
        'key': 'data_revision',
        'value': '0',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  Note _noteFromRow(
    Map<String, Object?> row,
    List<String> images,
    List<NoteAudio> audios,
  ) {
    final map = <String, dynamic>{
      ..._decodeExtras(row['extras_json']),
      'uuid': row['uuid'],
      'content': row['content'] ?? '',
      'created_at': _dateFromEpoch(row['created_at']).toIso8601String(),
      'updated_at': _dateFromEpoch(row['updated_at']).toIso8601String(),
      'images': images,
      'audios': [for (final audio in audios) audio.toJson()],
      'tag': row['mark'],
      'archived': (row['is_archived'] as int? ?? 0) == 1,
    };
    if ((row['is_locked'] as int? ?? 0) == 1) map['locked'] = 1;
    final sortOrder = row['sort_order'] as int?;
    if (sortOrder != null) map['sort_order'] = sortOrder;
    return Note.fromJson(map);
  }

  Map<String, Object?> _noteValues(Note note) {
    return {
      'content': note.content,
      'mark': note.tag,
      'is_archived': note.archived ? 1 : 0,
      'is_locked': _isTruthy(note.raw['locked']) ? 1 : 0,
      'sort_order': note.raw['sort_order'] is num
          ? (note.raw['sort_order'] as num).toInt()
          : null,
      'created_at': note.createdAt.toUtc().millisecondsSinceEpoch,
      'updated_at': note.updatedAt.toUtc().millisecondsSinceEpoch,
      'extras_json': _encodeExtras(note),
    };
  }

  bool _noteChanged(Map<String, Object?> old, Map<String, Object?> values) {
    for (final entry in values.entries) {
      if (old[entry.key] != entry.value) return true;
    }
    return false;
  }

  List<String> _desiredImages(Note note) {
    final desired = <String>[];
    for (final rawName in note.images) {
      final relative = sanitizeAttachmentPath(rawName);
      if (!isManagedAttachmentPath(relative) || desired.contains(relative)) {
        continue;
      }
      desired.add(relative);
    }
    return desired;
  }

  bool _sameImages(List<Map<String, Object?>> rows, List<String> desired) {
    final current = <String>[];
    for (final row in rows) {
      final path = row['storage_path'];
      if (path is String && path.isNotEmpty) current.add(path);
    }
    return listEquals(current, desired);
  }

  Future<void> _syncAttachments(
    Transaction txn,
    Note note,
    List<Map<String, Object?>> rows,
    List<String> desired,
  ) async {
    final existing = <String, Map<String, Object?>>{};
    final pendingBySha = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final path = row['storage_path'];
      if (path is String && path.isNotEmpty) {
        existing[path] = row;
      } else {
        final sha = row['sha256'];
        if (sha is String && sha.isNotEmpty) pendingBySha[sha] = row;
      }
    }
    final keep = desired.toSet();

    for (final row in rows) {
      final path = row['storage_path'];
      // 尚未下载的远端附件没有本地路径，编辑器看不到也不该顺手删掉。
      if (path is! String || path.isEmpty) continue;
      if (keep.contains(path)) continue;
      await txn.delete(
        'attachments',
        where: 'uuid = ?',
        whereArgs: [row['uuid']],
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    for (var index = 0; index < desired.length; index++) {
      final relative = desired[index];
      final old = existing[relative];
      if (old != null) {
        if (old['sort_order'] != index) {
          await txn.update(
            'attachments',
            {
              'sort_order': index,
              'updated_at': now,
              'rev': ((old['rev'] as int?) ?? 1) + 1,
            },
            where: 'uuid = ?',
            whereArgs: [old['uuid']],
          );
        }
        continue;
      }

      final file = _fileFor(relative);
      if (!await file.exists()) {
        debugPrint('附件文件缺失，跳过：$relative');
        continue;
      }
      final bytes = await file.readAsBytes();
      final digest = _shaFromPath(relative) ?? sha256.convert(bytes).toString();
      final extension = p
          .extension(relative)
          .replaceFirst('.', '')
          .toLowerCase();
      final pending = pendingBySha[digest];
      if (pending != null) {
        await txn.update(
          'attachments',
          {
            'storage_path': relative,
            'byte_size': bytes.length,
            'mime_type': extension.isEmpty
                ? null
                : 'image/${extension == 'jpg' ? 'jpeg' : extension}',
            'sort_order': index,
            'updated_at': now,
            'rev': ((pending['rev'] as int?) ?? 1) + 1,
          },
          where: 'uuid = ?',
          whereArgs: [pending['uuid']],
        );
        continue;
      }
      await txn.insert('attachments', {
        'uuid': _uuid.v4(),
        'note_uuid': note.uuid,
        'kind': 'image',
        'origin': 'import',
        'sha256': digest,
        'storage_path': relative,
        'mime_type': extension.isEmpty
            ? null
            : 'image/${extension == 'jpg' ? 'jpeg' : extension}',
        'byte_size': bytes.length,
        'sort_order': index,
        'created_at': now,
        'updated_at': now,
        'rev': 1,
        'extras_json': '{}',
      });
    }
  }

  Future<void> _bumpDataRevision(Transaction txn) async {
    final rows = await txn.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: ['data_revision'],
    );
    final current = rows.isEmpty
        ? 0
        : int.tryParse('${rows.first['value']}') ?? 0;
    await txn.insert('app_meta', {
      'key': 'data_revision',
      'value': '${current + 1}',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> _copyBlobs(Directory target) async {
    final source = Directory(p.join(rootDir.path, 'blobs'));
    if (!await source.exists()) return 0;
    var copied = 0;
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: rootDir.path);
      final destination = File(p.join(target.path, relative));
      if (await destination.exists() &&
          await destination.length() == await entity.length()) {
        continue;
      }
      await destination.parent.create(recursive: true);
      await entity.copy(destination.path);
      copied++;
    }
    return copied;
  }

  File _fileFor(String relative) => attachmentFile(rootDir, relative);

  static DateTime _dateFromEpoch(Object? value) {
    final millis = value is int ? value : int.tryParse('$value') ?? 0;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static Map<String, dynamic> _decodeExtras(Object? value) {
    if (value is! String || value.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return decoded.map((key, item) => MapEntry(key.toString(), item));
      }
    } catch (error) {
      debugPrint('extras_json 解析失败，按空对象处理：$error');
    }
    return const {};
  }

  static String _encodeExtras(Note note) {
    final extras = <String, dynamic>{};
    note.raw.forEach((key, value) {
      if (!_knownKeys.contains(key)) extras[key] = value;
    });
    return jsonEncode(extras);
  }

  static bool _isTruthy(Object? value) => value == 1 || value == true;

  static String? _shaFromPath(String relative) {
    final base = p.basenameWithoutExtension(relative);
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(base) ? base : null;
  }

  static Future<void> _migrateLegacy(Directory rootDir) async {
    final tmp = File(p.join(rootDir.path, 'shengwuji.db.migrating'));
    await _deleteDatabaseFiles(tmp.path);

    Database? db;
    try {
      final notesFile = File(p.join(rootDir.path, 'notes.json'));
      final legacyNotes = await _readLegacyNotes(notesFile);
      final fallbackTime =
          (await notesFile.stat()).modified.millisecondsSinceEpoch;

      db = await databaseFactoryFfi.openDatabase(
        tmp.path,
        options: OpenDatabaseOptions(
          version: kDatabaseSchemaVersion,
          singleInstance: false,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: (db, version) async {
            for (final statement in kSchemaV1Statements) {
              await db.execute(statement);
            }
          },
        ),
      );

      final stats = await db.transaction((txn) async {
        var attachments = 0;
        var missingImages = 0;
        for (final legacy in legacyNotes) {
          final map = legacy.map;
          final createdAt =
              _legacyEpoch(map['created_at']) ??
              _legacyEpoch(map['updated_at']) ??
              fallbackTime;
          final updatedAt = _legacyEpoch(map['updated_at']) ?? createdAt;
          await txn.insert('notes', {
            'uuid': legacy.uuid,
            'content': map['content'] is String ? map['content'] as String : '',
            'mark': map['tag'] is String ? map['tag'] as String : null,
            'is_archived': _isTruthy(map['archived']) ? 1 : 0,
            'is_locked': _isTruthy(map['locked']) ? 1 : 0,
            'sort_order': map['sort_order'] is num
                ? (map['sort_order'] as num).toInt()
                : null,
            'created_at': createdAt,
            'updated_at': updatedAt,
            'rev': 1,
            'extras_json': _encodeLegacyExtras(map),
          });

          final images = map['images'];
          if (images is! List) continue;
          final seen = <String>{};
          var sortOrder = 0;
          for (final item in images.whereType<String>()) {
            final name = p.basename(item);
            if (name.isEmpty || !seen.add(name)) continue;
            final file = File(p.join(rootDir.path, 'images', name));
            if (!await file.exists()) {
              missingImages++;
              sortOrder++;
              continue;
            }
            final bytes = await file.readAsBytes();
            final digest = sha256.convert(bytes).toString();
            final detected = detectImageExtension(bytes);
            final extension =
                (detected ?? p.extension(name).replaceFirst('.', ''))
                    .toLowerCase();
            final ext = extension.isEmpty ? 'bin' : extension;
            final relative = 'blobs/${digest.substring(0, 2)}/$digest.$ext';
            final blob = attachmentFile(rootDir, relative);
            if (!await blob.exists()) {
              await blob.parent.create(recursive: true);
              final tmpBlob = File('${blob.path}.migrating');
              await tmpBlob.writeAsBytes(bytes, flush: true);
              await tmpBlob.rename(blob.path);
            }
            await txn.insert('attachments', {
              'uuid': _uuid.v4(),
              'note_uuid': legacy.uuid,
              'kind': 'image',
              'origin': 'import',
              'sha256': digest,
              'storage_path': relative,
              'mime_type': ext == 'bin' ? null : 'image/$ext',
              'byte_size': bytes.length,
              'sort_order': sortOrder,
              'created_at': updatedAt,
              'updated_at': updatedAt,
              'rev': 1,
              'extras_json': '{}',
            });
            attachments++;
            sortOrder++;
          }
        }
        return (
          notes: legacyNotes.length,
          attachments: attachments,
          missingImages: missingImages,
        );
      });

      final now = DateTime.now().toUtc().toIso8601String();
      await db.transaction((txn) async {
        for (final entry in <String, String>{
          'created_at': now,
          'data_revision': '1',
          'legacy_migrated_at': now,
          'legacy_note_count': '${stats.notes}',
          'legacy_attachment_count': '${stats.attachments}',
          'legacy_missing_images': '${stats.missingImages}',
        }.entries) {
          await txn.insert('app_meta', {
            'key': entry.key,
            'value': entry.value,
          });
        }
      });

      final check = await db.rawQuery('PRAGMA integrity_check');
      final value = check.isEmpty ? null : check.first.values.first;
      if (value != 'ok') {
        throw FormatException('integrity_check 未通过：$value');
      }

      await db.close();
      db = null;
      await tmp.rename(p.join(rootDir.path, 'shengwuji.db'));
      await _archiveLegacy(rootDir);
    } catch (error, stack) {
      await db?.close();
      await _deleteDatabaseFiles(tmp.path);
      Error.throwWithStackTrace(LegacyMigrationException(error), stack);
    }
  }

  static Future<List<_LegacyNote>> _readLegacyNotes(File notesFile) async {
    final text = await notesFile.readAsString();
    if (text.trim().isEmpty) return const [];
    final decoded = jsonDecode(text);
    if (decoded is! List) {
      throw const FormatException('notes.json 顶层不是数组');
    }
    final notes = <_LegacyNote>[];
    for (final item in decoded) {
      final map = decodeNoteMap(item);
      if (map == null) continue;
      final uuid = (map['uuid'] as String?)?.trim() ?? '';
      if (uuid.isEmpty) continue;
      notes.add(_LegacyNote(uuid, map));
    }
    return notes;
  }

  static int? _legacyEpoch(Object? value) {
    if (value is num) return value.toInt();
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim())?.toUtc().millisecondsSinceEpoch;
  }

  static String _encodeLegacyExtras(Map<String, dynamic> map) {
    final extras = <String, dynamic>{};
    map.forEach((key, value) {
      if (!_knownKeys.contains(key)) extras[key] = value;
    });
    return jsonEncode(extras);
  }

  static Future<void> _archiveLegacy(Directory rootDir) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final archive = Directory(p.join(rootDir.path, 'legacy', stamp));
    try {
      await archive.create(recursive: true);
      final notes = File(p.join(rootDir.path, 'notes.json'));
      if (await notes.exists()) {
        await notes.rename(p.join(archive.path, 'notes.json'));
      }
      final images = Directory(p.join(rootDir.path, 'images'));
      if (await images.exists()) {
        await images.rename(p.join(archive.path, 'images'));
      }
    } catch (error) {
      // 新库已经可用；旧文件留在原处也不会被再次读取。
      debugPrint('旧数据留档失败（不影响新库）：$error');
    }
  }

  static Future<void> _deleteDatabaseFiles(String path) async {
    for (final suffix in const ['', '-wal', '-shm']) {
      final file = File('$path$suffix');
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException catch (error) {
        debugPrint('清理 $path$suffix 失败：$error');
      }
    }
  }
}

class _LegacyNote {
  const _LegacyNote(this.uuid, this.map);

  final String uuid;
  final Map<String, dynamic> map;
}
