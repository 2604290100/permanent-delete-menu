// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mxx1.cn
using System;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace PDSetup
{
    /// <summary>
    /// 「关于」窗口：作者、版本、许可证、仓库地址、更新检查。
    /// 界面上任何"作者信息"都从这里取，不要在别处硬编码字符串。
    /// </summary>
    internal sealed class AboutForm : Form
    {
        /// <summary>界面上显示的署名（简短形式）。</summary>
        internal const string AuthorName = "mxx1";
        /// <summary>署名对应的站点地址（完整域名）。</summary>
        internal const string AuthorSite = "mxx1.cn";
        internal const string AuthorUrl  = "https://mxx1.cn";
        internal const string RepoUrl    = "https://github.com/2604290100/permanent-delete-menu";
        internal const string License    = "GPL-3.0-or-later";

        private readonly string _version;

        private LinkLabel _linkUpdate;
        private Button _btnCheck;
        /// <summary>更新检查的兜底轮询：万一回调没回来，界面也不会永远停在"正在检查…"。</summary>
        private Timer _poll;
        private int _pollTries;

        public AboutForm(string version, string engineId)
        {
            _version = version;

            Text = "关于 · 永久删除 右键菜单管理";
            ClientSize = new Size(460, 300);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            // 两个都必须关：Min 开 + Max 关时，Win10 会在标题栏画一个灰掉的
            // 最大化方框（点了毫无反应），见 MainForm 里的同一处注释。
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Microsoft YaHei UI", 9F);
            Icon = SystemIcons.Application;

            Label title = new Label();
            title.Text = "永久删除 · 右键菜单管理";
            title.Font = new Font("Microsoft YaHei UI", 12F, FontStyle.Bold);
            title.Location = new Point(18, 16);
            title.Size = new Size(420, 28);
            Controls.Add(title);

            Label ver = new Label();
            ver.Text = "版本 v" + version + "    引擎 " + engineId;
            ver.Location = new Point(20, 48);
            ver.Size = new Size(420, 20);
            Controls.Add(ver);

            Label desc = new Label();
            desc.Text = "一键添加 / 移除资源管理器右键菜单「永久删除（不进回收站）」。\r\n"
                + "菜单到底可不可见是用系统 Shell 实测枚举出来的，不是只看注册表。";
            desc.ForeColor = Color.DimGray;
            desc.Location = new Point(20, 72);
            desc.Size = new Size(424, 40);
            Controls.Add(desc);

            Label line = new Label();
            line.BorderStyle = BorderStyle.Fixed3D;
            line.Location = new Point(20, 120);
            line.Size = new Size(420, 2);
            Controls.Add(line);

            Label by = new Label();
            by.Text = "作者：";
            by.Location = new Point(20, 134);
            by.Size = new Size(44, 22);
            Controls.Add(by);

            // 署名显示简称 mxx1，后面跟上完整站点域名（同一个链接）——
            // 既符合"界面上只用 mxx1"的要求，也不丢掉可点的网址。
            LinkLabel authorLink = new LinkLabel();
            authorLink.Text = AuthorName + "　·　" + AuthorSite;
            authorLink.Location = new Point(64, 134);
            authorLink.Size = new Size(240, 22);
            authorLink.LinkClicked += delegate { OpenUrl(AuthorUrl); };
            Controls.Add(authorLink);

            Label lic = new Label();
            lic.Text = "许可证：" + License + "（可自由使用/修改/商用，再分发须开源）";
            lic.Location = new Point(20, 160);
            lic.Size = new Size(424, 22);
            Controls.Add(lic);

            Label repo = new Label();
            repo.Text = "仓库：";
            repo.Location = new Point(20, 186);
            repo.Size = new Size(44, 22);
            Controls.Add(repo);

            LinkLabel repoLink = new LinkLabel();
            repoLink.Text = RepoUrl;
            repoLink.Location = new Point(64, 186);
            repoLink.Size = new Size(380, 22);
            repoLink.LinkClicked += delegate { OpenUrl(RepoUrl); };
            Controls.Add(repoLink);

            // ---- 更新检查行：标签停在按钮左边，绝不和按钮重叠（重叠会吃掉按钮的点击）
            Label upd = new Label();
            upd.Text = "更新：";
            upd.Location = new Point(20, 212);
            upd.Size = new Size(44, 22);
            Controls.Add(upd);

            _linkUpdate = new LinkLabel();
            _linkUpdate.Location = new Point(64, 212);
            _linkUpdate.Size = new Size(262, 22);
            _linkUpdate.AutoEllipsis = true;   // 文字长了给省略号，不要截断成半句话
            _linkUpdate.LinkArea = new LinkArea(0, 0);   // 默认不可点
            _linkUpdate.LinkClicked += delegate
            {
                UpdateResult r = UpdateCheck.Last;
                if (r != null && r.State == UpdateState.Available && r.Url.Length > 0)
                {
                    OpenUrl(r.Url);
                }
            };
            Controls.Add(_linkUpdate);

            _btnCheck = new Button();
            _btnCheck.Text = "检查更新";
            _btnCheck.Location = new Point(336, 208);
            _btnCheck.Size = new Size(104, 26);
            _btnCheck.Click += delegate { StartCheck(true); };
            Controls.Add(_btnCheck);
            _btnCheck.BringToFront();

            Button terms = new Button();
            terms.Text = "免责声明 / 服务协议";
            terms.Location = new Point(20, 250);
            terms.Size = new Size(170, 30);
            terms.Click += delegate
            {
                using (DisclaimerForm d = new DisclaimerForm()) { d.ShowDialog(this); }
            };
            Controls.Add(terms);
            terms.BringToFront();

            Button close = new Button();
            close.Text = "关闭";
            close.Location = new Point(330, 250);
            close.Size = new Size(110, 30);
            close.DialogResult = DialogResult.OK;
            Controls.Add(close);
            close.BringToFront();
            CancelButton = close;
            AcceptButton = close;

            _poll = new Timer();
            _poll.Interval = 500;
            _poll.Tick += delegate { PollUpdate(); };

            // 打开窗口先显示缓存结果；没查过就顺手查一次（后台线程，绝不卡界面）。
            Shown += delegate
            {
                UpdateResult cached = UpdateCheck.Last;
                if (cached != null && cached.State != UpdateState.Unknown && cached.State != UpdateState.Checking)
                {
                    ShowResult(cached);
                }
                else
                {
                    StartCheck(false);
                }
            };
        }

        /// <summary>force=true 是用户点了「检查更新」，false 是窗口打开时的顺手一查。</summary>
        private void StartCheck(bool force)
        {
            if (UpdateCheck.Disabled)
            {
                UpdateResult d = new UpdateResult();
                d.State = UpdateState.Disabled;
                d.Current = _version;
                ShowResult(d);
                return;
            }

            _btnCheck.Enabled = false;
            _linkUpdate.Text = "正在检查…";
            _linkUpdate.LinkArea = new LinkArea(0, 0);
            // 兜底轮询：即使回调因为任何原因没回来（例如同时有别的检查在跑），
            // 这里也会在结果落定或超时后把那一行刷成真实状态，绝不会永远停在"正在检查…"。
            _pollTries = 0;
            _poll.Start();
            UpdateResult busy = new UpdateResult();
            busy.State = UpdateState.Checking;
            busy.Current = _version;

            UpdateCheck.CheckAsync(_version, delegate(UpdateResult r)
            {
                // 回调在线程池线程上 —— 必须回 UI 线程再碰控件
                try
                {
                    if (IsDisposed) { return; }
                    BeginInvoke((MethodInvoker)delegate
                    {
                        if (IsDisposed) { return; }
                        _btnCheck.Enabled = true;
                        ShowResult(r);
                    });
                }
                catch (Exception) { }
            });
        }

        private void ShowResult(UpdateResult r)
        {
            if (r == null) { return; }
            _poll.Stop();
            _linkUpdate.Text = r.UiText;
            bool canDownload = r.State == UpdateState.Available && r.Url.Length > 0;
            _linkUpdate.LinkArea = canDownload
                ? new LinkArea(0, _linkUpdate.Text.Length)
                : new LinkArea(0, 0);
            _linkUpdate.ForeColor = r.State == UpdateState.Available
                ? Color.FromArgb(0, 90, 180)
                : Color.DimGray;
            _btnCheck.Enabled = true;
        }

        /// <summary>每 500ms 看一眼有没有结果；20 秒还没有就如实显示成"超时"。</summary>
        private void PollUpdate()
        {
            UpdateResult cached = UpdateCheck.Last;
            if (cached != null && cached.State != UpdateState.Unknown && cached.State != UpdateState.Checking)
            {
                ShowResult(cached);
                return;
            }
            _pollTries++;
            if (_pollTries > 40)
            {
                UpdateResult t = new UpdateResult();
                t.State = UpdateState.Failed;
                t.Current = _version;
                t.Detail = "timeout";
                ShowResult(t);
            }
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            if (_poll != null) { _poll.Stop(); _poll.Dispose(); _poll = null; }
            base.OnFormClosed(e);
        }

        private void OpenUrl(string url)
        {
            try { Process.Start(url); }
            catch (Exception ex)
            {
                MessageBox.Show(this, "打不开浏览器：" + ex.Message + "\r\n\r\n地址：" + url,
                    "关于", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }
    }
}
