// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mxx1.cn
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace PDSetup
{
    /// <summary>
    /// 「免责声明 / 服务协议」窗口。
    ///
    /// 文本来自**仓库里的 docs\DISCLAIMER.md**（编译时以资源名 Disclaimer.md 内嵌进 exe），
    /// 所以窗口内容与仓库文档永远一致，不需要在这里再抄一份 —— 抄两份必然会分叉。
    /// 显示前做一个很轻的 Markdown 清理（去掉 # / ** / 反引号），让它在文本框里仍然好读。
    /// </summary>
    internal sealed class DisclaimerForm : Form
    {
        private const string ResourceName = "Disclaimer.md";

        /// <summary>只在内嵌资源丢失时兜底（正常构建不会走到这里）。</summary>
        private const string Fallback =
            "免责声明与服务条款\r\n\r\n"
            + "本工具按 GPL-3.0-or-later 许可「按原样」提供，不提供任何形式的担保。\r\n"
            + "它会把所选文件/文件夹直接删除（不进回收站），删除后无法恢复，请提前备份。\r\n"
            + "安装/卸载会写入 HKLM 的右键菜单注册表项，需要管理员权限。\r\n"
            + "本工具不收集任何个人数据；启动时的更新检查只访问 GitHub 公开接口，\r\n"
            + "可用环境变量 PERMDEL_NO_UPDATE=1 完全关闭。\r\n\r\n"
            + "完整内容见仓库的 docs/DISCLAIMER.md。";

        public DisclaimerForm()
        {
            Text = "免责声明与服务条款";
            ClientSize = new Size(620, 468);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            // 两个都必须 false：Min=true/Max=false 时 Win10 会在标题栏画一个灰掉的
            // 最大化方框（点了没反应），见 MainForm 里的同一处注释。
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Microsoft YaHei UI", 9F);
            Icon = SystemIcons.Application;

            TextBox body = new TextBox();
            body.Multiline = true;
            body.ReadOnly = true;
            body.ScrollBars = ScrollBars.Vertical;
            body.WordWrap = true;
            body.BackColor = Color.White;
            body.Location = new Point(12, 12);
            body.Size = new Size(596, 400);
            body.Text = LoadText().Replace("\n", "\r\n").Replace("\r\r\n", "\r\n");
            body.SelectionStart = 0;
            body.SelectionLength = 0;
            Controls.Add(body);

            // 标签与按钮同一行时必须留出横向空隙：标签压在按钮上会吃掉鼠标点击，
            // 按钮看起来就"点了没反应"（本项目踩过的坑，见 SKILL 的界面硬规则）。
            Label hint = new Label();
            hint.Text = "完整文本与仓库 docs/DISCLAIMER.md 一致（同一个文件内嵌进 exe）。";
            hint.ForeColor = Color.DimGray;
            hint.Location = new Point(12, 424);
            hint.Size = new Size(462, 22);
            Controls.Add(hint);

            Button close = new Button();
            close.Text = "我已阅读";
            close.Location = new Point(490, 418);
            close.Size = new Size(118, 30);
            close.DialogResult = DialogResult.OK;
            Controls.Add(close);
            close.BringToFront();
            CancelButton = close;
            AcceptButton = close;
        }

        /// <summary>读内嵌的 docs\DISCLAIMER.md，转成适合文本框显示的纯文本。</summary>
        internal static string LoadText()
        {
            string raw = null;
            try
            {
                Assembly asm = typeof(DisclaimerForm).Assembly;
                using (Stream s = asm.GetManifestResourceStream(ResourceName))
                {
                    if (s != null)
                    {
                        using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
                        {
                            raw = sr.ReadToEnd();
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Logger.Write("读取内嵌免责声明失败: " + ex.Message);
            }
            if (string.IsNullOrEmpty(raw)) { return Fallback; }
            return ToPlainText(raw);
        }

        /// <summary>命令行 `disclaimer` 用的就是它（不带 Markdown 记号）。</summary>
        internal static string ToPlainText(string markdown)
        {
            string[] lines = markdown.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
            List<string> outp = new List<string>();
            foreach (string lineRaw in lines)
            {
                string line = lineRaw.TrimEnd();
                string t = line.TrimStart();
                // 标题：去掉 # 记号，但保留文字（外面再加一行分隔线，视觉上仍是标题）
                int h = 0;
                while (h < t.Length && t[h] == '#') { h++; }
                if (h > 0 && h < t.Length && t[h] == ' ') { t = t.Substring(h + 1); }
                if (t.StartsWith("> ")) { t = t.Substring(2); }
                if (t.StartsWith("- ")) { t = "· " + t.Substring(2); }
                t = t.Replace("**", "").Replace("`", "");
                // Markdown 链接 [文字](地址) 还原成 "文字（地址）"
                t = System.Text.RegularExpressions.Regex.Replace(t, @"\[([^\]]+)\]\(([^)]+)\)", "$1（$2）");
                outp.Add(t);
            }
            // 连续空行压成一个
            StringBuilder sb = new StringBuilder();
            bool blank = false;
            foreach (string l in outp)
            {
                if (l.Trim().Length == 0)
                {
                    if (blank) { continue; }
                    blank = true;
                }
                else { blank = false; }
                sb.Append(l).Append("\r\n");
            }
            return sb.ToString().TrimEnd() + "\r\n";
        }
    }
}
