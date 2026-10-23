# 声物记电脑版

Windows 上的轻量本地笔记客户端。第一轮只做本地增删改查，不连接 WebDAV。

## 已实现

- 瀑布流卡片列表，按创建时间倒序；窗口变宽自动 2～4 列
- 新建 / 编辑 / 删除笔记，正文实时搜索
- 笔记内图片：`Ctrl+V` 粘贴截图、从剪贴板粘贴图片文件、按钮选择图片
- 图片缩略图、全屏预览与单张移除；一条笔记最多 12 张
- 输入停顿 600ms 自动保存，图片增删立即保存；关闭窗口前会先落盘
- 浅色 / 深色跟随系统，中文界面，系统字体
- 全局快捷键呼出速记窗（默认 `Ctrl+Alt+Space`，可在设置里改）：右下角置顶小窗，`Ctrl+Enter` 保存并收起，`Esc` 收起但保留草稿
- 关闭主窗口不退出：隐藏到系统托盘，托盘菜单可快速记录 / 打开主界面 / 设置 / 退出
- 笔记数据目录可在设置里更换（默认应用数据目录），切换时复制到新目录、原目录保留，立即生效
- 数据字段与主 App 的 `diary.json` 兼容（未知字段原样保留），便于后续接同步

## 快捷键

| 快捷键 | 作用 |
| --- | --- |
| `Ctrl+N` | 新建笔记 |
| `Ctrl+F` | 聚焦搜索 |
| `Ctrl+S` | 立即保存（编辑页） |
| `Ctrl+V` | 剪贴板有截图时作为图片附件；有文字时正常粘贴文字 |
| `Esc` | 返回列表 / 清除搜索 |
| `Ctrl+Alt+Space` | 全局呼出 / 收起快速记录（可自定义） |
| `Ctrl+Enter` / `Ctrl+S` | 速记窗里保存并收起 |
| `Esc` | 速记窗收起，草稿保留到下次呼出 |

## 数据位置

默认在应用支持目录 `%APPDATA%\Shengwuji\Shengwuji Desktop\shengwuji_desktop\`：

- `notes.json`：笔记列表
- `images/`：图片附件
- `notes.corrupt-*.json`：`notes.json` 损坏时的自动留档

`settings.json`（快速记录快捷键、数据目录指针）固定留在该目录，不会跟着笔记走。
设置 → 数据位置 → 更改… 可以把 `notes.json` 与 `images/` 换到任意文件夹（如 D 盘或同步盘）：
切换时会把现有数据复制到新目录、原目录保留，立即生效；新目录里已有笔记时会先确认再切换。
外接盘暂时不可用时，启动会回退默认目录，不会卡在启动阶段。

图片只保存在本机，不进入任何同步。

## 运行

```bash
flutter pub get
flutter run -d windows
```

需要 Visual Studio 的「使用 C++ 的桌面开发」工作负载（含 CMake 工具与 Windows 10/11 SDK）。

## 打包发布

双击 `scripts\package_windows.bat`（或在 PowerShell 里运行 `scripts\package_windows.ps1`）即可一次完成：
构建 release → 自动查找并复制 VC++ 运行库（`msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`）→ 压缩成 zip。
产物在 `dist\shengwuji_desktop-v<版本>-windows-x64.zip`，版本号取自 `pubspec.yaml`（可加 `-Version 0.1.1` 覆盖）。

- 任何一步失败都会以非 0 退出码结束、打印原因，bat 窗口会停住等按键，不会一闪而过
- 运行库通过 vswhere 查找已安装的 Visual Studio（自定义安装盘符也能找到）；找不到时用 `-VcRuntimeDir` 指定 `...\x64\Microsoft.VC142.CRT`
- 接收方不需要 Flutter / Visual Studio，解压后双击 `shengwuji_desktop.exe` 即可

## 后续（第二轮）

- WebDAV 拉取 / 新建回传，复用主 App 的同步契约
- 编辑 / 删除 / 归档已有笔记
- Markdown 导出到 Obsidian

详细接口与边界见主仓库 `docs/plans/2026-10-22-windows-companion.md`。
