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
  src\UpdateCheck.cs             更新检查（只读版本号；PERMDEL_NO_UPDATE=1 可彻底关掉）
  src\DisclaimerForm.cs          免责声明窗口（正文来自内嵌的 docs\DISCLAIMER.md）
  engine\PermanentDelete.ps1     引擎主脚本（也内嵌进 exe）
  engine\launch_perm_delete.vbs  引擎启动器（也内嵌进 exe）
  docs\DISCLAIMER.md             免责声明 / 服务协议正本（也内嵌进 exe，资源名 Disclaimer.md）
  tests\Test-All.ps1             一条命令跑完全部测试
  tests\Test-SetupExe.ps1        安装器测试 64 项
  tests\Test-Engine-Regression.ps1 引擎回归 71 项
  tests\Test-Gui.ps1             界面回归 35 项（枚举子窗口矩形，需交互桌面）
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
powershell -File <项目根>\tests\Test-SetupExe.ps1        # 64 项
powershell -File <项目根>\tests\Test-Engine-Regression.ps1  # 71 项
powershell -File <项目根>\tests\Test-Gui.ps1             # 35 项（要交互桌面，无人会话返回 3 = 跳过）
powershell -File <项目根>\tests\Test-Engine-E2E.ps1      # 11 项（会短暂弹真实确认框）
# 或一次跑全套：tests\Test-All.ps1（无桌面时加 -SkipGui -SkipE2E）

# 更新检查 / 免责声明（只读，不下载不升级）
& ...\PermanentDeleteSetup.exe checkupdate   # update=latest|available|norerelease|error|disabled
& ...\PermanentDeleteSetup.exe disclaimer    # 打印免责声明全文
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
- **"正在汇总选中的项目…"进度框只在真的在等一批项目时才弹**：条件是"队列里已收到 ≥2 项"且
  "已等过 900ms"（`PERMDEL_MERGE_FEEDBACK_MS`）。单次右键只有 1 项 ⇒ 一个多余窗口都不弹。
  曾经是"过了 300ms 就弹"，结果常规右键先闪一个框再消失，用户当成故障。
- **主循环第二轮必须走"静默收尾宽限"**（`Wait-PDMergeWindow -Silent`，`PERMDEL_POSTGRACE_MS`
  = 400ms）：用户在确认框上做完选择（**确定和取消都算**）之后，只静默等一小会儿看有没有新请求，
  **绝不弹窗口**。老版本这里会再走一整轮合并窗口 → 用户刚点完取消，桌面上又跳出一个汇总框
  （回归测试 T22 锁住它：`WINDOW round=2 waited<1000ms`）。
- **`%V` 可能不加引号**：含空格的路径会被空格拆成多个参数，引擎用 `REJOIN` 只在"拼回来的路径确实
  存在"时才合并。
- **进程以 `SW_HIDE` 启动**（VBS 用 `Run(cmd, 0, False)` 隐藏控制台），这种进程里 WinForms 的
  `Form.ShowDialog()` 窗口**继承隐藏状态** → 用户看到"右键没反应"。引擎显式 `ShowWindow(SW_SHOW)`
  并有看门狗，1.6 秒仍不可见就退回系统 MessageBox。
- 队列的残留判据是**互斥体**，不是文件时间戳：抢到互斥体 ⇒ 无活实例 ⇒ 启动清残留；此后入队的
  条目一律采纳（这样用户在确认框上停留很久也不会丢请求）。
- **统计必须是"快速统计"**：`Measure-PDPaths` 默认只给 700ms 预算，且选中项 > 300 个时**一次都不扫**、
  数到 20000 个条目就停手 —— 命中任一条就标 `Capped`，确认框里的数字退化成 `≥` 并多出
  『统计实际大小』按钮（`Show-PDListDialog -MeasureAction`，点了才做完整统计）。
  这条是**延迟红线**：曾经用固定 1.5 秒预算先扫完再弹框，大目录下右键要等很久。
  三个上限分别由 `PERMDEL_MEASURE_MS` / `_ITEM_LIMIT` / `_ENTRY_LIMIT` 覆盖（0 = 不限）。
- **确认框的取消按钮语义是显式控制的**：`$form.AcceptButton = $btnCancel` 之后必须紧跟
  `$btnCancel.DialogResult = None`（表单给按钮设 DialogResult 可能覆盖它）。若取消按钮带上
  `OK` 语义，"点取消"就会变成"确认删除" —— 数据丢失级。改对话框时务必保住这两行，
  并跑一遍"点取消后文件还在"的验证。
- **GUI 的活不能在 UI 线程上干**：提权子进程（`RunElevatedQuiet`）、部署、`ShellVerify.Check`
  的 COM 枚举都要走 `MainForm.RunBusy`（线程池 + 完成后 `BeginInvoke`），否则点按钮就假死。

## 安装器界面的五条硬规则（全是"看着像 bug"那种坑）

| 规则 | 违反后的症状 |
| --- | --- |
| 按钮行只用 `MainForm.LayoutButtonRow()` 排，**不手写坐标** | 手写坐标时「打开日志目录」右边界压进「查看引擎日志」16px，两个按钮糊在一起 |
| 底部那一行用 `MainForm.LayoutButtonRowRight()`（右对齐，同一套量宽逻辑） | 署名、更新提示、「关于」与「免责声明」互相压住 |
| 标签（`Label`）**绝不能和按钮重叠** | 按钮变成一块空白、点它毫无反应（标签把背景重画了，还吃掉鼠标点击） |
| `MinimizeBox = false`（与 `MaximizeBox = false` 一起） | `FixedDialog` + `Min=true/Max=false` 时 Windows 在标题栏画一个**灰掉的**最大化方框，夹在最小化和关闭中间，点了没反应 |
| 界面文字**不用 `✓ ⚠ →` 这类符号** | 微软雅黑没有 `✓`(U+2713) 字形 → 渲染成空白（`【】『』≥…` 正常） |

- 这些规则不是靠自觉：`tests\Test-Gui.ps1` 会**枚举子窗口矩形**判重叠、**读 `GWL_STYLE`**
  判标题栏。改布局后跑一遍它，比看截图可靠（缩略图会骗人）。
- **作者信息只从 `src/AboutForm.cs` 的常量取**：`AuthorName = "mxx1"`（界面显示的简称）、
  `AuthorSite = "mxx1.cn"`、`AuthorUrl`、`RepoUrl`、`License`。底部署名只显示 `mxx1`，
  关于窗口里显示 `mxx1　·　mxx1.cn`（完整域名可点）。版权署名（LICENSE、源码 SPDX 头、
  `AssemblyCompany`）仍是 **mxx1.cn**；`2604290100` 只是 GitHub 账号，只出现在仓库地址里。

- 验证 GUI 时注意：**模态窗口会让 `SendMessage(BM_CLICK)` 一直阻塞**到窗口关闭
  （看起来就像"点了没反应"）。要验证按钮弹出对话框，用 `PostMessage`（`0x00F5`）。
- 状态行那几个标签宽度别贪大：给按钮留出右边距，并让按钮 `BringToFront()`；
  判断有没有重叠别靠眼睛 —— 枚举矩形比一下（`EnumChildWindows` + `GetWindowRect`）。

## 「测试一下」怎么判断用户已经关掉确认框

引擎主实例**全程持有** `Local\PermanentDelete.Agent` 这个命名互斥体，安装器只需问
"这个互斥体对象还在不在"（`Mutex.OpenExisting`）就知道框还开着没有。

- **千万别用 `WaitOne(0)` 去抢**：抢到的一瞬间，正要启动的引擎会把自己判成"已有实例"，
  把手里的路径转交出去然后退出（测试就永远等不到框）。
- 老实现是轮询"测试目录还在不在"，于是**点取消 ⇒ 目录还在 ⇒ 只能等 90 秒超时**，
  用户看到"点完取消，界面一直是禁止状态"。改用互斥体后实测 **551ms** 恢复。
- 测试期间**只锁「测试一下」这一个按钮**，其余按钮保持可用。

## 写 PowerShell 脚本时的一个致命陷阱

```powershell
[void][SomeClass]::SomeMethod(...) 2>$null    # ✗ 整段脚本一行都不会执行
[void][SomeClass]::SomeMethod(...)            # ✓
```

`2>$null` 会把前面的**表达式**提升成"命令管道"，而 `[void]` 转出来的 `System.Void` 无法再转成
管道要的 `System.Object`，报错是
`No coercion operator is defined between types 'System.Void' and 'System.Object'`，
而且是在**创建管道阶段**就炸：连脚本第一行 `Write-Host` 都不会输出，`trap` 也不触发，
极难定位（本仓库写验证脚本时真踩过）。要丢输出就用 `$null = ...`，不要加重定向。

第二个陷阱：**用管道读子进程输出必须边跑边读**。

```powershell
$p.Start(); $t = $p.StandardOutput.ReadToEndAsync(); $p.WaitForExit(); $out = $t.Result  # ✓
$p.Start(); $p.WaitForExit(); $out = $p.StandardOutput.ReadToEnd()                      # ✗ 输出 >4KB 互等
```

管道缓冲区只有 4 KB：子进程写满就阻塞在写调用上，父进程又在等它退出 —— 双方等到超时。
加 `disclaimer`（正文约 5 KB）时**实测踩到**，表现是 `TIMEOUT` 而不是报错。
`Test-SetupExe.ps1` / `Test-Engine-Regression.ps1` 现在都用 `ReadToEndAsync`。

## 更新检查与免责声明（改这两块时必须守住的约定）

**更新检查**（`src/UpdateCheck.cs`）：三条底线不能破 —— ①只读版本号，绝不下载 / 替换文件；
②失败静默（只写 `setup.log`），不弹窗；③`PERMDEL_NO_UPDATE=1` 能彻底关掉（关掉后一个字节都不发）。
接口地址 / 超时可用 `PERMDEL_UPDATE_URL` / `PERMDEL_UPDATE_TAGS_URL` / `PERMDEL_UPDATE_TIMEOUT_MS`
覆盖（测试就是靠这个塞本机假接口的）。命令行 `checkupdate` 输出 `update=latest|available|norerelease|error|disabled`。
引擎（右键删除链路）**永不涉及网络** —— 别把更新检查挪进引擎。

坑：`CheckAsync` 同一时刻只跑一个检查，**在跑期间登记的回调绝不能丢**。老实现遇到"已有检查在跑"
就直接 return，于是新登记的那个（刚打开的关于窗口）永远收不到结果，界面停在「正在检查…」，
看起来像卡死。正确做法：把回调挂到正在跑的那次检查上、出结果一起通知；界面上再放一个 500ms 的
兜底轮询（`AboutForm.PollUpdate`，20 秒还没有结果就显示"检查失败：timeout"）。界面回归 B05/B06 盯着这条。

**免责声明 / 服务协议**：正本只有一份 —— `docs/DISCLAIMER.md`，`build.ps1` 用
`/resource:…,Disclaimer.md` 内嵌进 exe，`DisclaimerForm` 读它并做轻量 Markdown 清理后显示。
**绝对不要在 C# 里再抄一份正文**（两份必然分叉，而这是给用户当条款读的文档）。
改完正文要重新编译，否则窗口里还是旧文本；`build.ps1` 会在编译后自检内嵌资源里有 `Disclaimer.md`。

## 界面回归测试 `tests\Test-Gui.ps1` 怎么用

需要交互式桌面；没有桌面时返回**退出码 3（跳过，不是失败）**。它做四件事：

1. **枚举子窗口矩形**判"按钮之间 / 标签与按钮之间有没有重叠"——`GroupBox` 在 WinForms 里也是
   `BUTTON` 类窗口，所以先用"是否完整包住别人"把容器排除掉；
2. **读 `GetWindowLong(GWL_STYLE)`** 判 `WS_MINIMIZEBOX` / `WS_MAXIMIZEBOX`（这是"标题栏有没有
   那个灰掉的最大化方框"的根因，比扫像素稳）；
3. 用 `PostMessage(BM_CLICK)` 真点「关于」「免责声明」，再用 **`WM_GETTEXT`**（`SendMessageTimeout`）
   跨进程读子控件文字 —— `GetWindowText` 对别的进程里没有标题的窗口常常返回空串（文本框尤其）；
4. 起一个 `HttpListener` **本机假接口**（返回 `{"tag_name":"v9.9.9"}`）塞给
   `PERMDEL_UPDATE_URL`，验证"有新版时底部出现提示"这条路径 —— 整套测试**不碰外网**。

加检查时注意：空的数组从函数返回会被 PowerShell 拆成 `$null`，比较 `.Count` 前先 `@(...)` 包一层。

## 加新功能的惯例

1. 选项 → `src/Settings.cs` 加字段 + `setup.ini` 键 + `MainForm` 一个控件；
2. 动作 → `src/Commands.cs` 加命令（`Options.Parse` 的 switch + 实现），GUI 通过
   `Commands.RunElevatedQuiet("...")` 调用，**不要让界面直接碰注册表**；
3. 新的注册表位置/动词 → `src/AppPaths.cs` 的常量 + `src/MenuRegistry.cs`；
4. 换引擎 → 实现 `src/Engine.cs` 的 `IEngine`（注意：**引擎 exe 不能要求管理员**，
   否则每次右键都弹 UAC；正确形态是"提权安装器 + 不提权引擎"两个 exe）；
5. 加"关于 / 条款"类窗口 → 作者与许可证字符串只从 `src/AboutForm.cs` 取；条款正文写进
   `docs/*.md` 并由 `build.ps1` 内嵌，**不要抄进 C#**；
6. 每次改完：`build.ps1` → 四套测试全跑一遍（无桌面时 `Test-All.ps1 -SkipGui -SkipE2E`），
   改了界面还要按上面的规则补 `tests\Test-Gui.ps1` 的检查。

## 安全约定

- 卸载时会 `reg.exe export` 备份被删的键到 `%LOCALAPPDATA%\PermanentDelete\backup-*.reg`。
- 引擎拒绝盘根（`C:\`）和 UNC 共享根，确认框默认按钮是**取消**。
- 测试全部在 `%TEMP%` 沙箱里做，不会碰用户的真实文件。
