# AGENTS.md —— 给 AI 助手 / 新会话的开场速读

> 这个文件是给"接手这个仓库的 AI 会话或新贡献者"看的：**先读这一页，再动手**，
> 免得把已经做完的事再做一遍。人类贡献者请看 [`CONTRIBUTING.md`](CONTRIBUTING.md)。

## 这个仓库是什么

给 Windows 资源管理器加一个「永久删除（不进回收站）」右键菜单项：一键添加 / 移除 / 修复，
多选也只弹**一个**确认框。交付物是单文件 `PermanentDeleteSetup.exe`（GUI + CLI），
引擎是部署到 `%LOCALAPPDATA%` 的 PowerShell 5.1 脚本 + VBS 启动器（都以资源形式内嵌进 exe）。

## 当前状态（2026-10-04）

- 版本 **1.0.1**；最近一轮改动的完整列表见 [`CHANGELOG.md`](CHANGELOG.md) 顶部的 `[1.0.1]` 段。
- 测试共 **181 项**：安装器 64 + 引擎回归 71 + 界面回归 35 + 端到端 11（界面回归与端到端需要交互式桌面，
  没有桌面时返回**退出码 3 = 跳过**，不是失败）。
- 免责声明 / 服务协议正本：[`docs/DISCLAIMER.md`](docs/DISCLAIMER.md)（安装器窗口显示的就是它，内嵌资源 `Disclaimer.md`）。
- 更新检查：`src/UpdateCheck.cs`，只读版本号、不下载、失败静默、`PERMDEL_NO_UPDATE=1` 可彻底关掉。

## 先看哪几份文档

| 想知道 | 看 |
| --- | --- |
| 怎么改、提交前要过什么 | [`CONTRIBUTING.md`](CONTRIBUTING.md)（含四条硬性红线） |
| 为什么这样设计（每条决策的实测依据） | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| 菜单不出现 / 点了没反应 / 更新检查报错 | [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) |
| 上一轮到底改了什么（别重复做） | [`CHANGELOG.md`](CHANGELOG.md) |
| 开发惯例与踩过的坑（写代码前必读） | [`skill/permanent-delete-menu/SKILL.md`](skill/permanent-delete-menu/SKILL.md) |

## 构建与测试

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1             # 产物 bin\PermanentDeleteSetup.exe
powershell -ExecutionPolicy Bypass -File build.ps1 -Package    # 额外打发布 zip
powershell -File tools\Test-Encoding.ps1                       # 编码红线体检（改完文件必跑）
powershell -File tests\Test-All.ps1                            # 全套（无桌面时加 -SkipGui -SkipE2E）
```

## 六条最容易踩的硬约定

1. **编码**：`engine\*.ps1`、所有 `.cs` / `.ps1` 必须 UTF-8 **带 BOM**；`.vbs` 必须**纯 ASCII**；
   `.md` / `.yml` **不带 BOM**。违反是"静默毁功能"级别（中文引号读坏、注释吞换行）。
   `build.ps1` 会给 `src\*.cs` 与 `tests\*.ps1` 自动补 BOM，其它文件自己确认。
2. **改了 `engine\` 或 `docs\DISCLAIMER.md` 必须重新编译**：它们是内嵌资源，不重编 exe 就不会更新
   （`build.ps1` 编译后会自检资源名）。
3. **界面四条硬规则**：按钮行只用 `LayoutButtonRow()` / `LayoutButtonRowRight()` 排（不许手写坐标）；
   标签绝不与按钮重叠（会吃掉鼠标点击）；`MinimizeBox = false`；界面文字别用 `✓ ⚠ →` 这类字形。
4. **作者 / 许可证字符串只有一个来源**：`src/AboutForm.cs` 的常量。条款正文只有一个正本：
   `docs/DISCLAIMER.md`（别在 C# 里再抄一份）。
5. **更新检查三条底线**：只读版本号、失败静默、`PERMDEL_NO_UPDATE=1` 能彻底关掉；
   引擎（右键删除那条链路）永远不联网。
6. **合并窗口别缩短**（默认 700 ms），确认框里 `$btnCancel.DialogResult = None` 必须留在
   `AcceptButton` 赋值**之后** —— 否则"点取消"会变成"确认删除"（数据丢失级）。

## 两个小提醒

- **父目录里可能残留项目早期的散装脚本归档**（`.ps1` / `.vbs` / 旧截图），那不是本仓库的源码：
  真源只在仓库的 `engine\`、`src\` 里，别去改那份归档、也别从它复制代码。
- 改完界面要跑 `tests\Test-Gui.ps1`：它用 Win32 枚举子窗口矩形判"有没有压在一起"、
  读窗口样式位判标题栏，比看截图可靠（缩略图会骗人）。
