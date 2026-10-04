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
            // MinimizeBox 必须也是 false。实测（Win10 19045，两种组合都截图比过像素）：
            // FixedDialog 下 Min=true/Max=false 时，Windows 会在标题栏画一个**灰掉的**最大化方框，
            // 夹在最小化和关闭中间；它不可点、点了毫无反应，用户看到的就是"右上角那个不知道是什么、
            // 点它没反应的东西"。两个都关掉之后标题栏只剩一个干净的关闭按钮。
            MinimizeBox = false;
            Font = new Font("Microsoft YaHei UI", 9F);

            BuildUi();
            LoadSettingsIntoUi();
            // 首次检测同样放到后台：窗口先出来，状态栏写"正在检测…"，
            // 免得 COM 枚举还没回来时整个窗口是白屏（那是用户最容易觉得"卡住"的一刻）。
            Shown += delegate { RefreshStatusAsync("正在检测当前状态…", "就绪"); };
        }

        // ------------------------------------------------------------------ UI
        private void BuildUi()
        {
            // 布局铁律（踩过的坑）：标签的宽度只要和按钮重叠，后加进 Controls 的按钮就会
            // 被标签的背景画在身上 —— 表现是按钮"变成一块空白、点它没反应"（标签在上面把
            // 鼠标点击也吃掉了）。所以状态行的标签一律停在 _btnRefresh 左边，
            // 按钮行也一律用 LayoutButtonRow 按实测文字宽度自动排，不再手写坐标。
            GroupBox gbStatus = new GroupBox();
            gbStatus.Text = "状态";
            gbStatus.Location = new Point(12, 8);
            gbStatus.Size = new Size(736, 150);
            Controls.Add(gbStatus);

            _lblEngine = MakeLabel(gbStatus, 16, 22, 700);
            _lblRegistry = MakeLabel(gbStatus, 16, 46, 700);
            _lblVisible = MakeLabel(gbStatus, 16, 70, 700);
            _lblFlags = MakeLabel(gbStatus, 16, 94, 700);

            _btnRefresh = new Button();
            _btnRefresh.Text = "重新检测";
            _btnRefresh.Location = new Point(608, 116);
            _btnRefresh.Size = new Size(124, 28);
            _btnRefresh.Click += delegate { RefreshStatusAsync("正在重新检测…", "已重新检测"); };
            gbStatus.Controls.Add(_btnRefresh);
            _btnRefresh.BringToFront();

            Label hint = new Label();
            hint.Text = "可见性由系统 Shell 实测枚举，不是只看注册表。";
            hint.ForeColor = Color.DimGray;
            hint.Location = new Point(16, 121);
            hint.Size = new Size(520, 20);
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

            _btnInstall = MakeButton(gbAct, "添加 / 修复右键菜单");
            _btnInstall.Click += OnInstall;

            _btnRemove = MakeButton(gbAct, "移除右键菜单");
            _btnRemove.Click += OnRemove;

            _btnTest = MakeButton(gbAct, "测试一下");
            // Tag 里放"按钮在忙时显示的备用文字"：排版时按两个文字里更宽的那个留位，
            // 这样忙碌时改标题不会把按钮撑变形、也不会把字裁掉。
            _btnTest.Tag = "等待确认框…";
            _btnTest.Click += OnTest;

            _btnOpen = MakeButton(gbAct, "打开日志目录");
            _btnOpen.Click += delegate
            {
                try { Directory.CreateDirectory(AppPaths.AppRoot); Process.Start("explorer.exe", AppPaths.AppRoot); }
                catch (Exception ex) { SetStatus("打开目录失败: " + ex.Message); }
            };

            _btnRefresh2 = MakeButton(gbAct, "查看引擎日志");
            _btnRefresh2.Click += delegate { ShowEngineLog(); };

            // 按文字实测宽度自动排，间隙自适应 —— 手写坐标时"打开日志目录"的右边界
            // 曾经压到"查看引擎日志"身上 16px，两个按钮糊在一起。
            LayoutButtonRow(gbAct, 16, 26, 728, 32, _btnInstall, _btnRemove, _btnTest, _btnOpen, _btnRefresh2);

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

        private static Label MakeLabel(Control parent, int x, int y, int w)
        {
            Label l = new Label();
            l.Location = new Point(x, y);
            l.Size = new Size(w, 20);
            l.AutoEllipsis = true;      // 文字太长时给 "..."，不要硬切成一截
            l.Text = "";
            parent.Controls.Add(l);
            return l;
        }

        private static Button MakeButton(Control parent, string text)
        {
            Button b = new Button();
            b.Text = text;
            b.Size = new Size(96, 32);   // 真实尺寸交给 LayoutButtonRow 按文字算
            parent.Controls.Add(b);
            return b;
        }

        /// <summary>
        /// 按钮行自动排版：按实测文字宽度定每个按钮的宽，间隙自适应，整体居中。
        /// 这样"改文案"或"加功能"都不会再出现重叠/裁字（手写坐标时踩过两次）。
        /// 按钮 Tag 里若放了备用文案，则按两者中更宽的留位（忙碌时改标题也不会变形）。
        /// </summary>
        private static void LayoutButtonRow(Control parent, int left, int y, int right, int height, params Button[] buttons)
        {
            int avail = right - left;
            int[] w = new int[buttons.Length];
            int sum = 0;
            for (int i = 0; i < buttons.Length; i++)
            {
                int m = TextRenderer.MeasureText(buttons[i].Text, buttons[i].Font).Width;
                string alt = buttons[i].Tag as string;
                if (!string.IsNullOrEmpty(alt))
                {
                    m = Math.Max(m, TextRenderer.MeasureText(alt, buttons[i].Font).Width);
                }
                w[i] = Math.Max(74, m + 30);
                sum += w[i];
            }

            int gap = buttons.Length > 1 ? (avail - sum) / (buttons.Length - 1) : 0;
            if (gap > 34) { gap = 34; }
            if (gap < 6) { gap = 6; }
            int total = sum + gap * (buttons.Length - 1);
            int cx = left + Math.Max(0, (avail - total) / 2);

            for (int i = 0; i < buttons.Length; i++)
            {
                buttons[i].Location = new Point(cx, y);
                buttons[i].Size = new Size(w[i], height);
                buttons[i].BringToFront();   // 别让先加的标签盖住按钮（点击会被标签吃掉）
                cx += w[i] + gap;
            }
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
        private void RefreshStatusAsync(string busyText, string doneNote)
        {
            RunBusy(busyText, delegate { _snapshot = GatherStatus(); },
                delegate { ApplyStatus(_snapshot, doneNote); });
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

        // ------------------------------------------------------------------ 测试
        // 测试的难点是"怎么知道用户已经把确认框关掉了"。以前靠轮询目标目录是否消失，
        // 于是"点了取消"就只能等 90 秒超时 —— 界面就一直灰着（用户报的第一个问题）。
        // 现在用引擎自己持有的单实例互斥体当信号：互斥体对象在 ⇒ 引擎进程还活着 ⇒ 框还开着；
        // 用户一答完（确定或取消），引擎收尾退出，互斥体消失，这里立刻恢复界面。
        private Timer _testTimer;
        private string _testDir;
        private int _testTicks;
        private bool _testSawAgent;

        /// <summary>
        /// 引擎主实例是否还活着。只看"互斥体对象在不在"，不去 WaitOne：
        /// 抢一下再放会让真正要启动的引擎误判成"已有实例"而把手里的路径转交出去。
        /// </summary>
        private static bool AgentRunning()
        {
            System.Threading.Mutex m = null;
            try
            {
                m = System.Threading.Mutex.OpenExisting(@"Local\PermanentDelete.Agent");
                return true;
            }
            catch (System.Threading.WaitHandleCannotBeOpenedException) { return false; }   // 对象不存在 = 没在跑
            catch { return false; }
            finally { if (m != null) { try { m.Dispose(); } catch { } } }
        }

        /// <summary>测试期间的"半忙碌"：只锁住测试按钮本身，其它按钮照常可用。</summary>
        private void SetTestRunning(bool running)
        {
            _btnTest.Enabled = !running;
            _btnTest.Text = running ? (string)_btnTest.Tag : "测试一下";
            if (running)
            {
                _progress.Visible = true;
                Cursor = Cursors.AppStarting;
            }
            else if (_busy == 0)
            {
                _progress.Visible = false;
                Cursor = Cursors.Default;
            }
        }

        private void StopTestWatch()
        {
            if (_testTimer != null)
            {
                _testTimer.Stop();
                _testTimer.Dispose();
                _testTimer = null;
            }
            _testTicks = 0;
            _testSawAgent = false;
            _testDir = null;
            SetTestRunning(false);
        }

        private void OnTest(object sender, EventArgs e)
        {
            if (_testTimer != null) { SetStatus("已经有一个确认框在等你了，先在框里选一个。"); return; }

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

            ProcessStartInfo psi = new ProcessStartInfo("wscript.exe", "\"" + AppPaths.EngineVbs + "\" \"" + dir + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            try { Process.Start(psi); }
            catch (Exception ex)
            {
                MessageBox.Show(this, "启动引擎失败: " + ex.Message, "测试", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            _testDir = dir;
            _testTicks = 0;
            _testSawAgent = false;
            SetTestRunning(true);
            SetStatus("确认框已弹出：请在框里选择（确定或取消），选完这里会自动恢复…");

            // 250ms 轮询：用户一关框，最多半秒界面就恢复
            _testTimer = new Timer();
            _testTimer.Interval = 250;
            _testTimer.Tick += delegate { TestTick(); };
            _testTimer.Start();
        }

        private void TestTick()
        {
            _testTicks++;
            bool alive = AgentRunning();
            if (alive) { _testSawAgent = true; }

            // 判定顺序很讲究：
            //   引擎还活着 → 框还开着，继续等（除非已经等满 10 分钟，别把按钮永久锁死）
            //   引擎没了、可从没见过它 → 多半是启动就失败/被拦，再给 8 秒观察期
            //   其它情况 → 用户已经答完了（确定或取消），马上收尾恢复界面
            if (alive && _testTicks < 2400) { return; }
            if (!alive && !_testSawAgent && _testTicks < 32) { return; }

            bool started = _testSawAgent;
            bool timedOut = _testTicks >= 2400;
            string dir = _testDir;
            StopTestWatch();
            bool gone = dir != null && !Directory.Exists(dir);
            try { if (dir != null && Directory.Exists(dir)) { Directory.Delete(dir, true); } } catch { }

            string note;
            string msg;
            MessageBoxIcon icon;
            if (!started)
            {
                note = "测试没跑起来：没等到引擎进程";
                msg = "没等到引擎进程。常见原因：安全软件拦截了 wscript/powershell，或者引擎脚本没部署好。\r\n\r\n"
                    + "换个办法验证：随便找个文件，右键看有没有『永久删除（不进回收站）』。";
                icon = MessageBoxIcon.Warning;
            }
            else if (timedOut)
            {
                note = "测试超时：确认框一直没被处理";
                msg = "等了 10 分钟也没等到你在确认框上做选择，测试先收尾了（界面已恢复）。";
                icon = MessageBoxIcon.Warning;
            }
            else if (gone)
            {
                note = "测试成功：确认框里点确定后，目标被永久删除";
                msg = "测试成功：确认框里点『永久删除』之后，目标真的被删掉了。";
                icon = MessageBoxIcon.Information;
            }
            else
            {
                note = "测试结束：点了取消，什么都还在";
                msg = "你点了取消 —— 目标原封不动地留着（这正说明确认框是管用的）。";
                icon = MessageBoxIcon.Information;
            }

            string finalNote = note;
            string finalMsg = msg;
            MessageBoxIcon finalIcon = icon;
            RunBusy("正在检测当前状态…",
                delegate { _snapshot = GatherStatus(); },
                delegate
                {
                    ApplyStatus(_snapshot, finalNote);
                    MessageBox.Show(this, finalMsg, "永久删除 · 测试", MessageBoxButtons.OK, finalIcon);
                });
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
