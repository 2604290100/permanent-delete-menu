# 排障手册（TROUBLESHOOTING）

本文写给**用这个工具遇到问题的用户，以及被叫来排查的人**。按"症状 → 原因 → 解决"组织，
每一条都对应一个真实踩过的坑。想先了解原理（为什么这也不能免费做、为什么会有多个确认框），
看 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

> 本文里的命令默认在**管理员 PowerShell** 里执行（读 HKLM 需要）。
> exe 是 GUI 子系统，**在 PowerShell 里用 `&` 调它不会等待、也不会返回输出**，请用
> `Start-Process -Wait` 或 `[System.Diagnostics.ProcessStartInfo]`。

---

## 0. 先做这三步

```powershell
# 1) 看状态（key=value，含 Shell 实测可见性）
Start-Process -FilePath .\bin\PermanentDeleteSetup.exe -ArgumentList 'status' -Wait -NoNewWindow

# 2) 只做可见性自检
Start-Process -FilePath .\bin\PermanentDeleteSetup.exe -ArgumentList 'verify' -Wait -NoNewWindow

# 3) 打开日志目录（GUI 里也有「打开日志目录」「查看引擎日志」两个按钮）
explorer "%LOCALAPPDATA%\PermanentDelete"
```

`status` 的每一行都可以直接读：

| 字段 | 含义 | 注意 |
| --- | --- | --- |
| `installed` | HKLM 里有没有这个动词键 | `false` = 没装，或装到别处去了 |
| `engineDeployed` | `%LOCALAPPDATA%` 下两个脚本是否都在 | `false` = 菜单点了必然报错 |
| `menuText` | 菜单显示的文字 | 被改过文案时，自检会退化成按产品名「永久删除」匹配 |
| `extendedOnly` | 是否"只在按住 Shift 的扩展菜单里显示" | `true` 时**正常右键是看不到的**，别误判 |
| `multiSelectModel` | 正常情况下是 `Player` | 空值说明键被别的东西改过 |
| `command` | 动词实际执行的命令行 | 必须是 `wscript.exe "...launch_perm_delete.vbs" %V` |
| `hideFlags` | 被写入的隐藏标志 | **非空 = 菜单一定看不到**（见 §1.2） |
| `staleKeys` | 历史/错误位置的注册项 | 非空 = 可能"弹两次框"（见 §4） |
| `fileVisible` / `folderVisible` | **用 Shell 实测**枚举动词的结果 | 唯一可信的"看得见吗"判据 |
| `verifyDetail` | 上面两个值的详情 | 枚举失败时会写原因 |

---

## 1. 右键菜单里根本看不到这一项

### 1.1 先看实测值，不要只看注册表

```text
status 显示 installed=true 但 fileVisible=false / folderVisible=false
```

**原因**：注册表写对 ≠ 菜单可见。Explorer 会因为隐藏标志、注册表位视图、缓存等原因不显示。
**解决**：按 §1.2 → §1.3 → §1.4 的顺序排查。

```text
status 显示 installed=false
```

**原因**：没装成功，或者被别的工具/系统还原清掉了。
**解决**：重新点 GUI 的「添加 / 修复右键菜单」（或 `install --quiet`），然后在 `setup.log` 里看
最后一段 `install:` 明细到底哪一步失败。

### 1.2 隐藏标志被右键菜单管理工具写了（最常见的坑）

```text
status 显示 hideFlags=LegacyDisable  （或 ProgrammaticAccessOnly / HideBasedOnVelocityId / ExtendedVerbs）
```

**原因**：`ContextMenuManagerPlus` 这类"右键菜单管理 / 审核"工具会给**新出现的动词**自动写隐藏值。
原文（`src/AppPaths.cs` 的 `HideFlagNames`）就是这四个：

| 标志 | 作用 |
| --- | --- |
| `LegacyDisable` | 老式禁用：Shell 直接不显示该动词 |
| `ProgrammaticAccessOnly` | 只允许程序调用，不显示给用户 |
| `HideBasedOnVelocityId` | 按使用频次隐藏（管理工具"审核"常用它） |
| `ExtendedVerbs` | 归到扩展动词集合里，常规菜单不列 |

**解决**：

1. 点「添加 / 修复」——安装流程会**主动删除**这四个值，并在 `setup.log` 里记
   `清除隐藏标志 <名字>（多半是右键菜单管理工具写的）`。
2. **更关键的一步**：在那类工具里把这一项**放行/加白**。否则它的下一次"审核"可能又写一遍，
   表现为"修好了，过一会儿又没了"。
3. 修完立刻用 `verify` 确认 `fileVisible=true`。

> 排查期想临时用注册表核对，看的是：
> `HKLM\SOFTWARE\Classes\AllFilesystemObjects\shell\PermanentDelete` 下是否存在上述四个值。

### 1.3 注册表正常、但菜单还是旧的

**原因**：Explorer 有自己的缓存。安装成功后安装器已经调过 `SHChangeNotify(SHCNE_ASSOCCHANGED)`
并等了约 700 ms 再实测，绝大多数情况够用；但某些环境下仍要更彻底地刷新。
**解决**（从轻到重）：

```powershell
# 重启资源管理器
Stop-Process -Name explorer -Force      # Windows 会自动重新拉起它
# 还不行就注销一次（新开的资源管理器进程一定能读到最新注册表）
```

### 1.4 手工改过注册表？注意 32/64 位视图

如果你曾经手工写这个键：必须用 **64 位**的 `regedit.exe`，或在 `reg.exe` 上加 `/reg:64`。
写到 32 位视图会落到 `WOW6432Node` 下，Explorer 读的是 64 位视图，于是"注册表里明明有却看不到"。

- 本工具的安装器固定用 `RegistryView.Registry64`，不存在这个问题。
- 手工写入在此场景下的实际表现**需实测确认**（本仓库没有做过 32 位视图的对照实验）。

### 1.5 确认是不是"只在 Shift 菜单里显示"

```text
status 显示 extendedOnly=true
```

**原因**：你在 GUI 里勾了「只在按住 Shift 时的扩展菜单里显示」。
**解决**：要么按住 <kbd>Shift</kbd> 再右键，要么点「添加 / 修复」前取消这个勾选
（命令行等价物：`install --no-extended`）。

---

## 2. 点了菜单"没反应"、确认框不出现

### 2.1 先看引擎日志有没有这次调用

```powershell
Get-Content "$env:LOCALAPPDATA\PermanentDelete\delete.log" -Tail 30
```

| 日志情况 | 结论 |
| --- | --- |
| 连 `START` 都没有 | Shell 根本没执行到脚本 —— 见 §2.2 / §2.3 |
| 有 `START` 但没有 `CONFIRM` | 脚本起来了但卡在前面或 UI 起不来 —— 见 §2.4 |
| 有 `CONFIRM no` | 是"用户点了取消"（可能是误触/回车，回车=取消） |
| 有 `UI-FALLBACK` / `UI-FAIL` | 自绘窗体不可见，已自动降级为系统弹窗 —— 见 §2.4 |

### 2.2 提示"不是有效的 Win32 应用程序"、"系统找不到指定的文件"

**原因**：`command` 指向的两个脚本之一不存在了。常见于：清理软件/安全软件删掉了它们、
`%LOCALAPPDATA%` 被迁移、或者手工删过。
**解决**：重新「添加 / 修复」（`install` 会把内嵌在 exe 里的脚本重新释放出来，并记录 sha256 前缀）。
确认：

```text
status 的 engineDeployed=true
%LOCALAPPDATA%\PermanentDelete.ps1
%LOCALAPPDATA%\launch_perm_delete.vbs
```

### 2.3 安全软件/HIPS 拦截未签名的 exe

**原因**：exe **没有代码签名**。"写 HKLM 注册表 + 永久删除文件"的行为对 HIPS（如火绒）来说
和恶意软件的特征高度重合，所以首次运行常被拦。
**解决**：

1. 看安全软件的拦截记录，把 `PermanentDeleteSetup.exe` 加入信任/白名单；
2. 再从官方 Releases 重新下载，并**校验 SHA256**（见 [`../SECURITY.md`](../SECURITY.md)）；
3. 如果拦截发生在引擎侧（右键之后没有任何反应、`delete.log` 里连 `START` 都没有），
   需要把 `wscript.exe` 与 `powershell.exe` 的脚本执行行为放行——大多数 HIPS 拦的是
   "wscript/powershell 启动未知脚本"这条规则；
4. 彻底避免只能做代码签名（需要证书），本项目当前**不提供签名版本**。

### 2.4 有 `START` 但没弹框：窗体的"隐形"问题

**原因**：引擎是被 VBS 用 `Run(cmd, 0, False)` 以 `SW_HIDE` 启动的（为了不闪黑窗）。
这种进程里 WinForms 的 `Form.ShowDialog()` 窗口会继承隐藏状态——进程在等你点，
你却什么都看不到。引擎已经用 `ShowWindow(SW_SHOW)` + 看门狗（约 1.6 秒）处理，
并会降级为系统 `MessageBox`。
**解决**：

1. 看日志有没有 `UI-FALLBACK`：有的话说明降级生效了，弹窗应该已经出现在屏幕上（可能被别的窗口挡住）；
2. 确认框是 **TopMost**（会盖在最上层）且 `ShowInTaskbar = true`，用 <kbd>Alt</kbd>+<kbd>Tab</kbd> 找一下；
3. 若日志出现 `UI-FAIL`，后面会跟着异常信息，按信息判断（多数是系统主题/字体/权限异常）；
4. 把 `delete.log` 里那段贴出来提 issue。

### 2.5 一次右键要等好几秒才弹框（顺带解释"正在汇总…"进度框）

**原因**：Shell 是**逐项**调用动词的（选中 36 项 = 36 个进程），引擎必须等这些调用到齐才能只弹一个框。
合并窗口是自适应的：默认"连续 700 ms 没有新请求就动手"，硬上限 8 秒；等待超过 **300 ms** 就会先显示
「正在汇总选中的项目…」，让你知道它有反应了。
**解决**：这是设计行为，不是卡死。嫌慢可以用 `PERMDEL_MERGE_MS` 调小（见 §5），
但调太小会导致多选时分成多批。

### 2.6 大目录右键后要等很久（旧版本的问题，现在最多 700 ms）

**原因**：旧版本为了在确认框里显示"共多少个文件、合计多大"，会**先把整棵目录树扫一遍**
（预算 1.5 秒），大目录下这段时间全花在统计上。
**现在的行为**：自动统计是"快速统计"，三条上限谁先到就停手 ——

| 上限 | 默认值 | 命中后的表现 |
| --- | --- | --- |
| 时间预算 | 700 ms | 确认框里的数字退化成 `≥` |
| 选中项数 | 300 个 | **一次都不扫**，直接弹框 |
| 统计条目数 | 20000 个 | 数到这里就停 |

也就是说，**不管目录多大，确认框都会在合并窗口结束后立刻出现**，延迟不再随文件数增长。
数字没数全时，框上会多一个『统计实际大小』按钮：点它才做完整统计（会显示"已数到 N 个文件"，
可以随时点『停止统计』），统计完按钮变成『重新统计』，摘要里变成精确的"约 X 个文件、合计 约 Y"。

**想要精确数字又不想每次手点**：把上限调大（见 §5），例如
`PERMDEL_MEASURE_ITEM_LIMIT=5000`、`PERMDEL_MEASURE_ENTRY_LIMIT=200000`、
`PERMDEL_MEASURE_MS=5000` —— 代价就是大目录弹框会变慢。

---

## 3. 多选时弹出多个确认框

### 3.1 先确认"这是不是两个不同的用户动作"

如果两次右键间隔很久（比如你先删一批、再删另一批），那**就是两个动作**，两次弹框正常。
判据看日志：一次用户动作应该只对应**一个** `BATCH` + 一个 `CONFIRM`。

### 3.2 历史注册项：最常见的真原因

```text
status 显示 staleKeys=*\shell\PermanentDelete,Directory\shell\PermanentDelete
```

**原因**：早期版本把同一个动词注册在 `*\shell`（只对文件）和 `Directory\shell`（只对文件夹）两处。
混合选中时 Shell 认为是两个动词，于是弹两个框、删两遍。
**解决**：点「添加 / 修复」——安装流程会先清理这些历史键（清理前用 `reg.exe export` 备份到
`%LOCALAPPDATA%\PermanentDelete\backup-*.reg`），日志记 `清理历史注册项 …`。
手工核对路径（都应在 `HKLM\SOFTWARE\Classes\` 下）：

```text
*\shell\PermanentDelete
Directory\shell\PermanentDelete
Directory\Background\shell\PermanentDelete
Drive\shell\PermanentDelete
```

### 3.3 合并窗口被打满

**原因**：一次选中**非常多**项时，Shell 的逐项调用可能拖得很久，超过合并窗口的硬上限（默认 8 秒），
于是前一批先弹框、后面的另起一批。
**解决**：确认日志里是否出现两次 `BATCH`，两次之间隔了多久。极端量级下的具体行为**需实测确认**
（本仓库验证过的规模是"36 个文件夹合并为 1 个批次"）。
可调大窗口（见 §5）后重试。

### 3.4 队列里有"陈旧路径"被重放

**正常情况下不会**：残留队列的判据是互斥体（抢到互斥体 = 没有活着的实例 = 清空残留），
且回归测试 T13 专门验证"陈旧路径不被误删"。
**如果你怀疑是这类问题**：`delete.log` 里 `BATCH n=…` 的 `n` 会明显大于你选的项数。
请带上这段日志与 `%LOCALAPPDATA%\PermanentDelete\queue` 目录里的文件列表提 issue。

---

## 4. 日志：在哪、怎么看

两个日志，分工不同，**不要看错**：

| 文件 | 谁写的 | 内容 |
| --- | --- | --- |
| `%LOCALAPPDATA%\PermanentDelete\setup.log` | 安装器 exe | 安装/卸载/状态/提权/资源释放/注册表操作/隐藏标志清理 |
| `%LOCALAPPDATA%\PermanentDelete\delete.log` | PowerShell 引擎 | 每次右键的完整过程：合并、确认、逐个删除结果 |

两个日志都会在超过 2 MB 时轮转成同名 `.1` 文件（`.1` 是上一份）。

### 4.1 `delete.log` 关键字速查

| 关键字 | 含义 |
| --- | --- |
| `START n=N` | 本进程收到的有效路径数（**每个**被 Shell 拉起的进程都会写一行） |
| `HANDOFF n=N` | 本进程没抢到互斥体，把路径交给队列后退出（合并机制的正常组成部分） |
| `PRIMARY window=…ms max=…ms n=N` | 本进程成为主实例，负责弹框；后面是合并窗口参数 |
| `WINDOW waited=…ms entries=N` | 合并窗口结束：等了多久、队列里攒到几个条目 |
| `BATCH n=N raw=M` | 一个批次：去重折叠后 N 项（原始 M 项）——**一次用户动作应该只有一个 BATCH** |
| `CONFIRM yes/no n=N files=F bytes=B` | 用户的选择；`files` 是文件数，`n` 是"文件 + 文件夹"总数；`bytes` 是统计到的总字节 |
| `DELETED <路径>` | 该项删除成功 |
| `FAILED <路径> :: 原因` | 该项删除失败（占用/权限/路径异常），原因原样记录 |
| `SKIP-MISSING <路径>` | 该项在确认后被别的程序删掉了，跳过 |
| `REJECT <路径>` | 被安全规则拒绝：盘根（`C:\`）或 UNC 共享根（`\\server\share`） |
| `NESTED collapsed=N` | 折叠掉 N 个"父目录内部"的嵌套项 |
| `REJOIN merged=N raw=M` | 把被空格拆散的路径拼回来了（`%V` 不加引号时会发生） |
| `ARGSFILE read=N` / `ARGSFILE ignored=…` | 命令行过长走了 `.pdl` 参数文件 / 该参数文件不在白名单被忽略 |
| `NOOP\|…` | 没有可做的事：路径全不存在、或没有有效路径 |
| `DONE\|ok=N elapsed=…ms` / `DONE\|failed=N …` | 一个批次结束；`failed` 表示有失败项 |
| `UI-FALLBACK` | 自绘窗体不可见，已降级为系统弹窗 |
| `UI-FAIL\|…` | 连窗体都建不起来，降级为 `WScript.Shell.Popup` |
| `FATAL\|…` | 脚本级异常（带堆栈），这时会弹一个错误框 |

排障时最常需要的三段：**这次的 `START`/`BATCH`/`CONFIRM`**、
**失败项的 `FAILED` 原因**、**有没有 `UI-FALLBACK`**。

---

## 5. 用来排障的测试用环境变量

这些是引擎里的测试钩子，正常使用**不需要**改。排查特定症状时可以临时设：

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `PERMDEL_AUTOCONFIRM` | 空 | 设成 `yes`/`no`：跳过 UI 直接按此决定（等于模拟用户点击），自动化测试用 |
| `PERMDEL_MERGE_MS` | `700` | 合并窗口的静默期（毫秒）：连续这么久没有新请求就弹框 |
| `PERMDEL_MERGE_MAX_MS` | `8000` | 合并窗口的硬上限（毫秒） |
| `PERMDEL_BIG_FILES` | `1500` | 目录内文件数超过它就走"分片删除" |
| `PERMDEL_MEASURE_MS` | `700` | 自动统计的时间预算（毫秒），`0` = 不限 |
| `PERMDEL_MEASURE_ITEM_LIMIT` | `300` | 选中项超过它就完全不统计，`0` = 不限 |
| `PERMDEL_MEASURE_ENTRY_LIMIT` | `20000` | 统计数到这么多条目就停手，`0` = 不限 |
| `PERMDEL_LOG` | `%LOCALAPPDATA%\PermanentDelete\delete.log` | 换日志文件位置 |
| `PERMDEL_QUEUE` | `%LOCALAPPDATA%\PermanentDelete\queue` | 换队列目录 |

例：想确认"多选分批"是不是窗口太短造成的，临时调大窗口再试一次：

```powershell
$env:PERMDEL_MERGE_MS = '3000'
$env:PERMDEL_MERGE_MAX_MS = '20000'
# 然后照常右键；注意：右键菜单是 Explorer 拉起的进程，需要让 Explorer 也看到这些变量
# （最简单可靠的方式是用测试脚本，它自己设置变量并直接调用脚本）
```

> 注意：环境变量只对**你从这个终端启动的**进程生效。想影响"右键菜单拉起的进程"，
> 得让 Explorer 继承这些变量（通常要重启 Explorer），所以这条更适合配合
> `tests\Test-Engine-Regression.ps1` 使用，而不是手工右键。

---

## 6. 卸载不干净怎么办

### 6.1 正常卸载会做什么

```powershell
Start-Process -FilePath .\bin\PermanentDeleteSetup.exe -ArgumentList 'uninstall' -Wait -NoNewWindow
```

1. 备份并删除 `HKLM\SOFTWARE\Classes\AllFilesystemObjects\shell\PermanentDelete`；
2. 顺带清理同样位置的四个历史键（`*\shell` 等），以及 `HKCU\Software\Classes` 下的同名残留；
3. **默认保留**引擎脚本（`setup.ini` 里 `RemoveEngineOnUninstall=true` 才会连脚本一起删）；
4. 日志保留（`setup.log` / `delete.log` 不会被清）。

### 6.2 卸载后仍有残留

| 现象 | 处理 |
| --- | --- |
| `status` 里 `installed=true` | 说明键还在（多半是卸载被拒权限/UAC 取消）。重新以管理员卸载，或看 `setup.log` 的 `uninstall:` 明细 |
| `status` 里 `staleKeys` 非空 | 历史键还在：再点一次「添加 / 修复」，或手工删掉第 3.2 节列出的那些路径 |
| `status` 里 `hideFlags` 非空 | 菜单管理工具又写了隐藏标志；卸载后这些值其实已无意义（键都没了），但若你随后重装，记得放行这一项 |
| 菜单还在、点了报错 | `command` 指向的脚本被删了：**重新 install**（会重新释放脚本），或彻底卸载 |
| 想彻底清干净 | 删注册表键 → 删 `%LOCALAPPDATA%\PermanentDelete.ps1`、`launch_perm_delete.vbs` → 整个目录 `%LOCALAPPDATA%\PermanentDelete\`（里面有日志、设置、队列、`backup-*.reg` 备份） |

### 6.3 用 `verify` 复核

卸载后应该两个都是 `false`：

```powershell
Start-Process -FilePath .\bin\PermanentDeleteSetup.exe -ArgumentList 'verify' -Wait -NoNewWindow
# fileVisible=false
# folderVisible=false
```

### 6.4 注册表改坏了想还原

卸载/清理动作前，工具已经把被删的键导出为
`%LOCALAPPDATA%\PermanentDelete\backup-<时间戳>-<键名>.reg`。
双击即可导回（需要管理员），也可以先用文本编辑器打开核对里面到底是什么。

---

## 7. 仍然解决不了

提 issue 时请附上这些（**不要只写"菜单没有"**，那没法查）：

1. `PermanentDeleteSetup.exe status` 的完整输出；
2. `%LOCALAPPDATA%\PermanentDelete\setup.log` 与 `delete.log` 的相关片段
   （**贴之前把路径里的用户名等信息自行打码**）；
3. Windows 版本（`winver`）+ 是否 64 位；
4. 安全软件名称与版本（尤其是 HIPS）；
5. 是否装了右键菜单管理工具（例如 ContextMenuManagerPlus）、它的"审核"是否开着；
6. 复现步骤：选了什么（文件/文件夹/混合）、多少个、点了几次。

**不要在公开 issue 里贴安全漏洞的 PoC**——那类内容请走
[`../SECURITY.md`](../SECURITY.md) 里的私下报告渠道。
