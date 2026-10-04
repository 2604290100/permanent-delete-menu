// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mxx1.cn
using System;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace PDSetup
{
    /// <summary>
    /// 「关于」窗口：作者、版本、许可证、仓库地址。
    /// 界面上任何"作者信息"都从这里取，不要在别处硬编码字符串。
    /// </summary>
    internal sealed class AboutForm : Form
    {
        internal const string AuthorName = "mxx1.cn";
        internal const string AuthorUrl  = "https://mxx1.cn";
        internal const string RepoUrl    = "https://github.com/2604290100/permanent-delete-menu";
        internal const string License    = "GPL-3.0-or-later";

        public AboutForm(string version, string engineId)
        {
            Text = "关于 · 永久删除 右键菜单管理";
            ClientSize = new Size(460, 268);
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

            LinkLabel authorLink = new LinkLabel();
            authorLink.Text = AuthorName;
            authorLink.Location = new Point(64, 134);
            authorLink.Size = new Size(120, 22);
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

            Button visit = new Button();
            visit.Text = "访问 " + AuthorName;
            visit.Location = new Point(180, 222);
            visit.Size = new Size(140, 30);
            visit.Click += delegate { OpenUrl(AuthorUrl); };
            Controls.Add(visit);

            Button close = new Button();
            close.Text = "关闭";
            close.Location = new Point(330, 222);
            close.Size = new Size(110, 30);
            close.DialogResult = DialogResult.OK;
            Controls.Add(close);
            CancelButton = close;
            AcceptButton = close;
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
