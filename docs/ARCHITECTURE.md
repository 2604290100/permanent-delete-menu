# 架构说明（ARCHITECTURE）

本文写给**想读懂代码、或准备改代码的人**：解释这套工具为什么长成现在这样、每一层负责什么、
每一条看起来奇怪的设计后面是哪次真实事故。若只是想"装上用起来"，看 [`../README.md`](../README.md)；
若遇到问题，看 [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)。

> 约定：本文里凡是**实测结论**都标注了依据；凡是尚未在更多环境下复现的行为，写成"需实测确认"。

---

## 1. 全景

整个工具分**安装期**和**运行期**两条完全独立的链路：安装期只有安装器 exe 参与，
运行期只有 PowerShell 引擎参与，两边唯一的交接物是**注册表里的那一行 command** 和
**`%LOCALAPPDATA%` 下的两个脚本文件**。

### 1.1 安装期

```text
用户双击 PermanentDeleteSetup.exe
      │
      ├─ 无参数 ──▶ Program.Main ──▶ MainForm（按钮窗口：状态 / 添加修复 / 移除 / 测试 / 日志）
      │                                  │
      │                                  └─ Commands.RunElevatedQuiet("install --quiet")
      └─ 有参数 ──▶ Program.Main ──▶ Commands.Run
                                       status / verify / install / uninstall / help

                    （非管理员时：用 ProcessStartInfo.Verb = "runas" 重启自己并附加 --elevated）
                                       │
                                       ▼
                            ┌──────────────────────┐
                            │   Commands.Install   │
                            └──────────┬───────────┘
                     ┌─────────────────┴──────────────────┐
                     ▼                                    ▼
        Engine.cs : IEngine                  MenuRegistry.cs
        PowerShellVbsEngine.Deploy()         Install() / GetStatus() / Uninstall()
        · 从内嵌资源按字节释放两个脚本        · 写 HKLM 动词键
        · 与现文件逐字节比较，一致就不重写    · 清除第三方工具写的隐藏标志
        · 记 sha256 前缀到日志                · 清理历史注册项（先 reg.exe export 备份）
                     │                                    │
                     ▼                                    ▼
   %LOCALAPPDATA%\PermanentDelete.ps1        HKLM\SOFTWARE\Classes\AllFilesystemObjects\
   %LOCALAPPDATA%\launch_perm_delete.vbs     └─ shell\PermanentDelete
                     │                                    │
                     └─────────────────┬──────────────────┘
                                       ▼
                    Native.NotifyShellChanged()   SHChangeNotify(SHCNE_ASSOCCHANGED) 让 Explorer 立刻刷新
                    ShellVerify.Check()           用 Shell.Application 枚举动词，实测「菜单里到底看不看得见」
```

### 1.2 运行期（一次右键）

```text
资源管理器里选中 N 项 → 右键 → 点「永久删除（不进回收站）」
      │  Shell 读注册表动词，展开 %V
      ▼
wscript.exe "<%LOCALAPPDATA%>\launch_perm_delete.vbs" <路径…>        ← 进程以 SW_HIDE 创建
      │  Run(cmd, 0, False)：不闪黑窗；参数逐个加固引号；命令行过长则改写 .pdl 文件传参
      ▼
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA ^
               -File "%LOCALAPPDATA%\PermanentDelete.ps1" <路径…>
      │
      ▼  引擎主流程（engine/PermanentDelete.ps1 末尾的主流程区）
      ├─ 1  Merge-PDSplitArgs    把被空格拆散的路径拼回「确实存在的路径」（日志 REJOIN）
      ├─ 2  Get-SafePathList     去引号/尾分隔符、去重、拒绝盘根与 UNC 共享根（日志 REJECT）
      ├─ 3  选主                 命名互斥体 Local\PermanentDelete.Agent
      │         · 没抢到 → 自己的路径写进队列后退出（日志 HANDOFF）
      │         · 抢到了 → 清残留队列 → 自己的路径入队（日志 PRIMARY）→ 记活实例
      ├─ 4  Wait-PDMergeWindow   自适应合并窗口：每来一个新请求就顺延，硬上限 8 秒
      ├─ 5  Read-PDQueueEntries  取出队列 → 日志 BATCH n=… → Get-TopLevelPaths 折叠嵌套项
      ├─ 6  Measure-PDPaths      统计文件数/体积（1.5 秒预算，超预算标记 Capped）
      ├─ 7  Show-PDListDialog    一个批次只弹一次确认框（默认按钮 = 取消）
      └─ 8  Remove-PDItem × N    原生递归删除 → 失败则回落自底向上遍历（DELETED / FAILED）
                                 删除过程中每 64 个文件泵一次消息，超过 1.2 秒弹进度框
      │
      ▼
%LOCALAPPDATA%\PermanentDelete\delete.log     每个批次以 START 开始、DONE 结束
```

---

## 2. 为什么是「安装器 exe + 外置脚本引擎」

而不是一个纯 exe？三个理由，按重要性排序：

1. **权限必须分层。** 写 `HKLM` 需要管理员；而右键动词每次都会被执行——如果引擎需要管理员，
   **每一次右键都会弹一次 UAC**，这工具直接没法用。所以「需要提权的部分」被压缩到只做一次性的
   注册表操作，引擎本身以当前用户权限运行。这个推论对将来同样成立：
   **若把引擎改写成 exe，必须是两个 exe**（提权的安装器 + 不提权的引擎），合成一个就等于每次右键弹 UAC。
2. **可审计性。** 一个"不经过回收站、直接删文件"的工具，用户有权在动手前读完它到底做什么。
   两个纯文本脚本（约 1000 行 PowerShell + 80 行 VBS）可以直接打开看；
   同样的逻辑编译进 exe 就只能信任发布者。
3. **不重写已验证的东西。** 引擎已有 114 项自动化测试覆盖（见 §7）。把引擎改成 C# exe 意味着
   重写合并逻辑、删除引擎和全部 UI 细节并重新验证一遍，收益只有"少两个文件"。

代价（如实记录）：引擎脚本必然落在用户可写目录，存在被同机同用户进程篡改的可能。
完整的风险评估见 [`../SECURITY.md`](../SECURITY.md)。

---

## 3. 关键设计决策

### 3.1 只注册一处：`AllFilesystemObjects`

```text
HKLM\SOFTWARE\Classes\AllFilesystemObjects\shell\PermanentDelete
    (默认)           = 永久删除（不进回收站）
    Icon             = shell32.dll,247
    Position         = Bottom
    MultiSelectModel = Player
    command          = wscript.exe "<%LOCALAPPDATA%>\launch_perm_delete.vbs" %V
```

- `AllFilesystemObjects` 这个类**对文件和文件夹同时生效**（系统自带的「发送到」就在这一类下），
  所以注册一处就能覆盖两种选中对象。
- **不这么做会怎样**：早期版本同时注册 `HKCR\*\shell`（只管文件）和
  `HKCR\Directory\shell`（只管文件夹）。混合选中时 Shell 认为这是**两个不同的动词**，
  于是弹出**两个**确认框，且两个进程各删一部分——这就是最初的 bug。
- 安装器还会主动**清理历史注册项**（`StaleVerbSubKeys`：`*\shell`、`Directory\shell`、
  `Directory\Background\shell`、`Drive\shell` 下的同名键），清理前先 `reg.exe export` 备份。
- 注册表访问固定使用 `RegistryView.Registry64`：保证 64 位视图下写入，
  不受进程位数影响（否则可能落到 `WOW6432Node`，Explorer 看不到）。

### 3.2 为什么必须 HKLM：HKCU 实测不被认

把同一个静态动词写进 `HKCU\Software\Classes\AllFilesystemObjects\shell\…`，
再用 `Shell.Application` 枚举动词，结果是**文件 0 命中、文件夹 0 命中** —— Explorer 不认用户级静态动词。

- **不这么做会怎样**：如果坚持"HKCU 可以免管理员"，菜单根本不会出现，而注册表读起来一切正常，
  排查会绕很久。
- 因此安装器采用 **asInvoker 清单 + 按需自我提权**：查看状态、测试、枚举可见性都不提权；
  只有点「添加 / 修复」「移除」时用 `runas` 重启自己（带 `--elevated` 标志防止无限递归提权），
  等待子进程结束并把退出码带回。用户取消 UAC 时返回 **5**。

### 3.3 Shell 是「逐项」调用动词的 → 互斥体 + 队列 + 自适应窗口

`MultiSelectModel=Player` 这个值**对静态动词不生效**（实测：选中 36 个文件夹，
引擎日志里出现 36 次 `START n=1` 和 35 次 `HANDOFF n=1`，也就是被拉起了 36 个进程，每个只带 1 个路径）。

```text
36 次调用 ──▶ 第 1 个进程抢到互斥体 ──▶ 成为主实例
              其余 35 个进程 ──▶ 把路径写进队列目录后立刻退出（HANDOFF）
              主实例：反复等待「连续 700ms 没有新条目」──▶ 到齐后合并成一个批次
                      ──▶ 只弹一个确认框 ──▶ 只做一次删除
```

- 队列条目是一个小文件：先写 `<guid>.tmp` 再 `Move` 成 `<guid>.arg`（原子改名，避免读到半成品）。
- **窗口是自适应的**：起始等 700 ms，每发现一个新条目就把截止时间顺延 700 ms，硬上限 8 秒
  （`PERMDEL_MERGE_MS` / `PERMDEL_MERGE_MAX_MS` 可覆盖）。等待超过 1.5 秒会先弹一个
  "正在汇总选中的项目…"的进度框，避免用户以为卡死。
- **不这么做会怎样**：① 用固定窗口（比如"等 700ms 就动手"），一次选几十项时后面的调用还在路上，
  会分成好几批 → 又是多个确认框；② 不做合并，36 个进程会弹 36 个框、删 36 次。
- **残留判据用互斥体，不用时间戳**（`Clear-PDQueue`）：能抢到互斥体 ⇒ 当前没有活着的实例
  ⇒ 队列里剩下的必然是上一个已死实例的残留，直接清空，**绝不重放历史路径**。
  此后入队的条目一律采纳，不看新旧——因为用户在确认框上可能停留好几分钟，
  期间新入队的条目时间戳会很"旧"，但它属于活着的本实例，必须采纳（回归测试 T17 专测这条）。
  唯一的例外是 `.tmp` 半成品：超过 60 秒仍未被改名成 `.arg` 的会被当垃圾删掉
  （进程被杀时留下的碎片）。

### 3.4 `%V` 而不是 `%1`，以及路径被拆散后的 `REJOIN`

- `%1` 只会传**第一个**被选中的路径，多选时等于"只删一个"；`%V` 传整个选中集。
  所以 `command` 用 `%V`（`Engine.BuildVerbCommand()` 生成，VBS 负责加固引号）。
- `%V` 展开时**可能不给路径加引号**，含空格的路径会被空格拆成多个参数。
  实测例子：`C:\a\Vector Magic 1.15 中文版` 变成 `C:\a\Vector`、`Magic`、`1.15`、`中文版` 四个参数。
- `Merge-PDSplitArgs` 的处理原则是**只在拼回来确实是一个存在的路径时才合并**，最多向后拼 16 段，
  绝不凭空猜测；成功合并时写日志 `REJOIN merged=N raw=M`。
- **不这么做会怎样**：含空格的目录会删不掉（报"路径不存在"），或者更糟——
  把 `C:\a\Vector` 这种"看起来像路径的碎片"当成待删目标。
- VBS 一侧也做了加固：参数尾部若是反斜杠就**补成两个**，否则 `"...\dir\"` 里的反斜杠会转义掉
  闭合引号，把后面的参数一起吞进路径。

### 3.5 `SW_HIDE` 启动的进程里，WinForms 窗体是隐形的

VBS 用 `WScript.Shell.Run(cmd, 0, False)` 隐藏控制台（不闪黑窗），代价是**进程以 `SW_HIDE` 创建**。
在这种进程里，WinForms 的 `Form.ShowDialog()` 窗口**会继承隐藏状态**：
进程在模态循环里等用户点击，而用户屏幕上什么都没有——表现就是"右键点了没反应，菜单像死的"。
`MessageBox` 是系统对话框，不受影响（所以旧版本用 MessageBox 时是正常的）。

三层对策：

| 层 | 做法 |
| --- | --- |
| 显示 | `HandleCreated` 事件里直接调 `ShowWindow(SW_SHOW)` + `SW_RESTORE`，再 `SetForegroundWindow` |
| 看门狗 | 200 ms 定时器复核 `IsWindowVisible`；连续 8 次（约 1.6 秒）仍不可见 ⇒ 判定自绘窗体不可用，关掉它 |
| 兜底 | 降级为系统 `MessageBox`（`Yes/No` 且默认第二个按钮 = 否）；连 WinForms 都起不来时再退到 `WScript.Shell.Popup`（`308` = 是/否 + 警告图标 + 默认"否"） |

降级发生在弹框之后，所以**降级路径不会默默吞掉用户的请求**，日志里会留 `UI-FALLBACK` / `UI-FAIL`。
非模态的进度框同样要显式 `ShowWindow`（`Show-PDProgress` 里那行注释就是这么来的）。

### 3.6 `winexe` + 系统自带 `csc.exe`

- 目标机器（Win10/11）一定有 .NET Framework 4.x 和它附带的 `csc.exe`，但**不一定有 .NET SDK**。
  用 `csc.exe` 编译是零安装方案；`build.ps1` 会自动找 `Framework64` 再退到 `Framework`。
- `winexe`（GUI 子系统）天生没有控制台 → 顺手消灭"黑窗闪现"，也顺带缓解 3.5 那类继承隐藏的问题。
- CLI 模式用 `AttachConsole(ATTACH_PARENT_PROCESS)` 把自己挂到父控制台，所以在 cmd/PowerShell 里
  能看到输出。副作用：**在 PowerShell 里用 `&` 调这个 exe 不会等待、也拿不到输出**，
  脚本里请用 `Start-Process -Wait` 或 `ProcessStartInfo`（测试脚本就是这么做的）。

### 3.7 编码红线（三条，都是踩过的事故）

| 文件 | 约束 | 违反后果 |
| --- | --- | --- |
| `engine/PermanentDelete.ps1` | **UTF-8 带 BOM** | PowerShell 5.1 按 GBK/ANSI 解析 → 中文引号读坏，弹框变成 PowerShell 报错 |
| `engine/launch_perm_delete.vbs` | **纯 ASCII** | wscript 按 ANSI 读，UTF-8 中文注释的最后一个字节会**吞掉换行**——曾把下一行的 `maxLen = 28000` 并进注释，导致命令行长度阈值恒为 0 |
| `src/*.cs` | 带 BOM | csc 对无 BOM 源码按 ANSI 解码 → 中文字符串变乱码 |

补充规则（后续维护者最容易踩的）：**很多编辑器/补丁工具保存 UTF-8 时会静默丢掉 BOM**。
本仓库真实踩过"只改了一行 `build.ps1`，BOM 没了，PowerShell 5.1 直接报 `Unexpected token`"。
所以：**任何写文件的操作之后，复核前 3 字节是不是 `EF BB BF`**。
`build.ps1` 现在会自动给 `src/*.cs` 和 `tests/*.ps1` 补回 BOM，但 `build.ps1` 自己仍需人工确认。
`.gitattributes` 里脚本类文件用 `-text`，就是让 git 彻底不碰这些字节。

---

## 4. 一次右键点击的完整时序（带日志）

以"选中 2 个文件 + 1 个文件夹、点确认删除"为例，`delete.log` 大致长这样：

```text
01:04:26.817|START n=3                       ← 主实例收到 3 个路径（另两个进程的 START/HANDOFF 各自一行）
01:04:26.833|HANDOFF n=1                     ← 次要实例把路径交给队列后退出（重复出现若干次）
01:04:26.901|PRIMARY window=700ms max=8000ms n=1
01:04:28.059|WINDOW waited=2143ms entries=3  ← 自适应窗口：又等了 2.1 秒，队列里攒到 3 个条目
01:04:28.060|BATCH n=3 raw=3                 ← 合并结果：3 项一个批次
01:04:28.547|CONFIRM yes n=3 files=3 bytes=3 ← 用户点了「永久删除」（n=文件+文件夹总数，files=文件数）
01:04:28.561|DELETED C:\...\a.txt
01:04:28.562|DELETED C:\...\b.txt
01:04:28.571|DELETED C:\...\sub
01:04:28.580|DONE|ok=3 elapsed=33ms
```

关键点：

- 日志里的时间是**每个进程各写各的**，跨进程比较时看顺序即可。
- **一次用户动作 = 一个 `BATCH` + 一个 `CONFIRM`**。如果看到 `BATCH` 出现两次而用户只点了一次右键，
  说明合并失败（见 TROUBLESHOOTING 的"多选弹多个确认框"）。
- 用户在确认框上停留期间又有新的右键进来，会在 `DONE` 之后出现下一轮 `WINDOW` / `BATCH`
  （主实例是循环处理的，不会丢请求）。

---

## 5. 安全性设计（代码位置可查）

| 措施 | 实现位置 | 说明 |
| --- | --- | --- |
| 拒绝盘根 / UNC 共享根 | `Get-SafePathList` | `C:\`、`\\server\share` 直接进 `Rejected`，只记日志 `REJECT`，不弹框 |
| 去重 + 尾部分隔符规整 | `Get-SafePathList` | 大小写不敏感去重；`C:\dir\\` 归一 |
| 嵌套项折叠 | `Get-TopLevelPaths` | 同时选中父目录和它内部的文件时，只保留父目录（日志 `NESTED collapsed=N`），避免"父目录已删 → 子项报失败" |
| 软链接/联接点只删链接 | `Measure-PDPaths` / `Remove-PDItem` / `Remove-PDTree` / `Remove-PDSharded` | 检测 `ReparsePoint` 属性；目录联接点用 `Directory.Delete(path, false)` 只删链接本身，**绝不递归进目标**（回归测试 T08 验证目标数据仍在） |
| 清除只读/隐藏/系统属性 | `Remove-PDTree`、`Remove-PDSharded` | 原生递归删除遇到只读文件会直接失败，所以先 `SetAttributes(Normal)` 再删 |
| 超长路径 | `Get-LongPath` | 长度 ≥ 240 时加 `\\?\`（UNC 用 `\\?\UNC\`），交给 Unicode API |
| 确认框默认按钮 = 取消 | `Show-PDListDialog` | `AcceptButton = CancelButton`，**回车 = 取消**；降级到 MessageBox 时默认也是第二个按钮（否）；`WScript.Shell.Popup` 用 `308`（默认"否"） |
| 参数文件白名单 | 主流程 `$ArgsFile` 分支 | 只接受 `%TEMP%\permdelete_args_*.pdl`；其余一律忽略并记 `ARGSFILE ignored=`。**绝不把用户选中的普通文件当成参数文件读取或删除** |
| 禁止位置参数误绑定 | 脚本头 `[CmdletBinding(PositionalBinding = $false)]` | 否则第一个路径会被绑到 `$ArgsFile` 上——曾经因此"只选一个文件时绕过确认框直接删" |
| 删除前备份注册表 | `MenuRegistry.BackupKey` | 卸载/清理历史项前 `reg.exe export` 到 `%LOCALAPPDATA%\PermanentDelete\backup-<时间戳>-<键名>.reg` |
| 统计有预算 | `Measure-PDPaths` | 1.5 秒预算，超时记 `Capped`，体积显示退化成 `≥`，绝不为了"算准体积"把确认框卡死 |
| 大目录分片 + 消息泵 | `Remove-PDSharded`、`Pump-PD` | 直接子项多（>1500 文件 / 超过 2 GB / 统计被截断）时逐个子项删除，两个子项之间泵消息；删除超过 1.2 秒弹进度框 |
| 失败不尝试提权/解锁 | `Remove-PDItem` 的返回值 | ACL 拒绝或被独占只报 `FAILED`，弹一个"部分失败"列表，不会偷偷提权或强拆句柄 |

---

## 6. 扩展点：加东西要改哪里

| 想做的事 | 改哪些文件 | 位置提示 |
| --- | --- | --- |
| **加一个选项** | `src/Settings.cs` → `src/MainForm.cs` → `src/MenuRegistry.cs` | `SetupSettings` 加字段 + `Load()/Save()` 的 `switch` 加一个键 → 界面上加一个控件、`ReadUiSettings()` 里读回 → 在写注册表的地方使用它 |
| **加一个命令/动作** | `src/Commands.cs` | `Options.Parse` 的开关解析 → `Run()` 的 `switch` 加一例 → 实现里记得把明细写进 `Logger`（GUI 走 `--quiet`，没有控制台，出问题只能靠 `setup.log` 复盘） |
| **界面按钮** | `src/MainForm.cs` | 只调 `Commands.RunElevatedQuiet("...")`，**界面永远不要直接碰注册表**（这样 CLI 与 GUI 走同一条已验证的路径） |
| **加一个新的注册位置**（例如「发送到」菜单、桌面背景右键） | `src/AppPaths.cs` + `src/MenuRegistry.cs` | 常量集中在 `AppPaths`（`VerbSubKey` / `StaleVerbSubKeys`）；动词类对"文件+文件夹"是否都生效要先确认 |
| **加一条运行时安全规则** | `engine/PermanentDelete.ps1` 的路径规整或删除引擎区 | 规整类改动必须同步补 `tests/Test-Engine-Regression.ps1` 的用例 |
| **换引擎** | `src/Engine.cs` 实现 `IEngine`（`Id`/`DisplayName`/`IsDeployed`/`Deploy`/`Remove`/`BuildVerbCommand`） | 设置项 `Engine=` 已经预留（当前只有 `powershell-vbs`）。记住 §2 的两 exe 规则：引擎 exe **不能**要求管理员 |
| **新增文件位置/日志** | `src/AppPaths.cs` | 与 `%LOCALAPPDATA%` 相关的路径只在这一处定义 |

改动流程见 [`../CONTRIBUTING.md`](../CONTRIBUTING.md)：改完 `build.ps1` → 三套测试全跑。

---

## 7. 测试与验证手段（为什么这些结论可信）

```powershell
powershell -File tests\Test-All.ps1                 # 一条命令跑全套（编码检查 + 三套测试，见下）
powershell -File tools\Test-Encoding.ps1            # 只跑编码红线检查（BOM / 纯 ASCII / 无个人路径）
powershell -File tests\Test-SetupExe.ps1            # 47 项：安装器（会真的装/卸，最后恢复现场）
powershell -File tests\Test-Engine-Regression.ps1   # 56 项：引擎（被测对象是「已部署」的脚本）
powershell -File tests\Test-Engine-E2E.ps1          # 11 项：真实 Shell 动词（会短暂弹出真实确认框）
```

- 回归测试被测的是 `%LOCALAPPDATA%\PermanentDelete.ps1`（**部署后**的副本），
  用 `PERMDEL_AUTOCONFIRM` 跳过 UI，全部在 `%TEMP%` 沙箱里做——所以必须先 `install` 一次。
- 端到端测试用 `Shell.Application` 枚举动词确认菜单可见，再用 `FolderItemVerb.DoIt()` 触发，
  这是**和资源管理器点击同一条链路**（Shell 自己拼命令行、自己展开 `%V`、经 wscript 起脚本）。
- **判断"菜单里到底可见吗"的唯一可信方式**是 `Shell.Application` 动词枚举（`ShellVerify`）。
  注册表写对 ≠ 菜单可见——第三方菜单管理工具的隐藏标志会让它消失。
- 测试写 UI 时的两条经验：点按钮用 `BM_CLICK` 消息而不是 `SendKeys`（确认框是 TopMost，
  抢不到焦点时按键会丢）；关对话框用 `WM_CLOSE` 而不是 Esc（同理）。

## 8. 已知限制

- 单个几十万文件的**超大目录**：分片删除只在直接子项很多时生效，原生删除阶段仍然无法泵消息，
  窗口会短暂无响应（需实测确认具体目录规模下的表现）。
- 合并窗口的硬上限是 8 秒：极端情况（一次选中几百项、机器很慢）下仍有可能分成两批
  （需实测确认）。
- 不做 ACL 提升、不做句柄强拆、不做回收站（这是工具的目的）。删除**不可恢复**。
- 未签名、无自动更新、不联网。风险与信任边界详见 [`../SECURITY.md`](../SECURITY.md)。

---

## 9. 许可

本项目以 **GPL-3.0-or-later** 发布，版权署名 `2604290100`。见 [`../LICENSE`](../LICENSE)。
