---
name: permanent-delete-menu
description: Use when working on the "永久删除（不进回收站）" Windows Explorer right-click menu tool — installing, removing, or debugging the context-menu verb, rebuilding PermanentDeleteSetup.exe, running its test suites, or extending it with new features. Also use when a context-menu item does not appear in Explorer, when a multi-select pops multiple confirmation dialogs, or when the deployed PowerShell/VBS engine misbehaves.
---

# 永久删除右键菜单（PermanentDeleteSetup）

一键添加/移除资源管理器右键菜单里的「永久删除（不进回收站）」，删除不经过回收站。

## 结构

```
<仓库根>\                         也就是 clone 下来的目录，例如 D:\tools\permanent-delete-menu
  build.ps1                      一键编译（用系统自带 csc.exe，不需要 .NET SDK）
  bin\PermanentDeleteSetup.exe   交付物：单文件 GUI+CLI 安装器（引擎脚本已内嵌；不入仓，走 Releases）
  src\*.cs                       C# 源码（C# 5 语法，csc 4.8 编译）
  engine\PermanentDelete.ps1     引擎主脚本（也内嵌进 exe）
  engine\launch_perm_delete.vbs  引擎启动器（也内嵌进 exe）
  tests\Test-All.ps1             一条命令跑完全部测试
  tests\Test-SetupExe.ps1        安装器测试 49 项
  tests\Test-Engine-Regression.ps1 引擎回归 56 项
  tests\Test-Engine-E2E.ps1      真实 Shell 端到端 11 项（会短暂弹真实确认框）
  tools\Test-Encoding.ps1        编码红线检查（本地与 CI 共用）
```

配套 skill 本体（本文件）在仓库的 `skill\permanent-delete-menu\SKILL.md`；
DSH 要认得它，得放到某个 skill 根下，任选其一：
`<工作区>\.dsh\skills\permanent-delete-menu\`（只对那个工作区生效）
或 `%USERPROFILE%\.dsh\skills\permanent-delete-menu\`（所有工作区通用）。
多处副本要同步，否则加载到的是旧版。

部署后的运行时位置：

| 位置 | 内容 |
| --- | --- |
| `%LOCALAPPDATA%\PermanentDelete.ps1` | 引擎主脚本（UTF-8 **带 BOM**） |
| `%LOCALAPPDATA%\launch_perm_delete.vbs` | 引擎启动器（**纯 ASCII**） |
| `%LOCALAPPDATA%\PermanentDelete\setup.log` | 安装器日志 |
| `%LOCALAPPDATA%\PermanentDelete\delete.log` | 引擎删除日志（排障主要看这个） |
| `%LOCALAPPDATA%\PermanentDelete\setup.ini` | 安装器设置 |
| `HKLM\SOFTWARE\Classes\AllFilesystemObjects\shell\PermanentDelete` | 右键动词（**只注册这一处**） |

## 常用命令

```powershell
# 编译（改完 .cs 或 engine\ 后必做；engine 是内嵌资源，不重编 exe 不会更新）
powershell -ExecutionPolicy Bypass -File <项目根>\build.ps1

# 状态（key=value，含 Shell 实测可见性）
& <项目根>\bin\PermanentDeleteSetup.exe status        # GUI 子系统，脚本里请用 ProcessStartInfo/Start-Process -Wait
# 安装 / 卸载（需要管理员，会弹 UAC）
& ...\PermanentDeleteSetup.exe install --quiet
& ...\PermanentDeleteSetup.exe uninstall --quiet
& ...\PermanentDeleteSetup.exe install --quiet --extended      # 只在 Shift 扩展菜单显示

# 三套测试（都用管理员 PowerShell 跑）
powershell -File <项目根>\tests\Test-SetupExe.ps1
powershell -File <项目根>\tests\Test-Engine-Regression.ps1
powershell -File <项目根>\tests\Test-Engine-E2E.ps1
```

## 排障：菜单项看不到 / 点了没反应

按顺序查这四件事（**每一条都是本工具踩过的真坑**）：

1. **被右键菜单管理工具隐藏**：`ContextMenuManagerPlus` 之类开了「审核」会给新动词写上
   `LegacyDisable` / `ProgrammaticAccessOnly` / `HideBasedOnVelocityId` → 菜单里就消失。
   `status` 的 `hideFlags=` 非空即此因；`install` 会自动清除，但用户应在该工具里放行这一项。
2. **纯注册表不够，要看 Shell 实测**：`status` 里的 `fileVisible` / `folderVisible` 是用
   `Shell.Application` 枚举动词得到的真实结果。注册表写对 ≠ 菜单可见。
   - **例外：「仅 Shift 显示」时枚举必然为空**。这种模式下动词键上多了 `Extended` 值，
     Shell 只在按住 Shift 时列出它，而 `Shell.Application` 的 `Verbs()` 没法模拟按 Shift。
     判据是 `extendedOnly=true` + 注册表正常 ⇒ `visibleByDesign=true`，**不算故障**
     （曾据此误判"安装失败"，用户一勾这个选项 GUI 就红字报错）。手工验证要按住 Shift 右键。
   - 端到端测试 `Test-Engine-E2E.ps1` 遇到这种模式会返回**退出码 3 = 环境不满足（跳过）**，
     不是失败；`Test-All.ps1` 会把 3 显示成 SKIP。
3. **注册位置错了**：只能注册在 `HKLM\SOFTWARE\Classes\AllFilesystemObjects\shell\PermanentDelete`。
   - `HKCR\*\shell` + `HKCR\Directory\shell` 同时注册会让混合选中弹**两个**确认框；
   - **HKCU\Software\Classes 下的静态动词 Explorer 不认**（实测：文件 0 文件夹 0），所以免管理员不可行。
4. **改名后签名/路径不对**：`command` 必须是 `wscript.exe "<vbs>" %V`，用 `%1` 会变成逐项调用。

## 编码红线（踩过两次，能静默毁功能）

- 引擎 `.ps1` 必须 **UTF-8 带 BOM**：PS 5.1 按 GBK 读会把中文引号读坏 → 弹框变 PowerShell 报错。
- `.vbs` 必须**纯 ASCII**：wscript 按 ANSI 读；UTF-8 中文注释的最后一个字节会**吞掉换行**，
  曾经把下一行的 `maxLen = 28000` 并进注释 → 阈值恒为 0。`build.ps1` 会强制校验这两条。
- 所有工程内 `.ps1` / `.cs` 也要带 BOM（csc 对无 BOM 源码按 ANSI 解码）。
- **补丁工具会静默丢掉 BOM**（本仓库里踩过：改一行 `build.ps1` 后 BOM 没了 → PS 5.1 按 GBK
  解析直接报 `Unexpected token`）。规则：**任何写文件操作之后都要复核 BOM**；
  `build.ps1` 会给 `src\*.cs` 和 `tests\*.ps1` 自动补回，`tools\Test-Encoding.ps1` 能全仓库体检
  （`-Fix` 补 BOM），但 `build.ps1` 自己仍要手工确认。
  复核方法：`[System.IO.File]::ReadAllBytes($p)[0..2]` 必须是 `EF BB BF`。
- 不要往 `Add-Type -TypeDefinition` 的 C# 源码里写中文（命令通道会弄坏它）；把中文当参数传进去。
- 提交前跑 `tools\Test-Encoding.ps1`：它还会顺手拦住**硬编码本机绝对路径**这类泄漏。

## 引擎行为要点（改引擎前必须知道）

- **Shell 是逐项调用动词的**（`MultiSelectModel=Player` 对静态动词不生效）：选 36 个文件夹会拉起
  36 个进程，每个只带 1 个路径。引擎用"命名互斥体 + 队列 + 自适应静默窗口"把它们合并成**一个**
  确认框。窗口默认 700ms（每来一个新请求就顺延），硬上限 8 秒。
- **`%V` 可能不加引号**：含空格的路径会被空格拆成多个参数，引擎用 `REJOIN` 只在"拼回来的路径确实
  存在"时才合并。
- **进程以 `SW_HIDE` 启动**（VBS 用 `Run(cmd, 0, False)` 隐藏控制台），这种进程里 WinForms 的
  `Form.ShowDialog()` 窗口**继承隐藏状态** → 用户看到"右键没反应"。引擎显式 `ShowWindow(SW_SHOW)`
  并有看门狗，1.6 秒仍不可见就退回系统 MessageBox。
- 队列的残留判据是**互斥体**，不是文件时间戳：抢到互斥体 ⇒ 无活实例 ⇒ 启动清残留；此后入队的
  条目一律采纳（这样用户在确认框上停留很久也不会丢请求）。

## 加新功能的惯例

1. 选项 → `src/Settings.cs` 加字段 + `setup.ini` 键 + `MainForm` 一个控件；
2. 动作 → `src/Commands.cs` 加命令（`Options.Parse` 的 switch + 实现），GUI 通过
   `Commands.RunElevatedQuiet("...")` 调用，**不要让界面直接碰注册表**；
3. 新的注册表位置/动词 → `src/AppPaths.cs` 的常量 + `src/MenuRegistry.cs`；
4. 换引擎 → 实现 `src/Engine.cs` 的 `IEngine`（注意：**引擎 exe 不能要求管理员**，
   否则每次右键都弹 UAC；正确形态是"提权安装器 + 不提权引擎"两个 exe）；
5. 每次改完：`build.ps1` → 三套测试全跑一遍。

## 安全约定

- 卸载时会 `reg.exe export` 备份被删的键到 `%LOCALAPPDATA%\PermanentDelete\backup-*.reg`。
- 引擎拒绝盘根（`C:\`）和 UNC 共享根，确认框默认按钮是**取消**。
- 测试全部在 `%TEMP%` 沙箱里做，不会碰用户的真实文件。
