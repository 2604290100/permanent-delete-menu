// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 2604290100
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace PDSetup
{
    /// <summary>
    /// 按钮窗口：状态 + 一键添加/移除 + 测试。
    /// 加新功能的惯例：选项加进 SetupSettings + 这里的一个控件，动作加进 Commands，
    /// 不要让界面直接碰注册表。
    /// </summary>
    internal sealed class MainForm : Form
    {
        private Label _lblEngine;
        private Label _lblRegistry;
        private Label _lblVisible;
        private Label _lblFlags;
        private CheckBox _chkExtended;
        private TextBox _txtMenuText;
        private TextBox _txtIcon;
        private TextBox _txtLog;
        private Button _btnInstall;
        private Button _btnRemove;
        private Button _btnTest;
        private Button _btnRefresh;
        private Button _btnOpen;
        private ProgressBar _progress;
        private StatusStrip _statusStrip;
        private ToolStripStatusLabel _statusLabel;

        private readonly IEngine _engine = new PowerShellVbsEngine();

        /// <summary>0 = 空闲，1 = 有后台操作在跑（防止重复点击）。</summary>
        private int _busy;

        /// <summary>后台线程算好的状态快照，回到 UI 线程再套用。</summary>
        private StatusSnapshot _snapshot;
        private int _lastCode;

        public MainForm()
        {
            // 标题带上版本号：用户报问题时能一句话说清自己跑的是哪一版
            string ver = Application.ProductVersion;   // 形如 1.0.0.0
            string[] parts = ver.Split('.');
            if (parts.Length >= 3) { ver = parts[0] + "." + parts[1] + "." + parts[2]; }
            Text = "永久删除 · 右键菜单管理  v" + ver;
            ClientSize = new Size(760, 580);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            Font = new Font("Microsoft YaHei UI", 9F);

            BuildUi();
            LoadSettingsIntoUi();
            // 首次检测同样放到后台：窗口先出来，状态栏写"正在检测…"，
            // 免得 COM 枚举还没回来时整个窗口是白屏（那是用户最容易觉得"卡住"的一刻）。
            Shown += delegate { RefreshStatusAsync("正在检测当前状态…"); };
        }

        // ------------------------------------------------------------------ UI
        private void BuildUi()
        {
            GroupBox gbStatus = new GroupBox();
            gbStatus.Text = "状态";
            gbStatus.Location = new Point(12, 8);
            gbStatus.Size = new Size(736, 150);
            Controls.Add(gbStatus);

            _lblEngine = MakeLabel(gbStatus, 16, 26);
            _lblRegistry = MakeLabel(gbStatus, 16, 52);
            _lblVisible = MakeLabel(gbStatus, 16, 78);
            _lblFlags = MakeLabel(gbStatus, 16, 104);

            _btnRefresh = new Button();
            _btnRefresh.Text = "重新检测";
            _btnRefresh.Location = new Point(600, 24);
            _btnRefresh.Size = new Size(120, 30);
            _btnRefresh.Click += delegate { RefreshStatusAsync("正在重新检测…"); };
            gbStatus.Controls.Add(_btnRefresh);

            Label hint = new Label();
            hint.Text = "可见性由系统 Shell 实测枚举，不是只看注册表。";
            hint.ForeColor = Color.DimGray;
            hint.Location = new Point(392, 82);
            hint.Size = new Size(330, 40);
            gbStatus.Controls.Add(hint);

            GroupBox gbOpt = new GroupBox();
            gbOpt.Text = "选项（改完点『添加 / 修复』生效）";
            gbOpt.Location = new Point(12, 164);
            gbOpt.Size = new Size(736, 100);
            Controls.Add(gbOpt);

            Label l1 = new Label();
            l1.Text = "菜单文字";
            l1.Location = new Point(16, 28);
            l1.Size = new Size(70, 22);
            gbOpt.Controls.Add(l1);

            _txtMenuText = new TextBox();
            _txtMenuText.Location = new Point(92, 25);
            _txtMenuText.Size = new Size(300, 24);
            gbOpt.Controls.Add(_txtMenuText);

            Label l2 = new Label();
            l2.Text = "图标";
            l2.Location = new Point(408, 28);
            l2.Size = new Size(36, 22);
            gbOpt.Controls.Add(l2);

            _txtIcon = new TextBox();
            _txtIcon.Location = new Point(448, 25);
            _txtIcon.Size = new Size(270, 24);
            gbOpt.Controls.Add(_txtIcon);

            _chkExtended = new CheckBox();
            _chkExtended.Text = "只在按住 Shift 时的扩展菜单里显示（更安全，不容易误点）";
            _chkExtended.Location = new Point(92, 60);
            _chkExtended.Size = new Size(500, 24);
            gbOpt.Controls.Add(_chkExtended);

            GroupBox gbAct = new GroupBox();
            gbAct.Text = "操作";
            gbAct.Location = new Point(12, 270);
            gbAct.Size = new Size(736, 74);
            Controls.Add(gbAct);

            _btnInstall = MakeButton(gbAct, "添加 / 修复右键菜单", 16, 26, 190);
            _btnInstall.Click += OnInstall;

            _btnRemove = MakeButton(gbAct, "移除右键菜单", 218, 26, 150);
            _btnRemove.Click += OnRemove;

            _btnTest = MakeButton(gbAct, "测试一下", 380, 26, 110);
            _btnTest.Click += OnTest;

            _btnOpen = MakeButton(gbAct, "打开日志目录", 502, 26, 130);
            _btnOpen.Click += delegate
            {
                try { Directory.CreateDirectory(AppPaths.AppRoot); Process.Start("explorer.exe", AppPaths.AppRoot); }
                catch (Exception ex) { SetStatus("打开目录失败: " + ex.Message); }
            };

            // 宽度 104 而不是 84：9pt 微软雅黑下 6 个汉字约 78px，加上内边距后 84 会把
            // 最后一个字裁掉，用户看到的是「查看引擎日」——这种"看着像 bug"的截断必须避免。
            _btnRefresh2 = MakeButton(gbAct, "查看引擎日志", 616, 26, 104);
            _btnRefresh2.Click += delegate { ShowEngineLog(); };

            // 不确定进度条：后台干活时显示，让"卡一下"变成"在忙"。
            // 放在日志框和状态栏之间的空隙里，不遮任何控件。
            _progress = new ProgressBar();
            _progress.Style = ProgressBarStyle.Marquee;
            _progress.MarqueeAnimationSpeed = 30;
            _progress.Location = new Point(12, 536);
            _progress.Size = new Size(736, 6);
            _progress.Visible = false;
            Controls.Add(_progress);

            Label logLabel = new Label();
            logLabel.Text = "安装器日志（最近）:";
            logLabel.Location = new Point(12, 350);
            logLabel.Size = new Size(160, 20);
            Controls.Add(logLabel);

            _txtLog = new TextBox();
            _txtLog.Multiline = true;
            _txtLog.ReadOnly = true;
            _txtLog.ScrollBars = ScrollBars.Vertical;
            _txtLog.WordWrap = false;
            _txtLog.BackColor = Color.White;
            _txtLog.Font = new Font("Consolas", 8.5F);
            _txtLog.Location = new Point(12, 372);
            _txtLog.Size = new Size(736, 160);
            Controls.Add(_txtLog);

            _statusStrip = new StatusStrip();
            _statusLabel = new ToolStripStatusLabel("就绪");
            _statusStrip.Items.Add(_statusLabel);
            Controls.Add(_statusStrip);
        }

        private Button _btnRefresh2;

        private static Label MakeLabel(Control parent, int x, int y)
        {
            Label l = new Label();
            l.Location = new Point(x, y);
            l.Size = new Size(700, 22);
            l.Text = "";
            parent.Controls.Add(l);
            return l;
        }

        private static Button MakeButton(Control parent, string text, int x, int y, int w)
        {
            Button b = new Button();
            b.Text = text;
            b.Location = new Point(x, y);
            b.Size = new Size(w, 32);
            parent.Controls.Add(b);
            return b;
        }

        private void SetStatus(string text)
        {
            _statusLabel.Text = text;
            Logger.Write("gui: " + text);
        }

        // ------------------------------------------------------------------ 状态
        /// <summary>状态的"数据部分"：全部在后台线程算好，UI 线程只负责显示。</summary>
        private sealed class StatusSnapshot
        {
            public SetupSettings Settings;
            public MenuStatus Menu;
            public bool EngineOk;
            public bool ExtendedOnly;
            public VisibilityResult Visible;
            public string LogTail;
            public string Error;
        }

        /// <summary>只读系统状态，不碰任何控件 —— 可以在后台线程安全调用。</summary>
        private StatusSnapshot GatherStatus()
        {
            StatusSnapshot s = new StatusSnapshot();
            try
            {
                s.Settings = SetupSettings.Load();
                s.Menu = MenuRegistry.GetStatus();
                s.EngineOk = _engine.IsDeployed();
                s.ExtendedOnly = s.Menu.Installed ? s.Menu.ExtendedOnly : s.Settings.ExtendedOnly;
                // Shell 动词枚举走 COM，慢的时候几百毫秒 —— 以前它在 UI 线程上跑，
                // 于是"重新检测""添加/修复"一点就假死。现在放后台。
                s.Visible = ShellVerify.Check(s.Menu.Installed ? s.Menu.MenuText : s.Settings.MenuText, s.ExtendedOnly);
                s.LogTail = Logger.Tail(60);
            }
            catch (Exception ex)
            {
                s.Error = ex.Message;
            }
            return s;
        }

        /// <summary>把快照套到界面上（只能在 UI 线程调用）。</summary>
        private void ApplyStatus(StatusSnapshot s, string note)
        {
            if (s == null) { SetStatus("检测失败：没有拿到状态"); return; }
            if (s.Error != null) { SetStatus("检测失败: " + s.Error); return; }

            _lblEngine.Text = "引擎脚本：" + (s.EngineOk ? "已部署" : "未部署")
                + "   " + AppPaths.EnginePs1;
            _lblEngine.ForeColor = s.EngineOk ? Color.FromArgb(0, 100, 0) : Color.FromArgb(180, 0, 0);

            _lblRegistry.Text = "注册表：" + (s.Menu.Installed ? "已安装  " + AppPaths.VerbHklmDisplay : "未安装")
                + (s.Menu.StaleKeys.Count > 0 ? "（注意：还有 " + s.Menu.StaleKeys.Count + " 个历史注册项）" : "");
            _lblRegistry.ForeColor = s.Menu.Installed ? Color.FromArgb(0, 100, 0) : Color.FromArgb(120, 120, 120);

            VisibilityResult v = s.Visible;
            // 注意：这些状态文字全部用中文/ASCII 写，**不要用 ✓ ⚠ → 这类符号**。
            // 微软雅黑没有 ✓(U+2713) 的字形，实测在界面上渲染成空白，
            // 看起来就是"文字缺了一块"——和按钮被裁字的观感一样糟。
            if (v.Visible)
            {
                _lblVisible.Text = "菜单可见性：正常（文件、文件夹右键里都能看到）";
                _lblVisible.ForeColor = Color.FromArgb(0, 100, 0);
            }
            else if (s.ExtendedOnly && s.Menu.Installed)
            {
                // 勾了「仅 Shift 显示」时枚举必然为空 —— 这不是故障，别显示成红的
                _lblVisible.Text = "菜单可见性：仅 Shift 显示（按住 Shift 右键可见）";
                _lblVisible.ForeColor = Color.FromArgb(0, 100, 0);
            }
            else
            {
                _lblVisible.Text = "菜单可见性：看不到（" + v.Detail + "）";
                _lblVisible.ForeColor = v.Ok ? Color.FromArgb(0, 100, 0) : Color.FromArgb(180, 0, 0);
            }

            _lblFlags.Text = s.Menu.HideFlags.Count == 0
                ? "隐藏标志：无"
                : "隐藏标志：" + string.Join(" / ", s.Menu.HideFlags.ToArray()) + "（菜单会看不到，点『添加 / 修复』清除）";
            _lblFlags.ForeColor = s.Menu.HideFlags.Count == 0 ? Color.FromArgb(0, 100, 0) : Color.FromArgb(180, 0, 0);

            _txtLog.Text = s.LogTail;
            SetStatus(note);
        }

        /// <summary>同步版：启动/收尾用，调用方已经在后台线程时也可以直接调。</summary>
        private void RefreshStatus(string note)
        {
            ApplyStatus(GatherStatus(), note);
        }

        /// <summary>异步版：按钮点击用。窗口不会假死，按钮期间禁用。</summary>
        private void RefreshStatusAsync(string busyText)
        {
            RunBusy(busyText, delegate { _snapshot = GatherStatus(); },
                delegate { ApplyStatus(_snapshot, "已重新检测"); });
        }

        // ------------------------------------------------------------------ 后台执行
        /// <summary>
        /// 把耗时的活（提权子进程、部署脚本、COM 枚举）挪到线程池，期间：
        /// 禁用按钮、显示进度条、状态栏写清在干什么。干完再回 UI 线程收尾。
        /// </summary>
        private void RunBusy(string statusText, Action work, Action done)
        {
            if (System.Threading.Interlocked.CompareExchange(ref _busy, 1, 0) != 0)
            {
                SetStatus("上一个操作还没结束，请稍候…");
                return;
            }
            SetUiEnabled(false);
            SetStatus(statusText);
            System.Threading.ThreadPool.QueueUserWorkItem(delegate
            {
                try { work(); }
                catch (Exception ex) { Logger.Write("gui-bg-error " + ex.Message); }
                try
                {
                    BeginInvoke((MethodInvoker)delegate
                    {
                        SetUiEnabled(true);
                        _busy = 0;
                        try { if (done != null) { done(); } }
                        catch (Exception ex) { SetStatus("收尾失败: " + ex.Message); }
                    });
                }
                catch { _busy = 0; }
            });
        }

        private void SetUiEnabled(bool enabled)
        {
            _btnInstall.Enabled = enabled;
            _btnRemove.Enabled = enabled;
            _btnTest.Enabled = enabled;
            _btnRefresh.Enabled = enabled;
            _btnOpen.Enabled = enabled;
            _btnRefresh2.Enabled = enabled;
            _txtMenuText.Enabled = enabled;
            _txtIcon.Enabled = enabled;
            _chkExtended.Enabled = enabled;
            _progress.Visible = !enabled;
            Cursor = enabled ? Cursors.Default : Cursors.AppStarting;
        }

        private void LoadSettingsIntoUi()
        {
            SetupSettings s = SetupSettings.Load();
            _txtMenuText.Text = s.MenuText;
            _txtIcon.Text = s.Icon;
            _chkExtended.Checked = s.ExtendedOnly;
        }

        private SetupSettings ReadUiSettings()
        {
            SetupSettings s = SetupSettings.Load();
            if (_txtMenuText.Text.Trim().Length > 0) { s.MenuText = _txtMenuText.Text.Trim(); }
            if (_txtIcon.Text.Trim().Length > 0) { s.Icon = _txtIcon.Text.Trim(); }
            s.ExtendedOnly = _chkExtended.Checked;
            s.Save();
            return s;
        }

        // ------------------------------------------------------------------ 动作
        private void OnInstall(object sender, EventArgs e)
        {
            ReadUiSettings();
            RunBusy("正在添加 / 修复右键菜单…（可能弹一次 UAC 提权，请留意屏幕）",
                delegate { _lastCode = Commands.RunElevatedQuiet("install --quiet"); },
                delegate
                {
                    int code = _lastCode;
                    ApplyStatus(GatherStatus(),
                        code == 0 ? "添加 / 修复完成" : "添加 / 修复未完全成功（退出码 " + code + "）");
                    if (code != 0)
                    {
                        MessageBox.Show(this,
                            "没有完全成功。\r\n\r\n常见原因：\r\n"
                            + "  * 取消了 UAC 提权（需要管理员权限写 HKLM）\r\n"
                            + "  * 安全软件拦截（火绒等 HIPS）\r\n"
                            + "  * 右键菜单管理工具的『审核』把这一项隐藏了 —— 请在该工具里放行\r\n\r\n"
                            + "详细日志见窗口下方与 setup.log。",
                            "永久删除 · 添加/修复", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                });
        }

        private void OnRemove(object sender, EventArgs e)
        {
            if (MessageBox.Show(this, "要从右键菜单里移除『永久删除』吗？\r\n（引擎脚本默认保留，日志不会被删）",
                    "永久删除 · 移除", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2)
                != DialogResult.Yes)
            {
                return;
            }
            RunBusy("正在移除右键菜单…（可能弹一次 UAC 提权，请留意屏幕）",
                delegate { _lastCode = Commands.RunElevatedQuiet("uninstall --quiet"); },
                delegate
                {
                    int code = _lastCode;
                    ApplyStatus(GatherStatus(),
                        code == 0 ? "已移除" : "移除未完全成功（退出码 " + code + "）");
                });
        }

        private void OnTest(object sender, EventArgs e)
        {
            if (!_engine.IsDeployed())
            {
                MessageBox.Show(this, "引擎脚本还没部署，请先点『添加 / 修复右键菜单』。", "测试",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string dir = Path.Combine(Path.GetTempPath(), "pd_test_" + Guid.NewGuid().ToString("N").Substring(0, 6));
            try
            {
                Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, "测试文件.txt"), "test", Encoding.UTF8);
                string sub = Path.Combine(dir, "测试文件夹");
                Directory.CreateDirectory(sub);
                File.WriteAllText(Path.Combine(sub, "内部文件.txt"), "test", Encoding.UTF8);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "准备测试目标失败: " + ex.Message, "测试", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            SetUiEnabled(false);
            SetStatus("已弹出确认框，请在确认框里操作…（等于你右键点『永久删除』）");
            ProcessStartInfo psi = new ProcessStartInfo("wscript.exe", "\"" + AppPaths.EngineVbs + "\" \"" + dir + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            try { Process.Start(psi); }
            catch (Exception ex)
            {
                SetUiEnabled(true);
                MessageBox.Show(this, "启动引擎失败: " + ex.Message, "测试", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // 等用户处理（最多 90 秒）。用定时器轮询而不是 DoEvents 死循环：
            // 后者会把消息泵搅在一起（重入），窗口照样不跟手。
            int ticks = 0;
            Timer poll = new Timer();
            poll.Interval = 500;
            poll.Tick += delegate
            {
                ticks++;
                bool gone = !Directory.Exists(dir);
                if (!gone && ticks < 180) { return; }
                poll.Stop();
                poll.Dispose();
                SetUiEnabled(true);
                try { if (Directory.Exists(dir)) { Directory.Delete(dir, true); } } catch { }
                RunBusy("正在检测当前状态…",
                    delegate { _snapshot = GatherStatus(); },
                    delegate
                    {
                        ApplyStatus(_snapshot, gone ? "测试成功：目标已被永久删除" : "测试结束：目标仍存在（多半点了取消）");
                        MessageBox.Show(this,
                            gone ? "测试成功：弹出的确认框确认后，目标被永久删除。" : "测试结束：目标还在（你在确认框里点了取消，或超时）。",
                            "永久删除 · 测试", MessageBoxButtons.OK,
                            gone ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
                    });
            };
            poll.Start();
        }

        private void ShowEngineLog()
        {
            try
            {
                if (!File.Exists(AppPaths.DeleteLog))
                {
                    MessageBox.Show(this, "还没有删除日志：" + AppPaths.DeleteLog, "引擎日志",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                Process.Start("notepad.exe", AppPaths.DeleteLog);
            }
            catch (Exception ex) { SetStatus("打开引擎日志失败: " + ex.Message); }
        }
    }
}
