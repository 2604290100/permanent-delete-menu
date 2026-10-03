<!--
  感谢提交 PR！

  这个工具会直接写 HKLM 注册表、并且是真的"永久删除"文件，所以下面的清单不是走形式：
  每一条都对应一个真实踩过的坑。请把清单照着填完再提交。
-->

## 这个 PR 做了什么

<!-- 一两句话说明改动内容。如果修的是 issue，请写上 `Fixes #123` / `Closes #123`。 -->

## 为什么要这么改

<!-- 说明动机：修的是哪个现象？或者加这个功能是为了解决什么问题？ -->

## 怎么验证的

<!-- 至少贴一下测试的汇总行（形如「合计 49 项，通过 49，失败 0」），并说明跑的机器环境。 -->

- [ ] 已在本机跑 `tests\Test-SetupExe.ps1`（49 项，安装器 / 注册表 / 编码红线）
- [ ] 已在本机跑 `tests\Test-Engine-Regression.ps1`（67 项，引擎回归，需要先装一次让引擎部署到 `%LOCALAPPDATA%`）
- [ ] 改过 `engine\` 的话，已在本机跑 `tests\Test-Engine-E2E.ps1`（11 项，**需要交互式桌面**，会短暂弹出真实的确认框）
- [ ] 贴了测试汇总行：

```
（把三套测试结尾的「合计 xx 项，通过 xx，失败 0」贴在这里）
```

---

## 提交前勾选清单

### 引擎相关（最容易被漏掉的一条）

- [ ] **改了 `engine\` 下的任何文件后，重新跑过 `build.ps1`。**
      `engine\PermanentDelete.ps1` 和 `engine\launch_perm_delete.vbs` 是**以资源形式内嵌进 exe** 的：
      只改源码不重编，交付物 `bin\PermanentDeleteSetup.exe` 里还是旧引擎，等于白改
      （`build.ps1` 结尾会自检内嵌资源名，但自检的是"有没有嵌进去"，不是"嵌的是不是最新版"）

### 两条编码红线（踩过两次，都是静默毁功能）

- [ ] 红线一：`engine\PermanentDelete.ps1` 保存为 **UTF-8 带 BOM**。
      少了 BOM，PowerShell 5.1 会按 GBK 读，中文引号读坏，确认框会变成一串 PowerShell 报错
- [ ] 红线二：`engine\launch_perm_delete.vbs` 保持**纯 ASCII**（注释也不许有中文）。
      wscript 按 ANSI 读文件，UTF-8 中文注释的最后一个字节会**吞掉换行**，
      曾经把下一行的 `maxLen = 28000` 并进注释里，导致阈值恒为 0
- [ ] 工程内改过的 `.ps1` / `.cs` 都带 BOM（csc 对无 BOM 的 `.cs` 按 ANSI 解码，中文会花），
      改完复核过前 3 个字节是 `EF BB BF`
- [ ] 没有往 `Add-Type -TypeDefinition` 的临时 C# 片段里塞中文字面量（命令通道会把中文弄坏，中文要当参数传进去）

### 架构约束

- [ ] **GUI（`src\MainForm.cs`）没有直接操作注册表**：界面一律通过
      `Commands.RunElevatedQuiet("...")` 去调命令行，保证"界面点按钮"和"命令行敲命令"走的是同一条提权路径
- [ ] 注册位置仍然只有 `HKLM\SOFTWARE\Classes\AllFilesystemObjects\shell\PermanentDelete` 一处。
      不要再往 `HKCR\*\shell` 或 `HKCR\Directory\shell` 加：两处同时注册会让"混合选中"弹出**两个**确认框
      （`HKCU\Software\Classes` 下的静态动词资源管理器根本不认，实测文件 0 命中、文件夹 0 命中，别试）
- [ ] 如果碰了删除引擎，确认这几条安全约束还在：盘根 / UNC 共享根拒绝、联接点只删链接不递归、
      只读属性清除、`\\?\` 超长路径、嵌套选中折叠、确认框默认按钮=取消

### 其他

- [ ] 没有新增第三方依赖（本项目零依赖：csc / PowerShell / .NET Framework 都是 Windows 自带）
- [ ] 没有引入机器相关的绝对路径（源码、脚本、测试里都不该出现形如 `<盘符>:\Users\<用户名>\...` 的硬编码）
- [ ] 日志、截图、测试输出里没有个人路径信息
- [ ] 文档（`README.md`）如果和改动不一致，一并更新了
- [ ] 我确认本次贡献以 **GPL-3.0-or-later** 授权（与仓库 `LICENSE` 一致）
