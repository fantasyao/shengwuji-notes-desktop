# 桌面端数据库架构

> 状态：**P1 已落地**（2026-10-23）。默认存储已是 SQLite，旧 `notes.json` 在
> 首次打开时一次性迁入；迁移失败则保留原文件并回退 JSON 兼容模式。
> 2026-10-24 起，WebDAV 同步所需的快照/墓碑读写、录音附件（下载与播放）
> 和回收站（`is_archived` 标记）也已接入；标签体系、录音录制/导入与附件 GC
> 仍属后续阶段，本文对应章节保留为目标设计。
>
> 落地位置：
> [lib/data/note_store.dart](../../lib/data/note_store.dart)（门面）·
> [lib/data/note_database.dart](../../lib/data/note_database.dart)（SQLite 后端）·
> [lib/data/db_schema.dart](../../lib/data/db_schema.dart)（Dart 版 DDL）·
> [schema-v1.sql](schema-v1.sql)（可执行 DDL）。
>
> 关联规范：[与手机端的同步契约](cloud-sync.md) ·
> 手机端参考：`my_first_app/docs/architecture/database.md`、
> `my_first_app/docs/architecture/cloud-sync.md`。

## 1. 决策摘要

| 决定 | 内容 |
|------|------|
| 本地存储 | 从单文件 JSON 换成 SQLite（`sqflite_common_ffi`），与手机端同源 |
| 身份 | `uuid TEXT` 主键；本地自增 id 永远不作为跨端身份 |
| 时间 | 统一存 Unix epoch 毫秒（UTC），只在同步边界转字符串 |
| 删除 | 硬删除 + `tombstones` 墓碑，与手机端 `sync_deleted` 同构 |
| 附件 | 图片/音频统一进 `attachments` 表，文件按 sha256 内容寻址 |
| 标签 | 用户标签走 `tags` + `note_tags` 多对多；手机端固定标注存 `notes.mark`，两者不混用 |
| 扩展 | 核心字段用列，未知字段进 `extras_json`；新能力优先加表/加列，不做 EAV |
| 同步 | 本地 schema 与同步协议解耦；桌面端新增 `v2/` 命名空间，不把桌面专属字段塞进手机端会重写的文件 |

## 2. 为什么现在要换

### 2.1 P1 之前的问题（已解决）

P1 之前桌面端每次保存都把全部笔记序列化后整文件覆盖
（[lib/state/notes_controller.dart:115](../../lib/state/notes_controller.dart#L115)、
[lib/data/legacy_json_note_store.dart:58](../../lib/data/legacy_json_note_store.dart#L58)）。
笔记量小时没问题，但一旦接同步、标签、音频、图片，会依次撞上：

1. **没有增量语义**：改一条笔记要重写全部数据；同步无法判断“哪些行变了”。
2. **没有墓碑**：删除只从本地数组移除，下一次同步会被云端原样拉回。
3. **没有 `updated_at` 的可靠裁决**：现有 `updated_at` 只在编辑时更新，但导入/合并
   没有统一规则；双向同步会出现来回覆盖。
4. **标签只有一个字符串**：`tag` 目前是手机端的固定标注（紧急/收藏/灵感），
   不是用户标签体系；多标签、按标签筛选、标签重命名都需要关系表。
5. **附件只有图片列表**：`Note.images` 是本地文件名字符串数组，没有时长、MIME、
   哈希、音频类型，也没有“远端有、本地没下载”的中间态。
6. **文件全量覆盖不适合外部目录**：数据目录可能被用户选到网盘/同步盘，整文件
   覆盖没有事务与锁，冲突时容易丢数据。

### 2.2 P1 保留的既有约定

- `uuid` 作为笔记身份、未知字段透传（[lib/models/note.dart](../../lib/models/note.dart) 的 `raw`）
  ——SQLite 下落到 `extras_json`。
- 写入串行化——SQLite 下由事务和 WAL 接管。
- 图片格式识别与 BMP→PNG 规范化（[lib/data/image_payload.dart](../../lib/data/image_payload.dart)）
  ——继续复用，落盘位置从 `images/` 变成内容寻址的 blob。
- 数据目录可切换、原目录保留的产品语义——继续保留，复制方式改为
  `VACUUM INTO` + blob 复制（见 §12）。

## 3. 存储引擎选择

**采用 SQLite**，Dart 侧用 `sqflite_common_ffi`（Windows 桌面走 FFI，
API 与手机端 `sqflite` 基本一致），不引入代码生成。

| 方案 | 结论 | 原因 |
|------|------|------|
| 继续 JSON + 旁路文件 | 否 | 标签筛选、音频中间态、增量同步都要自己实现一套；越往后越像在重写数据库 |
| SQLite（sqflite_common_ffi） | **采用** | 与手机端同源；事务、索引、部分更新、迁移机制成熟；依赖小 |
| Drift | 暂不 | 类型安全更好，但引入 codegen 与新的迁移体系；团队已有 sqflite 经验 |
| Hive / Isar | 否 | 查询与关系能力弱，跨端协议还要另做一层 |

运行参数：

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
PRAGMA synchronous = NORMAL;
```

注意 `foreign_keys` 是**连接级**开关，每次打开连接都要执行；只在建库脚本里写
一次不会对后续连接生效。

体积与依赖：`sqflite_common_ffi` 依赖 `sqlite3` 3.x 的 native assets，构建时会把
`sqlite3.dll` 放到 Release 目录（本机实测约 1.7 MB）。**不要**再引入
`sqlite3_flutter_libs`：它已 EOL，对 `sqlite3` 3.x 是空包。打包脚本复制整个
Release 目录即可带上 `sqlite3.dll`；若只挑文件，必须把它和
`native_assets.json` 一起带上。当前桌面端安装包约 12.5 MB，仍在“轻量客户端”
的可接受范围内。

约束：

- **数据目录必须是本地磁盘**。WAL 依赖可靠的文件锁与共享内存，放在 SMB /
  WebDAV / 部分网盘同步目录上会出现锁失效、`database is locked`、甚至库损坏。
  用户选到网络盘时，设置页应明确提示并建议换回本地目录（是否硬性阻止见 §15）。
- **单实例**。同一数据目录只允许一个进程写。建议用 Windows 命名互斥量或本地
  端口做单实例；第二实例只负责唤起第一实例。SQLite 本身能多进程，但应用层的
  “整库快照 + 覆盖”逻辑不适合并发。
- **单连接 + 写队列**。沿用现在 `NotesController` 的串行写纪律；事务里不做
  网络、图片解码等慢操作。

## 4. 数据目录布局

```
<数据目录>/
├── shengwuji.db              # SQLite 主库
├── shengwuji.db-wal          # WAL（随库存在，不要单独备份）
├── shengwuji.db-shm
├── blobs/                    # 内容寻址的附件本体，只增不改
│   └── <sha256 前两位>/<sha256>.<ext>
├── cache/                    # 缩略图、波形峰值等派生数据，可随时删除
├── backups/
│   ├── pre-migration-v<n>-<时间>.db
│   └── ...
└── legacy/                   # 迁移前的 notes.json / images/ 原样留档
```

`settings.json`（快捷键、数据目录指针）继续留在系统应用支持目录，理由与现在
一致：它属于应用本身，不属于笔记数据。WebDAV 密码等敏感信息**不得**写进数据
目录或数据库（见 [cloud-sync.md](cloud-sync.md) §9）。

## 5. 通用约定

| 项 | 约定 |
|----|------|
| 表名/列名 | snake_case；表名复数（`notes`、`tags`、`attachments`） |
| 主键 | `uuid TEXT`（UUID v4；后续可切 v7，已存数据不受影响） |
| 时间列 | 后缀 `_at`，`INTEGER` 毫秒 UTC；NULL 表示未知，不用 0 冒充 |
| 布尔列 | `INTEGER 0/1` + `CHECK`；不用文本 |
| 版本列 | `rev INTEGER`，本机每次写 +1；**只用于本机脏标记/诊断，不跨设备比较** |
| 未知字段 | `extras_json TEXT NOT NULL DEFAULT '{}'`，仅存协议里不认识的字段 |
| 文件路径 | 只存相对数据目录的 POSIX 路径；禁止绝对路径、盘符、`..` |
| 删除 | 硬删除行 + 写 `tombstones`；附件 blob 延迟回收 |
| 内容 | 笔记正文保持 Markdown 纯文本；不把结构化业务字段塞进正文 |
| 秘密 | 数据库、日志、导出物里不出现密码/token |

`rev` 的语义要特别注意：设备 A 的 `rev=7` 和设备 B 的 `rev=3` 没有可比性。
跨设备新旧只由 `updated_at` + `device_id` 裁决（见 [cloud-sync.md](cloud-sync.md) §7）。

## 6. 表结构

完整可执行 DDL 以 [schema-v1.sql](schema-v1.sql) 为准，这里说明设计意图。

```
notes 1 ────< attachments
notes >────< tags            (note_tags)
notes 1 ──── 1 tombstones    (entity='note')
items 1 ──── 1 tombstones    (entity='item')
tags  1 ──── 1 tombstones    (entity='tag')
app_meta：设备 id、迁移标记、数据版本号等单例键值
```

### 6.1 `notes`（笔记）

| 列 | 说明 |
|----|------|
| `uuid` | 跨端身份。手机端导入时直接使用其 `sync_uuid`，不重新生成 |
| `content` | Markdown 正文 |
| `mark` | 手机端 v17 的固定标注 `urgent/star/idea/task`。同步边界映射为手机端的 `tag` 字段 |
| `is_archived` | 归档 |
| `is_locked` | 界面打码标记；**不是加密** |
| `sort_order` | 活跃区自定义顺序；归档行恒 NULL。是否跨端采纳见同步规范 |
| `created_at` / `updated_at` | 创建/最后修改，毫秒 UTC |
| `rev` | 本机修订号，写操作 +1 |
| `extras_json` | 协议未知字段透传；不要放可搜索/可排序的核心字段 |

### 6.2 `tags` + `note_tags`（用户标签）

| 列 | 说明 |
|----|------|
| `tags.uuid` | 标签身份，重命名不变 |
| `tags.name` | 展示名，保留用户输入的大小写与空白 |
| `tags.name_key` | 归一化唯一键：trim → 合并连续空白（含全角空格）→ 小写 → NFC（若可用） |
| `tags.color` | 可选 ARGB 整数；为空时 UI 按名称稳定取色 |
| `note_tags` | 多对多关系；`(note_uuid, tag_uuid)` 主键 |

为什么不用手机端的 `tag` 列做标签体系：手机端 `tag` 是单选、固定枚举，
用于整卡换色和筛选（`DiaryTag`）。把“旅行/工作/读书”塞进去会破坏手机端
现有筛选，也无法表达多标签。两者在 UI 上可以并排展示，但数据模型必须分开。

### 6.3 `attachments`（图片/音频附件）

| 列 | 说明 |
|----|------|
| `uuid` | 附件身份；同一内容挂到两条笔记时是两个附件行、共享一个 blob |
| `note_uuid` | 所属笔记；删除笔记级联删行 |
| `kind` | `image` / `audio` / `file` |
| `origin` | `paste` / `screenshot` / `record` / `import` / `download`，用于 UI 与清理策略 |
| `sha256` | 内容哈希，小写十六进制；本地文件必填 |
| `storage_path` | 相对路径，如 `blobs/ab/abcdef...png`；为空表示远端有、本机未下载 |
| `sync_name` | 与手机端兼容的 basename（v1 音频用）；图片在 v1 不同步，通常为空 |
| `mime_type` / `byte_size` | 类型与字节数 |
| `duration_ms` | 音频时长；手机端存秒，边界换算 |
| `width` / `height` | 图片/视频尺寸，可选 |
| `sort_order` | 笔记内顺序（正文插图、多段录音） |
| `updated_at` / `rev` | 预留给将来的附件独立同步；当前附件集合随笔记 LWW 裁决 |

“远端点、本地未下载”是合法状态，不要用空文件或假路径占位。UI 看到
`storage_path == null` 时显示“在云端，点击下载”，而不是报损坏。

### 6.4 `items`（物品）

桌面端目前没有物品 UI，但手机端同步里有 `items.json`。先把表建好，避免以后
为了同步物品再加一次迁移。手机端 v17 的物品没有时间戳，导入行允许
`created_at/updated_at` 为 NULL；本机新建必须写时间。

### 6.5 `tombstones`（墓碑）

| 列 | 说明 |
|----|------|
| `entity` | `note` / `item` / `tag` |
| `uuid` | 被删对象身份 |
| `deleted_at` | 删除时间，毫秒 UTC |
| `rev` | 删除时的本机修订号 |
| `origin` | 哪台设备删的（设备 id） |

任何删除路径都必须在同一事务里写墓碑。附件不单独记墓碑：附件的增删属于笔记
状态，随笔记的 `updated_at` 一起同步；笔记删除时附件行级联删除，blob 由 GC
回收。

### 6.6 `app_meta`（单例键值）

建议的键：

| key | 值 |
|-----|----|
| `device_id` | 本机稳定设备 id（UUID），首次启动生成，同步锁/冲突裁决用 |
| `schema_created_at` | 建库时间 |
| `legacy_migrated_at` | `notes.json` 迁移完成时间 |
| `legacy_migration_stats` | 迁移统计 JSON（导入条数、跳过坏行、缺失图片） |
| `data_revision` | 本地数据版本计数，每次用户侧写库 +1 |
| `last_synced_revision` | 上次同步成功时的 `data_revision` 快照 |
| `last_sync_at` | 上次同步成功时间 |
| `last_blob_gc_at` | 上次 blob 回收时间 |

## 7. 不变量

这些是 code review 和测试的检查点：

1. **身份**：任何新笔记/物品/标签都必须有 uuid；导入手机端数据时 uuid =
   `sync_uuid`，禁止重新生成。
2. **时间**：写入 `created_at/updated_at` 一律毫秒 UTC；只在同步边界转字符串。
3. **修订**：任何改变笔记内容、标注、归档、锁定、排序、标签集合的写操作，
   同一事务内 `updated_at = now`、`rev = rev + 1`。
4. **删除**：任何删除必须硬删行 + 写墓碑；笔记删除级联删附件与标签关系。
5. **附件**：blob 写入后不可变；文件路径只由 sha256 + 扩展名派生；数据库不存
   绝对路径。
6. **标签**：`name_key` 唯一；重命名保留 uuid；同名标签不能出现两条。
7. **未知字段**：`extras_json` 只能保存协议未知字段，不能与核心列重复；解析失败
   的 extras 按 `{}` 处理并记日志，不能阻断整行。
8. **锁**：所有多表写操作在一个事务内完成；事务内不做网络/解码。
9. **秘密**：密码、token 不进数据库、数据目录、日志。
10. **兼容**：手机端 v1 投影只能包含手机端认识的字段；桌面专属字段只写 v2
    命名空间（见 [cloud-sync.md](cloud-sync.md)）。

## 8. 附件与 blob 生命周期

### 8.1 内容寻址

保存附件时：

1. 读取字节，校验大小上限（图片沿用 20 MB；音频上限单独配置，建议 256 MB；
   文件 64 MB）。
2. 识别类型：图片继续用现有格式嗅探（PNG/JPEG/GIF/WebP/BMP），BMP 转 PNG；
   音频至少接受 WAV（手机端录音格式），后续接 MP3/M4A 时只加白名单。
3. 计算 sha256（`crypto` 包）。
4. 目标路径 `blobs/<sha 前两位>/<sha>.<ext>`；已存在则直接复用，不重写。
5. 先写临时文件、`flush`，再 `rename` 到目标路径（同目录内原子）。
6. 最后在同一事务里插入/更新 `attachments` 行。

同一张图片粘贴到两条笔记、或同一条笔记重复粘贴，只占一份磁盘空间。

### 8.2 删除与 GC

- 从笔记移除附件时，删附件行；P1 是纯本地模式，**引用计数归零后立即删 blob**，
  以保持“移除图片就释放磁盘”的既有行为。同一 blob 仍被其他附件行引用时保留。
- 笔记移入回收站时保留附件；永久删除笔记时才级联删附件行，控制器随后按文件名
  调用 `deleteImage`，同样只在引用归零时删 blob。
- 附件 GC 尚未实现，目前仍是引用归零立即删除。接入上传队列后计划改为延迟回收
  （文件可能仍在待上传队列里）：
  1. 列出 `blobs/` 下所有文件；
  2. 统计 `attachments.sha256` 的引用；
  3. 无引用且文件 mtime 早于保留期（建议 30 天）才删除；
  4. 记录 `last_blob_gc_at`。
- 远端附件默认**不自动删除**。手机端 P1 的删除不跨端；桌面端主动删云端附件
  会让其他设备丢素材。等 v2 墓碑完整后再讨论远端回收。

### 8.3 安全

- 远端文件名不得直接拼路径；只接受 basename，拒绝空串、`..`、路径分隔符、
  控制字符。blob 路径由 sha256 派生，不信任远端给的路径。
- 下载先写临时文件，校验 sha256 与大小，通过后再 rename 并入库；不通过丢弃。
- 图片只接受光栅格式（PNG/JPEG/GIF/WebP/BMP），不接 SVG（可能带脚本）。
- 音频时长/元数据只用于展示，不据此执行任何路径或命令。

### 8.4 派生数据

缩略图、音频波形峰值、图片 EXIF 等派生数据放 `cache/`，不进数据库、不进同步；
删除 cache 只影响首次加载速度。若需要持久化索引，加本地表并标注“仅本机”，
不要写进 `extras_json` 后同步出去。

## 9. 标签体系

### 9.1 两种“标签”不要混

| 概念 | 存储 | 语义 | 是否进手机端 v1 |
|------|------|------|----------------|
| 标注 `mark` | `notes.mark` | 固定枚举：紧急/收藏/灵感/任务；整卡换色、快捷筛选 | 是，映射为手机端 `tag` |
| 用户标签 | `tags` + `note_tags` | 用户自建、多对多、可重命名/配色 | 否，进 v2 |

### 9.2 归一化

- 输入先 trim，去掉开头的 `#`（UI 展示时再加）。
- 内部连续空白合并为一个半角空格；全角空格 `U+3000` 视作空白。
- `name_key = 归一化后的字符串.toLowerCase()`；若引入 Unicode 归一化包，再做 NFC。
- 展示名保留用户输入的大小写；比较与唯一性只看 `name_key`。
- 空名、纯空白、超过 32 个字符、含控制字符的标签拒绝。
- 重名直接复用已有标签，不新建。

SQLite 的 `COLLATE NOCASE` 只处理 ASCII，不能作为中文/Unicode 的唯一性依据；
所以唯一索引建在 Dart 侧算好的 `name_key` 上。

### 9.3 常用操作

- 给笔记加/删标签：`INSERT OR IGNORE` / `DELETE` + 笔记 `updated_at/rev`。
- 按标签筛选：`note_tags` 上按 `tag_uuid` 查 `note_uuid`，再关联 `notes`；
  多标签 AND 用交集，OR 用 `IN`。
- 标签计数：`GROUP BY tag_uuid`；侧栏显示数量时加索引即可，不必缓存。
- 删除标签：删 `note_tags` 关系 + `tags` 行 + 墓碑；笔记的 `updated_at` 不必
  强行 bump，合并时用标签墓碑过滤笔记里的标签引用（见同步规范）。

### 9.4 扩展点

- 层级标签：以后加 `parent_uuid` 列和“同父级下 name_key 唯一”的索引；当前
  扁平模型不阻碍这次迁移。
- 标签别名/合并：加 `tag_aliases` 表；不要改现有 `tags` 主键。
- 智能标签（自动分类）：结果写入普通 `note_tags`，来源记在 `extras_json` 或
  单独表，避免把“用户标签”和“算法标签”混在一起。

## 10. 迁移

### 10.1 `notes.json` → SQLite（一次性）

触发条件：数据目录存在 `notes.json` 且不存在 `shengwuji.db`。
`app_meta.legacy_migrated_at` 只用于记录与排障；迁移成功后 `notes.json` 已移入
`legacy/`，不会重复触发。

流程：

1. 在数据目录创建临时库 `shengwuji.db.migrating`。
2. 执行 `schema-v1.sql`，设置 `user_version=1`。
3. 逐条解析 `notes.json`：
   - 顶层不是数组 → 中止迁移，保留原文件，进入兼容模式（§10.3）。
   - 单条坏行 → 跳过并计数，不阻断整体。
4. 字段映射：

   | notes.json | SQLite |
   |------------|--------|
   | `uuid` | `notes.uuid`（缺失/空 → 跳过该行并计数） |
   | `content` | `notes.content` |
   | `tag` | `notes.mark` |
   | `archived` | `notes.is_archived`（`1`/`true` 都认） |
   | `created_at` | `notes.created_at`；解析失败依次回退 `updated_at` → 文件 mtime → now |
   | `updated_at` | `notes.updated_at`；缺失则 = `created_at` |
   | `images[]` | 每个文件名建一条 `attachments(kind='image', origin='import')` |
   | 其他未知字段 | `extras_json` |

5. 图片处理：按文件名在 `images/` 找文件；计算 sha256；复制（不是移动）到
   `blobs/`；同一文件被多条笔记引用时共享 blob；文件缺失则跳过该附件并计数。
6. `PRAGMA integrity_check` 通过后，关闭临时库，`rename` 为 `shengwuji.db`。
7. 在 `app_meta` 写入 `legacy_migrated_at` 与统计。
8. 把原 `notes.json`、`images/` 移入 `legacy/<时间>/`（保留，不删）。

注意：

- **迁移时不要给导入行写 `updated_at = now`**。手机端导入的行没有更新语义，
  写成 now 会让它在之后的 LWW 里无端压过其他设备；正确值是 `created_at`。
- `created_at` 若是手机端格式（本地时间、无 `Z`），`DateTime.parse` 按本地时区
  解析后 `.toUtc().millisecondsSinceEpoch`；具体边界规则见同步规范 §6。
- 图片按内容去重后，删除一条笔记不能再直接删文件；必须走 blob 引用计数/GC。

### 10.2 Schema 版本管理

- 版本号用 `PRAGMA user_version`；桌面端从 **1** 开始，与手机端的 17 无关。
- 只做前进迁移，不修改历史迁移；每个版本一个事务。
- **迁移事务只做 DDL**，不跑逐行回填。回填在打开成功后单独执行，幂等，用
  `app_meta` 标记进度（手机端 v14 的 `database_closed` 事故就是回填拉长升级
  事务导致的）。
- 迁移前用 `VACUUM INTO` 生成一致快照：
  `VACUUM INTO 'backups/pre-migration-v<old>-<ts>.db'`；不要直接复制正在写的
  db + wal 文件。
- 打开时若 `user_version` 大于当前应用支持的版本（用户降级），拒绝打开并提示
  升级应用，不要尝试写库。
- 每次新增版本都要有“从上一版 fixture 升级”的测试，而不只测全新建库。

### 10.3 迁移失败与兼容模式

- 迁移失败：删除临时库，原 `notes.json` 不动；应用进入**兼容模式**，继续用
  旧 `NoteStore` 读写，并在界面提示“数据库升级未完成，数据已保留，下次启动重试”。
- 兼容模式下禁用标签、音频、同步等依赖新表的功能，避免半套数据。
- 迁移成功后才删除兼容模式代码（至少保留一个大版本）。

## 11. 查询与索引

典型查询（都要走索引或有明确上限）：

```sql
-- 活跃笔记，按创建时间倒序
SELECT * FROM notes
WHERE is_archived = 0
ORDER BY created_at DESC, uuid DESC;

-- 活跃区自定义排序（与手机端语义一致：NULL 行排尾部按时间兜底）
SELECT * FROM notes
WHERE is_archived = 0
ORDER BY (sort_order IS NULL), sort_order, created_at DESC;

-- 单标签筛选
SELECT n.* FROM notes n
JOIN note_tags nt ON nt.note_uuid = n.uuid
WHERE nt.tag_uuid = ? AND n.is_archived = 0
ORDER BY n.created_at DESC;

-- 多标签 AND
SELECT n.* FROM notes n
JOIN note_tags nt ON nt.note_uuid = n.uuid
WHERE nt.tag_uuid IN (?, ?)
GROUP BY n.uuid
HAVING COUNT(DISTINCT nt.tag_uuid) = 2;

-- 正文搜索（小数据量先用 LIKE/instr；中文全文见下）
SELECT * FROM notes
WHERE content LIKE '%' || ? || '%';
```

全文搜索不要现在做。笔记量大到 `LIKE` 明显变慢时，再加 FTS5 虚拟表
（中文用 `trigram` tokenizer）；这是纯增量迁移，不影响现有表。

## 12. 数据目录切换与备份

已实现（[lib/data/data_location.dart](../../lib/data/data_location.dart)、
[lib/data/note_database.dart](../../lib/data/note_database.dart) 的 `copyTo`）：

1. 切换前先 `flush` 当前编辑并等写队列清空，再 `PRAGMA wal_checkpoint(TRUNCATE)`。
2. 目标已有 `shengwuji.db`：界面先确认“切换到该目录现有数据”，不做静默合并，
   也不覆盖目标；目前未提供“用当前数据覆盖”的入口。
3. 目标为空：`VACUUM INTO` 生成 `.copying` 临时快照 → `PRAGMA integrity_check`
   校验 → 复制 `blobs/`（同路径且大小相同则跳过）→ 删除目标旧库、把临时库
   改名落位 → 写入 `settings.json` 指针并热切换连接；原目录保留。
4. 中途失败/崩溃：目标只会留下 `shengwuji.db.copying` 或孤立 blob，不会被当成
   有效数据；下次复制会清理临时库并重试。崩溃标记表留到后续阶段。
5. 选到网络盘：目前只提示风险，未硬性阻止（见 §15）。

备份分两种：

- **迁移回滚备份**：单个 `.db` 快照，放在 `backups/`。它不含 blob，只用于
  回滚 schema。
- **用户导出包**：`.db` + `blobs/` + 一份 `manifest.json`（版本、时间、文件
  哈希），打成 zip；恢复时先校验完整性，再替换。不要只导出数据库。

## 13. 测试清单

P1 已覆盖（`test/note_store_test.dart`、`test/migration_test.dart`、
`test/data_location_test.dart`、`test/notes_controller_test.dart`）：

- 全新建库：七张表齐全、`user_version=1`。
- 迁移：空 `notes.json`、正常数据、坏行、缺失 uuid、缺失图片、未知字段、
  多条笔记共享同一张图片、损坏 JSON 回退兼容模式。
- 时间：本地时间字符串 → UTC 毫秒 round-trip。
- 不变量：删除写墓碑；删笔记级联删附件行；同 uuid 重建清墓碑；
  内容不变不 bump `rev`，变化才 +1。
- 附件：sha256 寻址、同内容去重、引用归零后删文件、BMP→PNG、路径穿越拒绝。
- 数据目录切换：`VACUUM INTO` 快照可打开、blob 复制完整、设置文件不复制。

P2/P3 仍需补：标签归一化与多标签查询、录音录制/导入、超限拒绝的界面提示、
附件 GC 保留期、崩溃标记回退。

## 14. 分期落地

| 阶段 | 内容 | 完成标准 |
|------|------|----------|
| P1 ✅ | SQLite 接入 + `notes.json` 迁移 + 笔记/附件读写 | 现有功能不回归；迁移测试全过；旧 `notes.json` 留档 |
| P2 部分 ✅ | 音频附件（已做下载/播放）；标签体系、录制/导入、附件 GC 待做 | 已能从手机端下载并在卡片/编辑页播放；其余待补 |
| P3 阶段 A ✅ | WebDAV 同步 v1 兼容 + v2 命名空间 | 与手机端 v17 新增并集；图片/录音随笔记同步；桌面标签不被手机端同步抹掉 |
| P4 部分 ✅ | 回收站已用 `is_archived` 标记落地；全文搜索、层级标签待做 | 删除可恢复、可永久清理；其余按需增量迁移 |

P1 只替换存储层，不改界面文案与交互；出问题时旧版本仍能读取 `legacy/`
留档，但新版本写过的数据不会自动回写 JSON。回收站没有新增 `deleted_at` 列，
而是复用手机端已有的 `archived` 语义：进入回收站只改标记，永久删除才写墓碑。

## 15. 开放问题

1. 数据目录选到网络盘：硬性阻止，还是允许并持续警告？
2. 回收站目前复用 `is_archived`，未新增 `deleted_at`。若以后要区分“归档”与
   “删除”或做自动清理，需要再评估是否增加独立的软删除列。
3. 桌面端录音格式：直接用 WAV 与手机端一致（体积大），还是录 M4A/Opus 后在
   同步时转码？当前桌面端只下载/播放，不产生新录音。
4. 图片目前默认随笔记同步（关闭 WebDAV 同步即停止上传）。是否要给图片单独
   开关，仍待产品确认。
5. 标签是否需要层级；若需要，应在 v2 协议冻结前确认，避免之后改唯一索引。
6. 锁定笔记是否要做真正的加密（E2EE）？当前 `is_locked` 只是界面打码，
   云端仍是明文，需要向用户说清楚。

## Changelog

- 2026-10-24：接入同步所需快照/墓碑读写与录音附件（下载/播放）；删除改为
  `is_archived` 回收站（可恢复/永久删除/清空），数据目录切换按 §12 落地；
  补同步、回收站、录音与快照相关测试。
- 2026-10-23：P1 落地。`NoteStore` 改为门面，默认走
  [NoteDatabase](../../lib/data/note_database.dart)；`notes.json` 首次打开时
  迁入 SQLite 并留档到 `legacy/`，迁移失败回退 JSON 兼容模式；附件改为
  sha256 内容寻址 + 引用归零删除；数据目录切换改为 `VACUUM INTO` + blob 复制。
  新增 `test/note_store_test.dart`、`test/migration_test.dart` 等覆盖。
- 2026-10-23：首版。确定桌面端改用 SQLite；定义 uuid/UTC 毫秒/rev/墓碑约定、
  `notes/tags/note_tags/attachments/items/tombstones/app_meta` 七张表、
  内容寻址附件、标签与固定标注分离、迁移与数据目录切换规则。
