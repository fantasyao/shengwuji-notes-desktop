# 与手机端的 WebDAV 同步契约

> 状态：阶段 A 已实现（2026-10-23）。桌面端读取 v1 新增、以 v2 为权威、写回
> v1 投影；图片经 `v2/assets` 跟随笔记同步；录音可从 `audio/` 下载并在电脑上
> 播放（默认关，见 §4.5）。手机截图与桌面图片经根目录 `image_index.json`
> 双向同步（§4.8）：手机截图挂到桌面笔记，桌面图片下收到手机可多图查看。
> 物品与标签同步尚未接入，见 §14「实现现状与边界」。
> 本文同时保留完整目标设计，后续阶段按此推进。
>
> 关联：[桌面端数据库架构](database.md) ·
> 手机端参考：`my_first_app/docs/architecture/cloud-sync.md`、
> `my_first_app/lib/sync/sync_models.dart`。

## 1. 设计原则

1. **本地存储与同步协议解耦**。桌面端 SQLite 的列名、毫秒时间戳、`rev` 只在
   本地使用；上线前转换成协议字段。
2. **只做加法，不赌旧客户端会保留未知字段**。手机端 v17 的解码器只读取它认识
   的字段，回传时从数据库行重新编码。桌面专属字段写进 `diary.json` 会在手机端
   下一次同步时被丢掉。
3. **命名空间隔离**。桌面端把完整数据写在新的 `v2/` 目录；旧手机端不读它，
   也就不会破坏它。v1 文件只作为手机端可读的“投影”。
4. **身份用 uuid**。桌面端导入手机端笔记时 `uuid = sync_uuid`，不重新生成。
5. **删除靠墓碑**。任何删除都记 `tombstones`；只有墓碑能阻止远端把数据拉回。
6. **版本先协商，再写入**。远端协议版本高于本机支持范围时，只读或中止，绝不
   覆盖。
7. **隐私默认保守**。图片随笔记同步（关闭整个同步即可停止上传）；录音下载默认关；
   锁定笔记在云端仍是明文，不能宣称端到端加密。

## 2. 手机端 v17 的既成事实

这些是设计前提，不要在桌面端单方面改变：

| 项 | 现状 |
|----|------|
| 云端布局 | `manifest.json`、`diary.json`、`items.json`、`hotwords.txt`、`correction_pairs.json`、`audio_index.json`、`audio/` |
| 合并语义 | P1 只做“新增条目”并集；编辑、删除不跨端 |
| 删除 | 本机硬删除 + `sync_deleted` 墓碑，墓碑不上传；墓碑只防本机复活 |
| 标注 | `diary.tag` 固定枚举（urgent/star/idea/task），随日记行上传 |
| 锁定 | `is_locked` 只随“新插入行”传播，已有行不传播 |
| 排序 | `sort_order` 随 `diary.json` 上传，但只在“对端活跃区为空”时被采纳 |
| 图片 | `image_path` 是本机绝对路径，**v1 文件不写**；2026-10-24 起根目录 `image_index.json` + `v2/assets/` 双向桥接：手机截图挂到桌面笔记（`origin='mobile'`），桌面图片以 `source='desktop'` 发布、手机下收多图（§4.8）。仍不进备份 |
| 音频 | 开关默认关；文件名（basename）写在 `diary.audio`，本体在 `audio/`，索引在 `audio_index.json` |
| 时间 | `created_at` 是 `DateTime.now().toIso8601String()`：**本地时间、无 `Z`/偏移**；展示时没有 `toLocal()` |
| 少文件整包 | 刻意避免“每条一个文件”，防坚果云 600 请求/30 分钟限流 |

### 2.1 关键兼容性事实：未知字段会被丢掉

手机端 `DiarySyncEntry` 的编码只输出固定字段：

```dart
// my_first_app/lib/sync/sync_models.dart
Map<String, dynamic> toJson() => {
  'uuid': uuid,
  'content': content,
  'created_at': createdAt,
  if (audioName != null) 'audio': audioName,
  if (duration != null) 'duration': duration,
  if (isArchived) 'archived': 1,
  if (isLocked) 'locked': 1,
  if (tag != null) 'tag': tag,
  if (sortOrder != null) 'sort_order': sortOrder,
};
```

回传时它还会 `DiarySyncEntry.fromRow(DB 行)` 重新构造载荷。结论：

- 桌面端在 `diary.json` 里加的 `updated_at`、`tags`、`attachments`、`images`
  等字段，手机端同步一次就没了。
- `manifest.json` 同理：`SyncManifest.toJson()` 只输出 `v/device_id/updated_at/
  lock/counts`，桌面端写进去的 `writers`、`protocol_version` 也会被手机端覆盖。
- 因此：**桌面专属状态必须放在手机端不读的文件里**（`v2/`），不能依赖
  “宽容解码会保留未知字段”。

### 2.2 时间格式的坑

手机端展示时间时直接 `DateFormat(...).format(DateTime.parse(created_at))`。
如果桌面端写入带 `Z` 的 UTC 字符串，手机会把 UTC 当本地时间显示，中国时区会
差 8 小时。所以：

- **v1 投影**：写本地时间、无 `Z` 的 ISO 字符串，与手机端现有格式逐字一致。
- **v2 协议**：写 UTC、带 `Z` 的 RFC3339；手机端 v2 必须 `toLocal()` 后再展示。
- **本地数据库**：毫秒 UTC；边界转换统一放在 `sync/codec` 层，界面不碰字符串。

跨时区时 v1 无法同时做到“显示正确”和“瞬时可比”：手机端会把字符串当自己的
本地时间展示。这是手机端 v17 的现状，不在桌面端单方面修补；v2 用 UTC 显式
解决。

## 3. 目标目录布局

### 3.1 阶段 A：桌面端先兼容 v17（推荐先做）

```
<WebDAV 根>/
├── manifest.json            # v1 软锁 + 计数，手机端格式
├── diary.json              # v1 投影：只含手机端认识的字段
├── items.json              # v1 投影
├── hotwords.txt            # 桌面端只读透传，不改
├── correction_pairs.json   # 桌面端只读透传，不改
├── audio_index.json        # 音频上传索引；桌面端只做并集合并
├── audio/                  # 音频本体（手机端 v17 布局）
├── image_index.json        # 图片旁路索引（2026-10-24；两端读写，§4.8）
└── v2/                     # 桌面端新增，旧手机端忽略
    ├── manifest.json       # v2 协议版本、写入者、计数
    ├── notes.json          # 笔记全量快照（含标签、附件、时间戳）
    ├── items.json          # 物品全量快照
    ├── tags.json           # 标签定义
    ├── tombstones.json     # 删除墓碑
    └── assets/
        └── <sha 前两位>/<sha256>.<ext>
```

`v2/assets/` 由桌面端图片与手机截图共用：同一 sha256 内容寻址，两端各自写
自己的字节，互不覆盖。`image_index.json` 是双方共写的旁路索引——每条按
`(note_uuid, device_id, sha256)` 归属，各自只替换自己的条目；旧客户端不认它，
也不会删它。

要点：

- `v2/` 是**完整数据**，v1 文件是**给旧手机端看的投影**。桌面端以 v2 为准。
- 手机端 v17 只读写它认识的路径，不会遍历删除未知目录；这一点要在阶段 A
  验收时用真机确认（见 §12）。
- 不采用“每条笔记一个文件”，保持少文件整包，避免网盘限流。

### 3.2 阶段 B：手机端升级到 v2 后

- v2 成为所有新客户端的权威格式；
- 新客户端仍写 v1 投影，保证未升级的旧客户端还能看到笔记；
- `v2/manifest.json` 的 `writers` 记录各设备的协议版本与最后出现时间；
- 所有活跃设备都达到 v2 且稳定一段时间（建议 30 天）后，v1 文件冻结为只读，
  不再作为合并输入；是否删除由用户决定，不自动清理。

## 4. 阶段 A：v1 兼容 + v2 旁路

### 4.1 同步流程

```
1. 读 v1 manifest.json，检查软锁
2. 他机持锁且未超时（10 分钟）→ 中止
   否则写 v1 manifest 置锁（手机端格式，时间用本地无 Z 字符串）
3. 读 v1 diary.json / items.json（404 视为空）
4. 读 v2 manifest.json / notes.json / items.json / tags.json / tombstones.json
   （404 视为首次）；顺带读根目录 image_index.json（图片旁路索引，§4.8）
5. 版本检查：v2 protocol_version / min_reader_version 高于本机支持 → 中止
6. 合并（§7）：
   a. 先加载本地与远端墓碑集合、远端标签定义
   b. v1 新增笔记/物品 → 入本地（P1 只做新增；命中墓碑先跳过）
   c. v2 笔记/物品/标签/墓碑 → 按 LWW + 墓碑合并
   d. 冲突副本处理
   e. 图片索引 → 给对应笔记挂 origin='mobile' 的图片附件（跳过本机与
      source='desktop' 条目，§4.8）
7. 按需下载音频/资源（开关开启，分批）
8. 本地 SQLite 单事务落库
9. 生成并上传 v2 快照：`tags.json` → `notes.json` → `items.json` →
   `tombstones.json`（先有标签定义，笔记就不会引用不存在的标签）
10. 生成并上传 v1 投影（diary/items）
11. 合并 audio_index.json，上传音频/资源
12. 发布 image_index.json（桌面自有图片以 source='desktop' 登记；须在图片
    资产上传之后，见 §4.8）
13. 更新 v1 manifest 计数、释放锁
14. 记录 last_synced_revision / last_sync_at
```

顺序上 **v2 先于 v1**：v2 是桌面端的权威数据，v1 只是投影；中途失败时宁可
旧手机端晚一次看到，也不要 v2 丢标签/附件。资源放在最后：允许笔记先引用
“尚未传完的附件”，手机端/另一端下次同步续传即可，不要为了资源拖住文本。

### 4.2 v1 投影规则（写 `diary.json`）

只写手机端认识的字段，布尔值必须是 `1` 或省略（手机端判断 `== 1`，写 JSON
`true` 它不认）：

| v1 字段 | 来源 | 注意 |
|---------|------|------|
| `uuid` | `notes.uuid` | 非空 |
| `content` | `notes.content` | 原样 |
| `created_at` | `notes.created_at` | 本地时间、无 `Z`、ISO 字符串 |
| `archived` | `notes.is_archived` | `1` 或省略 |
| `locked` | `notes.is_locked` | `1` 或省略 |
| `tag` | `notes.mark` | 字符串或省略；**不要写用户标签** |
| `sort_order` | `notes.sort_order` | 整数或省略；归档行省略 |
| `audio` | 第一条 `kind='audio'` 附件的 `sync_name` | 只写 basename；多条音频只投影第一条并记警告 |
| `duration` | 同一附件的 `duration_ms` | 秒（四舍五入） |

不要写：`updated_at`、`tags`、`attachments`、`images`、`image_path`、自定义
字段。写了也会被手机端丢掉，只会造成“桌面端以为同步了”的错觉。

### 4.3 从 v1 读取（合并手机端新增）

- `diary.json` 的每一行：uuid 命中本地墓碑 → 跳过（防复活）；
  uuid 已存在 → **P1 不覆盖**（手机端 P1 不传播编辑），只记录分歧日志；
  uuid 不存在且自然键（content + created_at 毫秒）也不存在 → 新建。
- 新建时：
  - `created_at`：按手机端本地时间字符串解析成毫秒 UTC；
  - `updated_at = created_at`（不要写 now，否则导入行会无端赢得 LWW）；
  - `mark = tag`；
  - `is_archived/is_locked` 按 `== 1`；
  - `sort_order`：本地活跃区为空才采纳远端值，否则按“新行置顶”规则重排
    （与手机端 `insertRemoteDiaries` 的决策一致）；
  - `audio`：建一条 `attachments(kind='audio', sync_name=<basename>, origin='download')`；
    未下载时 `storage_path/sha256/byte_size` 为空（合法中间态）。开关关闭时不
    下载本体，只保留“云端有音频”的引用。
- `items.json`：uuid 不存在且 `(name, location)` 自然键不存在 → 插入；
  时间留空。

### 4.4 删除在阶段 A 的边界

- 桌面端删除笔记：本地硬删 + 墓碑；v2 快照里不再出现，`tombstones.json` 记下。
- 旧手机端不知道墓碑，下次同步会把该 uuid 重新写进 `diary.json`；桌面端靠
  墓碑跳过，**本机保持删除**，但手机端仍会显示这条笔记。这是手机端 P1
  “删除不跨端”的既有边界，不要用删除云端文件的办法绕过（会误删其他设备数据）。
- 手机端删除的笔记同样不会通知桌面端；桌面端下次仍会把它写进 v1 投影。等双方
  都升级 v2 后靠墓碑收敛。

### 4.5 音频桥接

- 手机端录音是 `diary_yyyyMMdd_HHmmss.wav`，放 `audio/`，`audio_index.json`
  记录已上传文件名。
- 桌面端只下载与播放，不产生新录音，因此**没有上传路径**（§4.5 原上传设计保留
  在下方，供将来桌面端支持录音时使用）：
  1. 文件名沿用同前缀，加短随机后缀避免撞车，例如
     `diary_20261023_120000_d1f3.wav`；
  2. 上传前检查远端同名文件：同名且哈希相同 → 直接复用；同名但哈希不同 →
     追加后缀改名后再传，禁止覆盖；
  3. `PUT audio/<name>`；
  4. 读 `audio_index.json`，并集加入新名字后写回；**只增不减**；
  5. 在本地写 `attachments.sync_name`，并填 sha256/storage_path。
- 桌面端下载音频（实现）：
  - 只在设置里开启「同步录音」后执行；关闭时仍保留“这条笔记有录音”的附件引用
    （`sync_name` + `duration_ms`），卡片显示「待下载」，编辑页提示开启方式。
  - 以 `audio_index.json` 为准：索引里还没出现的文件名先跳过，避免手机端刚录完、
    上传未完成时每轮同步都报 404；索引缺失或不是数组时退回直接尝试下载。
  - 按 basename 下载 `audio/<name>`，单条上限 100 MB，校验 sha256 后写入
    `blobs/<前两位>/<sha>.<ext>`，回填附件行的 `storage_path` / `sha256` /
    `byte_size`，下次同步不再重复下载。
  - 下载失败只记入本次同步的提醒，不影响文本同步，下次续传。
- v1 的 `audio` / `duration` 解析时统一成 `kind='audio'` 附件（稳定 uuid +
  mime + `duration_ms`），写回 v1 时再从附件投影；音频附件按 `sync_name` 参与
  载荷哈希，下载后回填 sha256 不会被误判成远端改动。
- 合并时若同 uuid 的 v2 记录没有录音附件（旧桌面写出的 v2 只带图片），会把
  v1 投影里的 `audio` 补回最终版本，避免第二台电脑首次同步时丢录音。
- 编辑页用 `audioplayers` 播放本地 blob（播放/暂停、进度拖动、时长）；未下载时
  只显示占位说明。
- 桌面端删除笔记不删云端音频与索引（P1 删除不跨端）。

### 4.6 透传文件

`hotwords.txt`、`correction_pairs.json` 桌面端不解析、不合并、不覆盖。读取时
原样保留在远端；如果实现“整目录镜像”类逻辑，必须先排除这些文件，避免把手机端
的纠错学习数据清空。

### 4.7 定时自动同步与请求预算（2026-10-24）

手机上新增的笔记，桌面端以前只能等启动、本地改动或手动点击才会看到。现在增加
可配置的定时检查（关闭 / 5 / 10 / 15 / 30 分钟，默认 10 分钟），实现上刻意压低
WebDAV 请求数：

- **轻量探测**：定时器到点后对 `diary.json`、`image_index.json`、
  `v2/notes.json` 与 `v2/tombstones.json` 发 `PROPFIND Depth: 0`，把返回的
  ETag（没有则 Last-Modified）与 `sync_state.remote_etags` 里上次同步结束时
  记录的版本比较。manifest 不再参与探测：它的 `updated_at` / `writers.*.last_seen`
  每轮心跳都会变。
- **心跳不算变化**：手机端空同步仍会重写 `v2/notes.json` 的 `generated_at`，
  版本变化后只 GET 这一个文件（约 9 KB），去掉 `generated_at` / `device_id`
  后与 `sync_state.remote_notes_hash` 比较；相同就只更新版本，不完整同步。
- **完整同步兜底**：任一内容文件版本变化、文件缺失，或服务端不支持 PROPFIND
  （405/501）时，退回现有的完整同步；不支持 PROPFIND 的服务器等于维持旧行为。
- **完整同步结束后**：内容版本在释放软锁之前记录（notes 随写随记，其余三个
  内容文件最后统一探测，3 个请求），避免其他设备在释放后写入被误记为已确认。
- **无变化不重传**：写 `v2/notes.json` / `v2/tombstones.json` /
  `v2/manifest.json` 前，忽略 `generated_at`、`updated_at` 和所有写入者的
  `writers.*.last_seen` 后再比较载荷；内容没变就不 PUT。`diary.json`
  仍按文本严格比较。
- **备份时机**：只有真的要写内容文件时才把远端旧 JSON 复制到 `sync_backup/`；
  纯拉取、心跳轮次和只加锁/解锁的轮次都不留副本。

请求预算（坚果云免费账号限制 600 次 / 30 分钟，付费 1500 次）：

| 间隔 | 空闲时每 30 分钟 | 占免费额度 |
|------|------------------|------------|
| 5 分钟 | 6 轮 × 5 = 30 次 | 5% |
| 10 分钟 | 3 轮 × 5 = 15 次 | 2.5% |
| 15 分钟 | 2 轮 × 5 = 10 次 | 1.7% |
| 30 分钟 | 1 轮 × 5 = 5 次 | 0.8% |

本地编辑仍走 25 秒防抖的完整同步（约 12～13 个请求），不受轮询影响。空闲轮次
只有探测请求，不加锁、不写远端；手机端心跳不再触发桌面端完整同步。

#### 4.7.1 本机请求计数与展示（2026-10-25）

坚果云只在帮助中心说明额度（免费 600 次 / 30 分钟、付费 1500 次），没有查询剩余
额度的 API，响应里也不返回限流余量。桌面端因此自己记账：

- **统一计数点**：`WebDavClient._request`。MKCOL / PROPFIND / GET / PUT / DELETE、
  「测试连接」以及失败后的重试都算一次；请求发出前计数，失败请求偏保守地计入。
- **滚动窗口**：按分钟归档最近 30 分钟（最多 31 个桶），读取时清理过期桶，不
  需要判断当前落在哪个固定区间。分钟粒度最多多保留 59 秒，偏保守。
- **跨重启**：计数写入配置目录 `webdav_requests.json`（与 `settings.json` 同级），
  不跟笔记数据目录走，避免换盘或数据目录放进同步盘时把计数复制到其它电脑。
  写入延迟 2 秒合并，正常退出前显式 flush；启动时恢复，重启不会清零。
- **界面**：设置 → WebDAV 同步显示「最近 30 分钟：这台电脑发出 N 次请求（按免费
  版 600 次估算，还剩 M 次）」。达到 80% 时变红，提示降低自动检查频率或暂停同步，
  并给出最早一批请求还有多久滑出窗口。数字随请求实时刷新；主页云图标的悬停提示
  也会带一行本机计数。
- **限流报错**：429 的提示附带本机最近 30 分钟计数，便于区分额度耗尽与网络问题。
- **边界**：只统计这台电脑；手机端、其它电脑和坚果云客户端发出的请求不计入，
  实际剩余可能更少。上限按免费版 600 估算，付费版 1500 需用户自行对照。触发
  限流后服务端可能封锁数小时，不保证 30 分钟后立即恢复。

### 4.8 图片桥接（双向，2026-10-24）

手机端截图仍是本机文件（`diary.image_path`），桌面端图片仍是
`attachments(kind='image')`；自 2026-10-24 起两端额外维护一份**旁路索引**
`image_index.json`，让图片跨端落地：手机截图挂到桌面笔记，桌面图片下收到
手机（可多张、按顺序左右切换）；都不改 v1 `diary.json`（手机端回写会丢未知
字段），也不进备份。

**索引格式**（根目录 `image_index.json`，两端共写）：

```json
[
  {
    "note_uuid": "5b0c...",
    "device_id": "mobile-1a2b",
    "sha256": "ab12...（64 位小写十六进制）",
    "name": "diary_sync_5b0c..._ab12....jpg",
    "mime": "image/jpeg",
    "size": 123456,
    "updated_at": "2026-10-24T04:12:33.123Z",
    "position": 0,
    "source": "desktop"
  }
]
```

`updated_at` 是 ISO UTC 字符串（手机端取文件 mtime，桌面端取笔记
`updated_at`）；`position` 决定同一笔记内展示顺序（桌面附件 `sort_order`
映射，缺省 0）；`source` = `desktop`（桌面发布）或 `mobile`/缺省（手机截图）。
唯一键是 `(note_uuid, device_id, sha256)`——同设备同一笔记可有多张图。

图片字节仍放 `v2/assets/<sha 前两位>/<name>`（与桌面图片共用目录）。每端每次
同步按所有权合并索引：只重写自己的条目，他机条目原样保留；手机端每次最多
上传 80 张，失败/超批/文件缺失的条目保留旧值下次续传。

**桌面端读索引（挂手机截图）**：

- 索引缺失或空数组 → 本轮不碰截图附件（老客户端零影响）；
- 坏 JSON / 不是数组 → 视为「索引不可用」并记提醒，**不能当成空索引**去清理
  已有手机截图附件；
- 坏行跳过并计数；`name` 只取 basename（拒绝 `..`、`/`、`\`）；
- **跳过 `source='desktop'` 与本机 `device_id` 条目**：桌面自有图片已经随
  v2 笔记附件到达，重复挂接会产生幽灵副本；
- 同一笔记可挂多张：不同 sha 全部保留，同 sha 多设备发布时取 `position`
  最小的一条（附件 uuid 由笔记 uuid + sha 推导，跨电脑稳定），按
  `position ASC, sha ASC` 排序并写入附件 `sort_order`；
- 为笔记挂 `attachments(kind='image', origin='mobile', sync_name=name,
  sha256, mime_type, byte_size)`，重复同步不产生新行；
- 已有同 sha 的手机附件保留本地 `storage_path`/`byte_size`（避免重复下载），
  只校正 `sync_name`/`sort_order`；远端删图时摘掉不再对得上的 `origin='mobile'`
  附件，非 mobile 附件（桌面粘贴/导入）不动；
- **不改笔记 `updated_at`**：截图是附加图片，不该因此赢 LWW 或被手机 v1 投影
  当成编辑传播；
- 字节走既有 `v2/assets` 下载链路（sha256 + 20 MB 上限 + 图片格式校验），落
  `blobs/`；未下载成功保持 `storage_path` 为空，下次续传；
- 已墓碑的笔记跳过挂载。

**桌面端写索引（发布自有图片）**：

- 只发布 `origin != 'mobile'`、已有 `storage_path` + `sha256` 的图片附件——
  从手机下载来的附件不能以电脑端身份再发布，否则来源换图后旧图复活；
- 每条笔记按附件 `sort_order`（再 uuid）编号成 `position`，`source='desktop'`，
  `updated_at` 用笔记时间（不取当前时间，避免每轮索引抖动导致重传）；
- 与远端索引合并时跳过「本机 device_id 且笔记仍在本地」的旧条目，由本轮
  附件列表整体重建（删图/换图/重排都能同步）；笔记已删则保留旧条目
  （P1 删除不跨端）；
- 回写前与旧 JSON 做规范化比较，内容没变就不写，避免无意义 PUT；
- 所有图片先随 v2 附件上传完成，再写索引（见 §4.1 第 9 步之后的发布段）。

失败隔离：索引解析失败或图片下载失败只进本轮提醒，不影响文本同步。

## 5. 阶段 B：v2 协议

### 5.1 `v2/manifest.json`

```json
{
  "format": "shengwuji.manifest",
  "protocol_version": 2,
  "min_reader_version": 2,
  "device_id": "desktop-7f3c...",
  "updated_at": "2026-10-23T04:12:33.123Z",
  "last_writer": "desktop-7f3c...",
  "writers": {
    "mobile-1a2b": { "protocol": 2, "last_seen": "2026-10-23T04:00:00.000Z" },
    "desktop-7f3c": { "protocol": 2, "last_seen": "2026-10-23T04:12:33.123Z" }
  },
  "counts": { "notes": 42, "tags": 9, "items": 7, "assets": 3 }
}
```

- `protocol_version` 是写入者使用的协议；`min_reader_version` 是读懂本目录
  所需的最低版本。读取方支持版本低于 `min_reader_version` → 中止。
- 时间统一 UTC、带 `Z`。
- 不在这里放锁：阶段 A/B 过渡期继续用 v1 `manifest.json` 的软锁作为唯一互斥量
  （所有客户端都认它）。等 v1 退役时再把锁迁到 v2。

### 5.2 `v2/notes.json`

```json
{
  "format": "shengwuji.notes",
  "version": 2,
  "generated_at": "2026-10-23T04:12:33.123Z",
  "device_id": "desktop-7f3c...",
  "notes": [
    {
      "uuid": "5b0c...",
      "content": "第一条\n第二条",
      "created_at": "2026-10-23T03:00:00.000Z",
      "updated_at": "2026-10-23T04:10:00.000Z",
      "rev": 4,
      "mark": "urgent",
      "archived": false,
      "locked": false,
      "sort_order": 2,
      "tags": ["tag-uuid-1", "tag-uuid-2"],
      "attachments": [
        {
          "uuid": "att-uuid-1",
          "kind": "audio",
          "origin": "record",
          "sha256": "ab12...",
          "name": "diary_20261023_120000_d1f3.wav",
          "mime": "audio/wav",
          "size": 123456,
          "duration_ms": 42000,
          "sort_order": 0,
          "rev": 1,
          "extras": {}
        }
      ],
      "extras": {}
    }
  ]
}
```

规则：

- `rev` 是本机修订号，仅诊断/增量预留；**跨设备不做新旧比较**。
- `tags` 是标签 uuid 数组；定义在 `tags.json`。集合属于笔记状态，随
  `updated_at` 一起 LWW。
- `attachments` 是完整集合；远端应用时以集合为准（缺失即删除），不再单独
  记附件墓碑。
- `extras` 保存本版本不认识的字段，合并时原样带回，避免新字段在旧桌面端
  同步一次就丢。
- 时间统一 UTC `Z`，手机端 v2 展示前必须 `toLocal()`。

### 5.3 `v2/tags.json`

```json
{
  "format": "shengwuji.tags",
  "version": 2,
  "generated_at": "2026-10-23T04:12:33.123Z",
  "tags": [
    {
      "uuid": "tag-uuid-1",
      "name": "旅行",
      "color": null,
      "created_at": "2026-10-20T02:00:00.000Z",
      "updated_at": "2026-10-20T02:00:00.000Z",
      "rev": 1,
      "extras": {}
    }
  ]
}
```

`name_key` 不入协议：它是本地归一化实现细节；合并时由各端按同一规则重算。

### 5.4 `v2/items.json` 与 `v2/tombstones.json`

物品：

```json
{
  "format": "shengwuji.items",
  "version": 2,
  "generated_at": "...",
  "items": [
    { "uuid": "...", "name": "护照", "location": "书房抽屉", "created_at": "...", "updated_at": "...", "rev": 1, "extras": {} }
  ]
}
```

墓碑：

```json
{
  "format": "shengwuji.tombstones",
  "version": 2,
  "generated_at": "...",
  "tombstones": [
    { "entity": "note", "uuid": "5b0c...", "deleted_at": "2026-10-23T04:05:00.000Z", "rev": 5 }
  ]
}
```

墓碑保留期建议 180 天，且不早于“最后一次成功同步 + 30 天”清理；跨端删除靠它
传播。附件不单独记墓碑。

### 5.5 `v2/assets/`

- 路径：`assets/<sha 前两位>/<sha256>.<ext>`；
- 内容不可变，按 sha 去重，上传前先查缺失；
- 附件对象里的 `name` 是展示名/手机端兼容 basename，`sha256` 是权威身份；
- 兼容桥：从 v1 音频导入但尚未下载本体的附件，允许 `sha256: null` 且带
  `"legacy": true` 与 `name`；v2 客户端从 v1 `audio/<name>` 取一次后回填哈希。
- 手机截图（§4.8）同样落在这里：根目录 `image_index.json` 只是索引，桌面端只
  读不写；同一 sha 的字节两端共享，文件名由手机端给出（`name`），路径前缀仍按
  sha 前两位。

## 6. 字段映射表

| 概念 | 桌面 SQLite | 手机 v17 列 | v1 JSON | v2 JSON |
|------|-------------|-------------|---------|---------|
| 笔记 | `notes` | `diary` | `diary[]` | `notes[]` |
| 身份 | `notes.uuid` | `sync_uuid` | `uuid` | `uuid` |
| 正文 | `content` | `content` | `content` | `content` |
| 创建时间 | `created_at` 毫秒 UTC | `created_at` 本地字符串 | 本地无 `Z` 字符串 | UTC `Z` |
| 更新时间 | `updated_at` 毫秒 UTC | 无 | 不写 | UTC `Z` |
| 固定标注 | `mark` | `tag` | `tag` | `mark` |
| 归档 | `is_archived` 0/1 | `is_archived` 0/1 | `archived` 0/1（省略=0） | bool |
| 锁定 | `is_locked` 0/1 | `is_locked` 0/1 | `locked` 0/1（省略=0） | bool |
| 排序 | `sort_order` | `sort_order` | `sort_order` | `sort_order` |
| 音频 | `attachments(kind='audio')` | `audio_path` + `duration` | `audio` basename + `duration` 秒 | `attachments` + `assets` |
| 图片 | `attachments(kind='image')` | `image_path`（本机） | 不写 | `attachments` + `assets`；手机截图另经 `image_index.json` 单向上行 |
| 用户标签 | `tags` + `note_tags` | 无 | 不写 | `tags` + `tags.json` |
| 删除 | `tombstones` | `sync_deleted`（不上传） | 不写 | `tombstones.json` |
| 未知字段 | `extras_json` | 无 | 不写 | `extras` |

## 7. 合并与冲突

### 7.1 身份与自然键

| 数据 | 主键 | 自然键（辅助去重） |
|------|------|-------------------|
| 笔记 | uuid | `content` + `created_at` 毫秒 |
| 物品 | uuid | `name` + `location` |
| 标签 | uuid | `name_key` |
| 附件 | uuid | `sha256` + `kind`（同一笔记内） |

自然键用于吸收“备份导入后重新生成 uuid”的历史数据。命中自然键但 uuid 不同时，
视为同一条，保留本地 uuid，不新建重复行。

### 7.2 新旧裁决

- 跨设备只比较 `updated_at`（毫秒 UTC），平局用 `device_id` 字典序，保证所有
  设备算出同一个赢家。
- **不要比较 `rev`**；它是每台设备自己的计数。
- v1 导入的行 `updated_at = created_at`，不会无端压过真实编辑。
- 时钟偏差处理：如果双方 `updated_at` 相差小于 5 分钟且正文不同，输家内容
  生成一条“冲突副本”：
  - 新 uuid；
  - 正文 = 输家正文；
  - 标签、附件元数据一并复制（附件本体按 sha 复用，不重复上传）；
  - `created_at` = 输家原创建时间，`updated_at` = now；
  - `extras.conflict_of = 原 uuid`；
  - 只在输家设备上生成一次（确定性裁决保证不会两台都生成），避免静默丢字。
- 时钟偏差很大且无法判断时，仍按上述规则裁决并保留冲突副本；不要直接覆盖。

### 7.3 删除

- 墓碑 `deleted_at >= 远端.updated_at` → 删除生效；
- 远端有更晚的显式编辑（`updated_at > deleted_at`）→ 视为“删除后重建”，
  允许复活；
- 手机端 v1 的行没有 `updated_at`，因此墓碑一律优先（防复活）。
- 标签墓碑优先于笔记里的标签引用：合并笔记时过滤掉已墓碑的标签 uuid。

### 7.4 标签合并

1. 先按 uuid 匹配；
2. 找不到时按 `name_key` 匹配（同名视为同一标签）；
3. 两个不同 uuid 同名：取 `uuid` 字典序较小者为规范 id（所有设备结果一致），
   把双方笔记里的引用改写到规范 id，并给落败 uuid 写墓碑；
4. uuid 相同但名字不同：按 `updated_at` LWW；重命名撞到已有 `name_key` 时，
   后到者追加 ` (2)`、` (3)`…，不要静默合并两个不同语义的标签；
5. 标签删除写墓碑；重建同名标签会得到新 uuid，旧墓碑不会误删新标签。

### 7.5 笔记内的标签集合

标签集合属于笔记状态，随笔记 `updated_at` LWW。合并顺序：先应用标签定义，
再应用笔记的 `tags` 数组，最后用标签墓碑过滤。不要为单条 `note_tags` 关系做
独立时间戳裁决。

### 7.6 排序键

`sort_order` 是**设备视图偏好**，不是内容：

- 不参与 LWW 让笔记“变新”；
- 本地活跃区为空（换机恢复）时采纳远端顺序；
- 本地已有顺序时，新导入行按“置顶”规则插入，不覆盖用户的手工排序；
- 两台设备各自重排后不互相覆盖，与手机端现有边界一致。

### 7.7 附件

- 附件集合随笔记整体裁决；
- 同 sha 的内容只存/传一份；
- 远端附件未下载时保留“pending”行（`storage_path` 为空），不要删引用；
- 资源缺失只影响该附件，不影响笔记文本同步。
- 手机截图（`origin='mobile'`）由 `image_index.json` 单独驱动：按
  `(note_uuid, device_id)` 归并后替换该笔记的 mobile 图片集合，**不参与
  LWW**、不改笔记 `updated_at`；桌面自己粘贴/导入的附件不受影响。

## 8. 资源同步

当前实现：图片随笔记默认同步（在 `v2/assets`）；录音默认只同步元数据，
设置里开启「同步录音」后从 `audio/` 下载到 `blobs/` 并可播放。

- **图片**：条目按 sha256 内容寻址到 `v2/assets/<前两位>/<sha>.<ext>`；上传前
  校验本地文件哈希与大小（单张上限 20 MB），远端已存在则跳过；下载后校验哈希
  与图片格式再写入 `blobs/`。桌面端自己粘贴的图片不进入 v1 投影，手机端 v17
  不读 `v2/assets/`，因此**桌面 → 手机方向仍不通**；反方向由手机端写
  `image_index.json` 桥接（§4.8），桌面端读索引后走同一条下载链路。
- **音频**：v1 `audio` / `duration` 归一化为 `kind='audio'` 附件；开启开关后按
  `audio_index.json` + `audio/<name>` 下载，写入 `blobs/` 并回填哈希与大小；
  关闭时只保留附件引用，卡片标注「待下载」。详见 §4.5。
- **失败隔离**：资源阶段失败只记入本次同步的提醒（手动同步时可点开查看），
  不把文本同步标成失败。
- **不自动删远端**：资源删除与笔记删除都不自动删云端文件；等墓碑机制完整后
  再设计回收。
- **请求预算**：每次同步约 10~15 个元数据请求 + 资源批量；不要改成“每条
  笔记/每个附件一个文件”的布局。

## 9. 锁与并发

- 过渡期唯一互斥量是 v1 `manifest.json` 的 `lock: {device_id, at}`：
  - 他机持锁且 `now - at <= 10 分钟` → 中止；
  - 超时视为死锁，自动放行；
  - 写锁/解锁都用手机端格式；`at` 用本地时间无 `Z` 字符串，和手机端
    `DateTime.tryParse` 的语义一致。
- WebDAV 没有可靠的原子 test-and-set；极端同时点击可能双写，后果是重复上传
  相同数据，不应产生结构损坏。软锁不保证强一致，文档和 UI 不要宣称“绝对不会
  并发”。
- 失败时在 `finally` 里尽力释放锁；没释放成功靠 10 分钟超时兜底。
- 所有写操作先拿锁，再读快照；不要在持锁期间做耗时解码/图片处理。

## 10. 安全与隐私

- WebDAV 密码放 Windows 凭据管理器（`win32` 的 `CredWriteW`）；地址、用户名可
  放 `settings.json`。**密码不得进 SQLite、数据目录、日志、崩溃报告**。
- 数据目录可能被用户放到网盘同步目录；凭据与数据库分离，避免整目录上传时泄露。
- `is_locked` 只是界面打码，云端内容是明文。设置页需要明确说明；真正的端到端
  加密是单独课题（见 §13）。
- 下载路径校验：只接受 basename，拒绝 `..`、`/`、`\`、控制字符；资产路径由
  sha256 派生，不信任远端 JSON 里的路径。
- 图片只接受光栅格式，拒绝 SVG；音频只接受白名单扩展名。
- 日志只记条数、uuid 前缀、错误类型；不记正文、密码、完整远端路径。

## 11. 版本与兼容矩阵

| 客户端 | 协议 | 行为 |
|--------|------|------|
| 手机 v17 | v1 | 读写 v1；忽略 `v2/`；重写时丢弃未知字段；2026-10-24 起另写 `image_index.json` + `v2/assets`（截图单向到桌面） |
| 桌面 P1 | v1 + v2 | 读 v1 新增；v2 为权威；写 v1 投影 |
| 手机 v2 | v2 | 读 v2；仍写 v1 投影给旧客户端 |
| 旧桌面（JSON） | 无 | 不参与同步 |

保护规则：

- v1 `manifest.json` 的 `v > 1` → 中止，提示升级；
- v2 `protocol_version` 或 `min_reader_version` 高于本机支持 → 中止，绝不写入；
- v2 目录不存在但 v1 有数据 → 从 v1 引导生成 v2，不要求手机端先升级；
- 远端 JSON 坏行 → 跳过并计数，不整包失败；坏行不能让本地数据被清空；
- 未知字段进 `extras` 并在下次上传时带回（仅 v2）。

## 12. 验收清单

实现阶段 A 后至少手动验证：

1. 桌面新建笔记 → 手机同步 → 手机能看到，时间显示正确（不差 8 小时）。
2. 手机新建日记（含标注/录音）→ 桌面同步 → 能看到；标注进入 `mark`，音频
   引用存在；开启音频后能下载并播放。
3. 桌面给笔记加用户标签 → 手机同步 → 手机重写 `diary.json` → 桌面再同步 →
   标签仍在（证明 v2 未被破坏）。
4. 桌面删除笔记 → 手机同步（旧手机把笔记传回）→ 桌面仍保持删除；手机仍显示
   （预期边界，记录在案）。
5. 两台桌面同时同步：软锁生效；不出现重复笔记；冲突内容生成冲突副本。
6. 手机端修改 `hotwords.txt` / `correction_pairs.json` → 桌面同步后原样保留。
7. 远端未知协议版本 → 桌面中止且不改任何文件。
8. 断网/中途失败 → 本地数据完整；锁能释放或超时；下次续传。
9. 坚果云请求数：一次常规同步 ≤ 20 个请求（不含资源批量）；设置页显示的
   「最近 30 分钟」计数应随每次同步增加，重启后不清零。
10. 确认手机端 v17 不会清理 `v2/` 目录（真机观察）。
11. 手机悬浮窗截图 → 桌面同步 → 笔记卡片出现图片；`blobs/` 有对应文件；
    手机重截后桌面同步换成新图；手机删掉截图后桌面附件移除。

## 13. 开放问题

1. 手机端 v2 的时间字段全面切 UTC 后，旧数据的本地时间字符串如何迁移展示？
2. 图片当前默认随笔记同步，暂无单独开关；若后续改为默认关闭，v2 的 `assets`
   将主要服务音频与桌面间同步。
3. 云端附件是否需要“墓碑 + 回收”？当前只增不减。
4. 是否要做端到端加密（锁定笔记）？会影响 v2 字段与搜索。
5. v1 投影何时冻结/删除？需要 `writers` 统计与用户提示。
6. 自动同步：已实现“启动一次 + 手动 + 本地改动后延时（约 25 秒）”。如果后续
   加入后台常驻定时同步，需要重新评估请求预算与后台锁策略。

## 14. 实现现状与边界（2026-10-23）

已实现，代码在 `lib/sync/`：

| 能力 | 说明 |
|------|------|
| 软锁 | 读/写/释放 v1 `manifest.json` 的 `lock`；他机持锁且未过 10 分钟则中止 |
| v1 导入 | `diary.json` 按 uuid 与自然键去重；墓碑优先；无法解析的行原样保留 |
| v2 权威 | 读 `v2/manifest.json` / `notes.json` / `tombstones.json`，校验协议版本 |
| 合并 | 载荷哈希基线 + `updated_at` LWW + 平局确定性裁决；双方都改且相差 < 5 分钟时给输家生成冲突副本 |
| 删除 | 墓碑写入/读取；`updated_at > deleted_at` 严格复活 |
| v1 投影 | 本地时间无 `Z`、布尔写数字 `1`、保留 `images` / `tags` 等未知字段 |
| 图片 | `v2/assets` 内容寻址；校验 sha256、20 MB 上限与图片格式；失败只记提醒 |
| 手机截图 | 读根目录 `image_index.json`（缺失/空=无操作，坏 JSON=不可用不清旧附件）；按 `(note_uuid, device_id)` 归并、坏行跳过、name 收敛为 basename；给笔记挂稳定 uuid 的 `origin='mobile'` 图片附件，字节走既有 `v2/assets` 下载；不改笔记 `updated_at` |
| 录音 | v1 `audio`/`duration` 归一成音频附件；开关开启时按 `audio_index.json` 下载到 `blobs/`（100 MB 上限），编辑页可播放；默认只保留引用 |
| 落库 | `applySync` 单事务，校验快照 `(updated_at, rev)`，同步期间本地改动则整轮重试一次 |
| 顺序 | 本地事务落库 → 图片资源 → `v2/notes.json` → `v2/tombstones.json` → `v2/manifest.json` → `diary.json` |
| 备份 | 仅在真正写内容文件前把远端旧 JSON 复制到数据目录 `sync_backup/`，保留最近 20 次；纯拉取、心跳轮次与只加锁/解锁的轮次不备份 |
| 触发 | 启动静默同步、顶部云图标手动同步、本地改动后 25 秒防抖、按设置间隔（默认 10 分钟）轻量探测远端；同步中收到的改动结束后补跑 |
| 自动探测 | `PROPFIND Depth: 0` 比较 `diary.json` / `image_index.json` / `v2/notes.json` / `v2/tombstones.json` 的 ETag；notes 版本变了再读一次比对内容指纹，排除 `generated_at` / `device_id` 心跳；未变化时 4～5 个请求结束，不加锁不写远端，不支持 PROPFIND 时退回完整同步 |
| 去重写 | 忽略时间戳与所有写入者的 `writers.last_seen` 后内容未变，不重传 v2 三个快照 |
| 请求预算 | `WebDavClient._request` 统一计数，滚动 30 分钟、跨重启持久化到配置目录；设置页展示已用/剩余估算并在 80% 时提醒（§4.7.1） |
| 凭据 | 密码存 Windows 凭据管理器（`win32` 的 `CredWriteW`），不进 `settings.json`、数据库或日志 |

尚未实现：

- `v2/items.json`、`v2/tags.json`（物品与用户标签）；当前只同步笔记
- 桌面端录音与音频上传（当前只下载/播放手机录音，不产生新录音）
- 手机端 v17 的编辑/删除跨端传播（取决于手机端升级 v2）

已知边界：

- 手机端 v17 只读 `diary.json`：桌面端的编辑/删除对手机不可见，手机端删掉的
  笔记在桌面端仍保留（§4.4）。
- 软锁不是原子 test-and-set；两台设备极端同时同步可能重复上传相同数据，
  不会造成结构损坏。
- v2 墓碑暂不按 180 天清理；远端资源只增不减。
- 图片同步不受“单次 80 个”上限约束，但每张都先查远端是否存在；大量首次上传
  可能触发网盘限流，失败项下次续传。
- 手机截图与桌面图片经 `image_index.json` 双向桥接：手机截图只做手机 → 桌面
  挂载；桌面图片以 `source='desktop'` 发布、手机端 v18 起下收多图。旧手机端
  不读索引，桌面端也不会替手机删条目（删除由发布方重写索引表达）。
- 手机截图索引坏 JSON 按“不可用”处理（不清已有 mobile 附件）；若手机端一直写
  坏索引，桌面会持续保留上一次成功的截图。

## Changelog

- 2026-10-26（实现）：轮询改为探测内容文件（`diary.json`、`image_index.json`、
  `v2/notes.json`、`v2/tombstones.json`），notes 版本变化后再读一次比对内容指纹，
  排除 `generated_at` / `device_id` 心跳；心跳轮次不再触发完整同步，也不加锁、
  不写远端。备份改为只在真正写内容前创建，纯拉取与心跳轮次不留副本；v2
  manifest 的所有 `writers.*.last_seen` 都不再触发写回（§4.7）。

- 2026-10-25（实现）：新增本机 WebDAV 请求计数。`WebDavClient._request` 统一记账，
  滚动 30 分钟窗口按分钟归档并持久化到配置目录 `webdav_requests.json`；设置页
  显示已用/按免费版 600 次估算的剩余额度，80% 变红提醒，429 报错附带本机计数。
  坚果云没有额度查询接口，只统计这台电脑，手机端请求不计入（§4.7.1）。

- 2026-10-24（实现）：图片桥接扩展为**双向多图**。索引条目增加 `position`
  （附件 `sort_order` 映射）与 `source`（`desktop`/`mobile`）；桌面端在图片
  资产上传后发布自有图片条目（只发 `origin != 'mobile'`，`updated_at` 用笔记
  时间防抖动，规范化 JSON 比较无变化不写）；读索引时跳过 `source='desktop'`
  与本机 device_id 条目，按 `position` 挂多张 `origin='mobile'` 附件。手机端
  下收多图到 v18 `diary_images`，悬浮窗/随手记出数量与图集。旧索引缺字段按
  position=0、source=mobile 兼容。
- 2026-10-24（实现）：手机截图桥接——手机端写根目录 `image_index.json`（按
  `(note_uuid, device_id)` 所有权），图片落 `v2/assets/`；桌面端读索引，为笔记
  挂 `origin='mobile'` 的图片附件，不改 `updated_at`。索引缺失/空=无操作，
  坏 JSON=不可用（不清旧附件），坏行跳过。（§4.8，现已扩展为双向）
- 2026-10-24（实现）：定时自动同步——设置里可选关闭/5/10/15/30 分钟（默认 10）；
  到点先做 ETag 轻量探测，未变化时一轮仅 2 个请求；完整同步不再重传未变化的 v2
  快照（见 §4.7）。
- 2026-10-24（实现）：录音桥接——v1 `audio`/`duration` 归一为音频附件并稳定参与
  载荷哈希；新增「同步录音」开关（默认关），开启后按 `audio_index.json` +
  `audio/` 下载到 `blobs/`；卡片显示录音信息，编辑页用 `audioplayers` 播放。
- 2026-10-23（实现）：完成阶段 A 子集——软锁、v1 导入与投影、v2 笔记与墓碑、
  三方合并与冲突副本、图片资产同步、备份与同步状态；物品/标签待后续。
- 2026-10-23：首版。明确“本地存储与协议解耦”；采用 `v2/` 命名空间隔离桌面
  专属字段；定义 v1 投影字段、时间格式、LWW/墓碑/标签/附件合并规则、音频桥接、
  版本协商与验收清单。
