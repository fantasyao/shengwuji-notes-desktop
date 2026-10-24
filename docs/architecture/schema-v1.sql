-- 声物记桌面端本地库 schema v1
-- 规范：docs/architecture/database.md
--
-- 约定：
--   * 时间一律 INTEGER，Unix epoch 毫秒（UTC）；空值表示“未知”，不要用 0 冒充。
--   * 身份一律 uuid TEXT；禁止把自增 id 当跨端身份。
--   * 删除采用“硬删除 + tombstones 墓碑”，与手机端 sync_deleted 同构。
--   * 附件文件不可变，路径由 sha256 派生；数据库只存相对路径。
--
-- 本文件只用于“新建空库”。升级迁移追加到 DbHelper 的 migrations 中，
-- 不修改本文件历史段；PRAGMA user_version 由迁移代码最后写入。
-- 注意：foreign_keys 是连接级开关，应用每次打开连接都要重新执行。

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS app_meta (
  key   TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);

-- 笔记。mark 是手机端 v17 的固定标注（urgent/star/idea/task），
-- 不是用户标签；用户标签走 tags + note_tags。
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
);

CREATE INDEX IF NOT EXISTS ix_notes_created
  ON notes (is_archived, created_at DESC, uuid);
CREATE INDEX IF NOT EXISTS ix_notes_sort
  ON notes (is_archived, sort_order, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_notes_updated
  ON notes (updated_at);
CREATE INDEX IF NOT EXISTS ix_notes_mark
  ON notes (mark) WHERE mark IS NOT NULL;

-- 用户标签。name 保留展示形态，name_key 是归一化后的唯一键
-- （trim + 合并空白 + 小写 + NFC，归一化在 Dart 侧完成，不依赖
-- SQLite 的 NOCASE——它只处理 ASCII）。
CREATE TABLE IF NOT EXISTS tags (
  uuid        TEXT PRIMARY KEY NOT NULL,
  name        TEXT NOT NULL,
  name_key    TEXT NOT NULL,
  color       INTEGER,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  rev         INTEGER NOT NULL DEFAULT 1,
  extras_json TEXT NOT NULL DEFAULT '{}'
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_tags_name_key ON tags (name_key);

-- 笔记 <-> 标签。标签集合属于“笔记状态”，随笔记的 updated_at 一起裁决；
-- 本表只是关系投影，不单独同步。
CREATE TABLE IF NOT EXISTS note_tags (
  note_uuid  TEXT NOT NULL REFERENCES notes (uuid) ON DELETE CASCADE,
  tag_uuid   TEXT NOT NULL REFERENCES tags (uuid) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (note_uuid, tag_uuid)
);

CREATE INDEX IF NOT EXISTS ix_note_tags_tag ON note_tags (tag_uuid, note_uuid);

-- 附件。kind=image/audio，按内容寻址存 blob。
-- storage_path 为空表示“远端有、本机未下载”（仅 v1 音频桥接会出现）；
-- 此时 sync_name 必须非空，下载完成后回填 sha256/storage_path/byte_size。
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
);

CREATE INDEX IF NOT EXISTS ix_attachments_note
  ON attachments (note_uuid, sort_order, uuid);
CREATE INDEX IF NOT EXISTS ix_attachments_sha
  ON attachments (sha256);
-- 同一段音频可以被多条笔记引用，sync_name 不能全局唯一；
-- 上传时由同步层按 basename 去重，同名不同哈希则改名。
CREATE INDEX IF NOT EXISTS ix_attachments_sync_name
  ON attachments (sync_name) WHERE sync_name IS NOT NULL;

-- 物品（手机端 items 的桌面镜像）。手机端 v17 没有时间戳，
-- 从 v1 导入的行允许为空；本机新建的数据必须写入时间。
CREATE TABLE IF NOT EXISTS items (
  uuid        TEXT PRIMARY KEY NOT NULL,
  name        TEXT NOT NULL DEFAULT '',
  location    TEXT NOT NULL DEFAULT '',
  created_at  INTEGER,
  updated_at  INTEGER,
  rev         INTEGER NOT NULL DEFAULT 1,
  extras_json TEXT NOT NULL DEFAULT '{}'
);

-- 删除墓碑。行本身已被硬删除，墓碑负责防复活与跨端传播。
CREATE TABLE IF NOT EXISTS tombstones (
  entity     TEXT NOT NULL CHECK (entity IN ('note', 'item', 'tag')),
  uuid       TEXT NOT NULL,
  deleted_at INTEGER NOT NULL,
  rev        INTEGER NOT NULL DEFAULT 1,
  origin     TEXT,
  PRIMARY KEY (entity, uuid)
);

CREATE INDEX IF NOT EXISTS ix_tombstones_deleted
  ON tombstones (deleted_at);

PRAGMA user_version = 1;
