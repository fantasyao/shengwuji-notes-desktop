# 声物记桌面端文档

## 架构规范

| 文档 | 内容 | 状态 |
|------|------|------|
| [数据库架构](architecture/database.md) | 本地 SQLite 表结构、uuid/时间/墓碑约定、附件与标签、迁移与数据目录切换 | P1 已落地；同步所需存储、录音下载/播放与回收站已接入（标签、录制、GC 待做） |
| [同步契约](architecture/cloud-sync.md) | 与手机端 WebDAV 的文件布局、v1 投影、v2 协议、合并规则与升级路径 | 阶段 A 已落地（v1 投影 + v2 权威 + 图片/录音下载） |
| [schema-v1.sql](architecture/schema-v1.sql) | 桌面端本地库 v1 的可执行 DDL | 已落地（与 `lib/data/db_schema.dart` 同步） |

实现入口：[lib/data/note_store.dart](../lib/data/note_store.dart)（门面）·
[lib/data/note_database.dart](../lib/data/note_database.dart)（SQLite）·
[lib/data/legacy_json_note_store.dart](../lib/data/legacy_json_note_store.dart)
（迁移失败兼容模式）。

## 一页纸结论

1. 桌面端本地存储从 `notes.json` 换成 SQLite；笔记、标签、附件、物品、墓碑分表。
2. 身份一律 uuid；时间一律毫秒 UTC；删除先进回收站（`is_archived` 标记），
   永久删除才“硬删 + 墓碑”。
3. 图片与音频统一为附件，文件按 sha256 内容寻址，支持“远端有、本地未下载”的中间态。
4. 用户标签与手机端的固定标注（`tag`）分开：前者进 `tags` 多对多，后者留在 `notes.mark`。
5. 同步不能把桌面专属字段写进 `diary.json`：手机端 v17 回传时会丢掉未知字段。
   桌面端新增 `v2/` 命名空间，v1 文件只作手机端可读投影。
6. 标签、附件、更新时间、墓碑都进 v2；图片随笔记同步，录音下载默认关闭。
7. 已按“存储 → 同步 → 界面能力”落地阶段 A，标签与跨端编辑/删除收敛仍待后续。

## 实施顺序

1. **P1 ✅**：引入 SQLite，完成 `notes.json` 一次性迁移，现有笔记/图片功能不回归。
2. **P2 部分 ✅**：录音下载与播放已接入；标签体系、录制/导入、附件 GC 待做。
3. **P3 阶段 A ✅**：WebDAV 读取 v1 新增、以 v2 为权威、写回 v1 投影；阶段 B
   随手机端升级到 v2 后推进。
4. **P4 部分 ✅**：回收站（移入/恢复/永久删除/清空）已落地；全文搜索、层级标签待做。

每一步的验收点见两份规范末尾。
