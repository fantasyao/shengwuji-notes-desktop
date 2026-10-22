# 声物记电脑版

Windows 上的轻量本地笔记客户端。第一轮只做本地增删改查，不连接 WebDAV。

## 已实现

- 瀑布流卡片列表，按创建时间倒序；窗口变宽自动 2～4 列
- 新建 / 编辑 / 删除笔记，正文实时搜索
- 笔记内图片：`Ctrl+V` 粘贴截图、从剪贴板粘贴图片文件、按钮选择图片
- 图片缩略图、全屏预览与单张移除；一条笔记最多 12 张
- 输入停顿 600ms 自动保存，图片增删立即保存；关闭窗口前会先落盘
- 浅色 / 深色跟随系统，中文界面，系统字体
- 数据字段与主 App 的 `diary.json` 兼容（未知字段原样保留），便于后续接同步

## 快捷键

| 快捷键 | 作用 |
| --- | --- |
| `Ctrl+N` | 新建笔记 |
| `Ctrl+F` | 聚焦搜索 |
| `Ctrl+S` | 立即保存（编辑页） |
| `Ctrl+V` | 剪贴板有截图时作为图片附件；有文字时正常粘贴文字 |
| `Esc` | 返回列表 / 清除搜索 |

## 数据位置

应用支持目录下的 `shengwuji_desktop/`：

- `notes.json`：笔记列表
- `images/`：图片附件
- `notes.corrupt-*.json`：`notes.json` 损坏时的自动留档

图片只保存在本机，不进入任何同步。

## 运行

```bash
flutter pub get
flutter run -d windows
```

需要 Visual Studio 的「使用 C++ 的桌面开发」工作负载（含 CMake 工具与 Windows 10/11 SDK）。

## 后续（第二轮）

- WebDAV 拉取 / 新建回传，复用主 App 的同步契约
- 编辑 / 删除 / 归档已有笔记
- Markdown 导出到 Obsidian

详细接口与边界见主仓库 `docs/plans/2026-10-22-windows-companion.md`。
