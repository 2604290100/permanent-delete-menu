# 贡献指南（CONTRIBUTING）

本文写给**想给本项目提 PR / 修 bug / 加功能的人**。目标是让改动"能被验证"——
这个工具会写 `HKLM` 注册表并且**永久删除文件**，所以本项目对"改完必须证明它没坏"的要求
比一般小工具严一些。原理性内容见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

---

## 1. 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / 11（64 位）。本项目**只在 Windows 10 上实测过** |
| 引擎运行时 | **Windows PowerShell 5.1**（`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`）。引擎必须能在 5.1 上跑，**不要引入只有 PowerShell 7 才有的语法/命令** |
| 编译器 | .NET Framework 4.x 自带的 `csc.exe`。**不需要 .NET SDK，也不要引入 dotnet 构建** |
| 权限 | 手动跑安装器测试需要**管理员**（要读写 `HKLM`）。GUI 日常使用不需要 |
| 交互式桌面 | 跑端到端测试必需（它会弹出真实的确认框） |

代码风格约束：C# 用 **C# 5 语法**（`csc` 4.8 的默认语言版本，别用 `nameof`、字符串插值、
表达式成员等新语法）；WinForms 手写布局，不引入设计器文件。

---

## 2. 快速开始

```powershell
git clone <仓库地址> permanent-delete-menu
cd permanent-delete-menu

# 1) 编译（会顺带做编码红线检查与内嵌资源自检）
powershell -ExecutionPolicy Bypass -File build.ps1

# 2) 装一次（引擎测试测的是"部署后"的脚本，所以必须先装）
.\bin\PermanentDeleteSetup.exe install --quiet     # 会弹一次 UAC
#    在 PowerShell 里用 & 调这个 exe 不会等待也不会返回输出，请看 build.ps1/测试脚本怎么做的

# 3) 跑测试（管理员 PowerShell）
powershell -File tests\Test-SetupExe.ps1            # 49 项
powershell -File tests\Test-Engine-Regression.ps1   # 71 项
powershell -File tests\Test-Engine-E2E.ps1          # 11 项（会短暂弹真实确认框）
```

`build.ps1 -Package` 会额外打一个发布 zip（含源码、测试、文档）。

---

## 3. 编译说明（改完源码必读）

- 引擎脚本 `engine/PermanentDelete.ps1` 和 `engine/launch_perm_delete.vbs` 是**内嵌资源**：
  改了它们**必须重新编译** exe，否则右键菜单跑的仍是旧脚本（部署时释放的是 exe 里的字节）。
- `build.ps1` 会把它们以 `/resource:` 嵌进去，编译后自检资源名是否为
  `PermanentDelete.ps1` / `launch_perm_delete.vbs`——名字不对会直接报错。
- 产物是单一 `bin\PermanentDeleteSetup.exe`（`/target:winexe`、`/platform:anycpu`、
  `/langversion:5`），不依赖旁边的任何文件。
- `build.ps1` 还会自动给 `src/*.cs` 和 `tests/*.ps1` **补回缺失的 UTF-8 BOM**（见 §4）。

---

## 4. 四条硬性红线

### 4.1 编码（每条都对应一次真实事故）

| 文件 | 约束 | 违反后果 |
| --- | --- | --- |
| `engine/PermanentDelete.ps1` | **UTF-8 带 BOM** | PowerShell 5.1 按 GBK/ANSI 解析 → 中文引号读坏，弹框变成 PowerShell 报错 |
| `engine/launch_perm_delete.vbs` | **纯 ASCII**（一个中文注释都不许有） | wscript 按 ANSI 读；UTF-8 中文注释的尾字节会**吞掉换行**，曾把下一行 `maxLen = 28000` 并进注释，阈值恒为 0 |
| `src/*.cs` | 带 BOM | csc 对无 BOM 源码按 ANSI 解码 → 中文字符串乱码 |
| `tests/*.ps1`、`build.ps1` | 带 BOM | 无 BOM 时 PS 5.1 按 GBK 解析中文 → 直接语法错误 |

**最重要的操作习惯**：**任何写文件的操作之后，复核前 3 字节是不是 `EF BB BF`。**

```powershell
$b = [System.IO.File]::ReadAllBytes('engine\PermanentDelete.ps1')
'{0:X2} {1:X2} {2:X2}' -f $b[0], $b[1], $b[2]      # 必须是 EF BB BF
```

原因很实际：不少编辑器（含各类自动化补丁工具）保存 UTF-8 时会**静默丢掉 BOM**。
本仓库踩过"只改了一行 `build.ps1`，BOM 没了，PowerShell 5.1 直接报 `Unexpected token`"。
`.gitattributes` 里脚本类文件用 `-text` 就是为了让 git 完全不碰这些字节——**请不要改动那些规则**。

另外：**不要往 `Add-Type -TypeDefinition` 的内联 C# 源码里写中文字面量**，
命令通道会把中文弄坏（测试脚本里踩过）。中文请当参数传进 C#。

### 4.2 界面与权限

- **GUI 永远不要直接操作注册表。** 界面一律通过 `Commands.RunElevatedQuiet("...")` 走 CLI 命令，
  保证 GUI 与 CLI 是同一条已被测试覆盖的路径（改注册表的逻辑只允许出现在 `MenuRegistry.cs`）。
- **不要给引擎加管理权限需求。** 引擎每次右键都会被执行；一旦它需要管理员，每次右键都会弹 UAC。
  推论：若将来把引擎做成 exe，必须是**两个 exe**（提权的安装器 + 不提权的引擎）。
- 提权子进程的命令行由 `Commands.RunElevatedQuiet(args)` 拼接。**不要把外部/不受信的字符串拼进去**。

### 4.3 破坏性操作必须有一次明确的确认

任何"直接删除"的路径都必须经过确认框，且**默认按钮是取消**（回车=取消）。
历史上出过"单个文件被当成参数文件读取、绕过确认框直接删掉"的事故——
所以 `[CmdletBinding(PositionalBinding = $false)]` 和 `.pdl` 参数文件白名单**不要动**。

### 4.4 零第三方依赖

不需要 .NET SDK、不引入 NuGet 包、不引入第三方 exe/dll，也不要用需要额外安装的 PowerShell 模块。
这不是洁癖：目标环境是"刚装好的 Windows 10"，任何依赖都会让工具装不上。

---

## 5. 测试要求

**提交前必须全绿**（编码检查 + 131 项）。一条命令跑全套（顺序：编码检查 → 安装器 → 引擎回归 → 端到端）：

```powershell
# 需要管理员 PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-All.ps1
#   -SkipE2E   无人桌面（例如 CI runner / 远程会话）时用
#   -SkipExe   不想动本机已安装的右键菜单时用
```

只想查编码红线时（本地与 CI 共用同一份规则）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-Encoding.ps1
#   加 -Fix 可自动补回 .ps1/.cs 缺失的 BOM；.vbs 的非 ASCII 与个人路径必须人工改
```

逐套的前置条件不一样：

| 测试 | 项数 | 前置条件 | 说明 |
| --- | --- | --- | --- |
| `tests\Test-SetupExe.ps1` | 49 | 管理员 | 会**真的安装/卸载**，最后把现场恢复成"已安装可用"。会校验部署的引擎文件与工程源码**字节一致**（含 BOM/ASCII 红线） |
| `tests\Test-Engine-Regression.ps1` | 67 | 管理员 + **先 `install` 一次** | 被测对象是 `%LOCALAPPDATA%\PermanentDelete.ps1`（部署后的副本）；用 `PERMDEL_AUTOCONFIRM` 跳过 UI；全部在 `%TEMP%` 沙箱内 |
| `tests\Test-Engine-E2E.ps1` | 11 | 管理员 + **交互式桌面** | 走真实 Shell 动词（`FolderItemVerb.DoIt()`），会短暂弹出真实确认框。**无人会话/CI 上跑不了** |

写测试时的两条经验（别重复踩）：

- 用 `Shell.Application` 枚举动词判断"菜单里到底可不可见"，这是**唯一可信**的判据
  （注册表写对 ≠ 菜单可见）；
- 点按钮用 `BM_CLICK` 消息，不用 `SendKeys`；关对话框用 `WM_CLOSE(0x0010)`，不用 Esc——
  确认框是 TopMost，抢不到焦点时按键会丢，"取消"就变成靠运气。

改动引擎的规则：

- 改路径规整、合并逻辑、删除引擎 → **必须**在 `Test-Engine-Regression.ps1` 里补一条对应用例；
- 涉及时序的用例（合并窗口）要留足余量：冷启动一个 PowerShell 进程在高负载下可能要几秒，
  窗口设太小会让用例变成"偶尔失败"（本仓库已因此把一个用例的窗口从 3 秒调到 8 秒）。

---

## 6. 加新功能：改哪些文件

| 想做的事 | 位置 |
| --- | --- |
| 加选项 | `src/Settings.cs`（字段 + `setup.ini` 键）→ `src/MainForm.cs`（一个控件 + `ReadUiSettings`）→ 在 `src/MenuRegistry.cs` 用它写注册表 |
| 加命令 | `src/Commands.cs`：`Options.Parse` 解析开关 → `Run()` 的 `switch` 加一例 → 实现里把明细写进 `Logger`（GUI 走 `--quiet`，没有控制台，出问题只能靠 `setup.log`） |
| 加界面按钮 | `src/MainForm.cs`，只调 `Commands.RunElevatedQuiet(...)` |
| 加新的注册位置 | `src/AppPaths.cs`（常量）+ `src/MenuRegistry.cs` |
| 换/加引擎 | 实现 `src/Engine.cs` 的 `IEngine`（`Engine=` 设置项已预留；注意 §4.2 的两 exe 规则） |
| 改引擎行为 | `engine/PermanentDelete.ps1` + 补测试 + 重新编译 |

全套流程：**改代码 → `build.ps1` → 三套测试 → 更新文档（README / `docs/` 里相关的那一篇）**。

---

## 7. 提交信息风格

用 `类型: 简述` 的形式，正文说明**动机**和**验证方式**。

```text
fix: 单个文件右键不再被误当成参数文件删除

原因：$Paths 带 ValueFromRemainingArguments 时，第一个路径会被绑到 $ArgsFile 上，
脚本于是把一个普通文件当参数文件读掉并删除，绕过了确认框。
做法：脚本头加 [CmdletBinding(PositionalBinding = $false)]，
      并把参数文件限制为 %TEMP%\permdelete_args_*.pdl 白名单。
验证：Test-Engine-Regression T01/T14/T15 通过；127 项全绿。
```

常用类型：`feat` / `fix` / `docs` / `test` / `refactor` / `build` / `chore`。
破坏性变更（例如注册表位置变了、要求用户重新安装）请在标题后加 `!` 并在正文写**迁移步骤**。

---

## 8. PR 流程

1. Fork → 从 `main` 建分支，分支名建议 `feat/xxx`、`fix/xxx`；
2. 只改与主题相关的文件，别顺手重排格式（尤其别动 `.gitattributes` 里的 `-text` 规则）；
3. 在 PR 描述里写清楚：
   - **改了什么、为什么**；
   - **怎么验证的**：跑了哪几套测试、结果（贴汇总行）或复现步骤；
   - **有风险的地方**：注册表键变化、需要重装、需要用户做什么；
4. 如果改动影响用户可见行为，README / `docs/` 里的对应段落要同步更新；
5. **不要提交**：个人机器路径（`C:\Users\<你的名字>\...`、自定义盘符目录）、
   真实日志、`bin/` 产物、任何用户数据。测试请使用 `%TEMP%` 沙箱（现有测试都这么做）。

会被直接拒绝的改动：

- 把引擎改成需要管理员权限的 exe（每次右键弹 UAC）；
- 引入第三方依赖（见 §4.4）；
- 让 GUI 直接写注册表；
- 去掉确认框、把默认按钮改成"删除"、或绕过确认；
- 无测试覆盖地修改合并逻辑 / 删除引擎 / 路径安全规则。

---

## 9. 许可与贡献授权

本项目以 **GPL-3.0-or-later** 发布，版权署名 `2604290100`（见 [`LICENSE`](LICENSE)）。

**提交 PR 即表示你同意：你的贡献同样以 GPL-3.0-or-later 授权给本项目及所有下游使用者。**
请只提交你自己有权授权的内容；不要粘贴来源不明（或与 GPL 不兼容）的代码片段、图标、截图。

安全相关问题**不要**走公开 PR/issue，请按 [`SECURITY.md`](SECURITY.md) 的渠道报告。
