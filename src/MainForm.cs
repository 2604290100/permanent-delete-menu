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
        private StatusStrip _statusStrip;
        private ToolStripStatusLabel _statusLabel;

        private readonly IEngine _engine = new PowerShellVbsEngine();

        public MainForm()
        {
            Text = "永久删除 · 右键菜单管理";
            ClientSize = new Size(760, 580);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            Font = new Font("Microsoft YaHei UI", 9F);

            BuildUi();
            LoadSettingsIntoUi();
            RefreshStatus("就绪");
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
            _btnRefresh.Click += delegate { RefreshStatus("已重新检测"); };
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

            _btnRefresh2 = MakeButton(gbAct, "查看引擎日志", 640, 26, 84);
            _btnRefresh2.Click += delegate { ShowEngineLog(); };

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
        private void RefreshStatus(string note)
        {
            try
            {
                SetupSettings s = SetupSettings.Load();
                MenuStatus st = MenuRegistry.GetStatus();
                bool engineOk = _engine.IsDeployed();

                _lblEngine.Text = "引擎脚本：" + (engineOk ? "已部署" : "未部署")
                    + "   " + AppPaths.EnginePs1;
                _lblEngine.ForeColor = engineOk ? Color.FromArgb(0, 100, 0) : Color.FromArgb(180, 0, 0);

                _lblRegistry.Text = "注册表：" + (st.Installed ? "已安装  " + AppPaths.VerbHklmDisplay : "未安装")
                    + (st.StaleKeys.Count > 0 ? "   ⚠ 存在历史注册项 " + st.StaleKeys.Count + " 个" : "");
                _lblRegistry.ForeColor = st.Installed ? Color.FromArgb(0, 100, 0) : Color.FromArgb(120, 120, 120);

                bool extendedOnly = st.Installed ? st.ExtendedOnly : s.ExtendedOnly;
                VisibilityResult v = ShellVerify.Check(st.Installed ? st.MenuText : s.MenuText, extendedOnly);
                if (v.Visible)
                {
                    _lblVisible.Text = "菜单可见性：文件 ✓  文件夹 ✓";
                    _lblVisible.ForeColor = Color.FromArgb(0, 100, 0);
                }
                else if (extendedOnly && st.Installed)
                {
                    // 勾了「仅 Shift 显示」时枚举必然为空 —— 这不是故障，别显示成红的
                    _lblVisible.Text = "菜单可见性：仅 Shift 显示（按住 Shift 右键可见）";
                    _lblVisible.ForeColor = Color.FromArgb(0, 100, 0);
                }
                else
                {
                    _lblVisible.Text = "菜单可见性：" + v.Detail;
                    _lblVisible.ForeColor = v.Ok ? Color.FromArgb(0, 100, 0) : Color.FromArgb(180, 0, 0);
                }

                _lblFlags.Text = st.HideFlags.Count == 0
                    ? "隐藏标志：无"
                    : "隐藏标志：" + string.Join(" / ", st.HideFlags.ToArray()) + "   → 菜单会看不到，点『添加 / 修复』清除";
                _lblFlags.ForeColor = st.HideFlags.Count == 0 ? Color.FromArgb(0, 100, 0) : Color.FromArgb(180, 0, 0);

                _txtLog.Text = Logger.Tail(60);
                SetStatus(note);
            }
            catch (Exception ex)
            {
                SetStatus("检测失败: " + ex.Message);
            }
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
            Cursor = Cursors.WaitCursor;
            try
            {
                int code = Commands.RunElevatedQuiet("install --quiet");
                RefreshStatus(code == 0 ? "添加/修复完成" : "添加/修复未完全成功（退出码 " + code + (code == 5 ? "，可能是取消了 UAC" : "") + "）");
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
            }
            finally { Cursor = Cursors.Default; }
        }

        private void OnRemove(object sender, EventArgs e)
        {
            if (MessageBox.Show(this, "要从右键菜单里移除『永久删除』吗？\r\n（引擎脚本默认保留，日志不会被删）",
                    "永久删除 · 移除", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2)
                != DialogResult.Yes)
            {
                return;
            }
            Cursor = Cursors.WaitCursor;
            try
            {
                int code = Commands.RunElevatedQuiet("uninstall --quiet");
                RefreshStatus(code == 0 ? "已移除" : "移除未完全成功（退出码 " + code + "）");
            }
            finally { Cursor = Cursors.Default; }
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

            SetStatus("已弹出确认框，请在确认框里操作…（等于你右键点『永久删除』）");
            ProcessStartInfo psi = new ProcessStartInfo("wscript.exe", "\"" + AppPaths.EngineVbs + "\" \"" + dir + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            try { Process.Start(psi); }
            catch (Exception ex)
            {
                MessageBox.Show(this, "启动引擎失败: " + ex.Message, "测试", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // 等用户处理（最多 90 秒），期间保持界面响应
            bool deleted = false;
            for (int i = 0; i < 90; i++)
            {
                Application.DoEvents();
                System.Threading.Thread.Sleep(1000);
                if (!Directory.Exists(dir)) { deleted = true; break; }
            }

            RefreshStatus(deleted ? "测试成功：目标已被永久删除" : "测试结束：目标仍存在（多半点了取消）");
            try { if (Directory.Exists(dir)) { Directory.Delete(dir, true); } } catch { }
            MessageBox.Show(this,
                deleted ? "测试成功：弹出的确认框确认后，目标被永久删除。" : "测试结束：目标还在（你在确认框里点了取消，或超时）。",
                "永久删除 · 测试", MessageBoxButtons.OK,
                deleted ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
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
