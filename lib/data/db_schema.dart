/// 桌面端本地库 schema。
///
/// 与 `docs/architecture/schema-v1.sql` 保持同步；升级时追加新版本的语句，
/// 不修改历史版本。
library;

const int kDatabaseSchemaVersion = 1;

const List<String> kSchemaV1Statements = [
  '''
  CREATE TABLE IF NOT EXISTS app_meta (
    key   TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS notes (
    uuid        TEXT PRIMARY KEY NOT NULL,
    content     TEXT NOT NULL DEFAULT '',
    mark        TEXT,
    is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    is_locked   INTEGER NOT NULL DEFAULT 0 CHECK (is_locked IN (0, 1)),
    sort_order  INTEGER,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    rev         INTEGER NOT NULL DEFAULT 1,
    extras_json TEXT NOT NULL DEFAULT '{}'
  )
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_notes_created
    ON notes (is_archived, created_at DESC, uuid)
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_notes_sort
    ON notes (is_archived, sort_order, created_at DESC)
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_notes_updated
    ON notes (updated_at)
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_notes_mark
    ON notes (mark) WHERE mark IS NOT NULL
  ''',
  '''
  CREATE TABLE IF NOT EXISTS tags (
    uuid        TEXT PRIMARY KEY NOT NULL,
    name        TEXT NOT NULL,
    name_key    TEXT NOT NULL,
    color       INTEGER,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    rev         INTEGER NOT NULL DEFAULT 1,
    extras_json TEXT NOT NULL DEFAULT '{}'
  )
  ''',
  '''
  CREATE UNIQUE INDEX IF NOT EXISTS ux_tags_name_key ON tags (name_key)
  ''',
  '''
  CREATE TABLE IF NOT EXISTS note_tags (
    note_uuid  TEXT NOT NULL REFERENCES notes (uuid) ON DELETE CASCADE,
    tag_uuid   TEXT NOT NULL REFERENCES tags (uuid) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (note_uuid, tag_uuid)
  )
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_note_tags_tag ON note_tags (tag_uuid, note_uuid)
  ''',
  '''
  CREATE TABLE IF NOT EXISTS attachments (
    uuid         TEXT PRIMARY KEY NOT NULL,
    note_uuid    TEXT NOT NULL REFERENCES notes (uuid) ON DELETE CASCADE,
    kind         TEXT NOT NULL CHECK (kind IN ('image', 'audio', 'file')),
    origin       TEXT NOT NULL DEFAULT 'import',
    sha256       TEXT,
    storage_path TEXT,
    sync_name    TEXT,
    mime_type    TEXT,
    byte_size    INTEGER,
    duration_ms  INTEGER,
    width        INTEGER,
    height       INTEGER,
    sort_order   INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    rev          INTEGER NOT NULL DEFAULT 1,
    extras_json  TEXT NOT NULL DEFAULT '{}',
    CHECK (storage_path IS NOT NULL OR sync_name IS NOT NULL),
    CHECK (storage_path IS NULL OR (sha256 IS NOT NULL AND byte_size IS NOT NULL))
  )
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_attachments_note
    ON attachments (note_uuid, sort_order, uuid)
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_attachments_sha
    ON attachments (sha256)
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_attachments_sync_name
    ON attachments (sync_name) WHERE sync_name IS NOT NULL
  ''',
  '''
  CREATE TABLE IF NOT EXISTS items (
    uuid        TEXT PRIMARY KEY NOT NULL,
    name        TEXT NOT NULL DEFAULT '',
    location    TEXT NOT NULL DEFAULT '',
    created_at  INTEGER,
    updated_at  INTEGER,
    rev         INTEGER NOT NULL DEFAULT 1,
    extras_json TEXT NOT NULL DEFAULT '{}'
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS tombstones (
    entity     TEXT NOT NULL CHECK (entity IN ('note', 'item', 'tag')),
    uuid       TEXT NOT NULL,
    deleted_at INTEGER NOT NULL,
    rev        INTEGER NOT NULL DEFAULT 1,
    origin     TEXT,
    PRIMARY KEY (entity, uuid)
  )
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_tombstones_deleted
    ON tombstones (deleted_at)
  ''',
];
