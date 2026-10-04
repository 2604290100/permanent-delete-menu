// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mxx1.cn
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace PDSetup
{
    internal sealed class Options
    {
        public string Command = "";
        public bool Quiet;
        public bool Elevated;
        public bool HasExtendedOpt;
        public bool Extended;
        public string MenuText = null;
        public List<string> Raw = new List<string>();

        public static Options Parse(string[] args)
        {
            Options o = new Options();
            foreach (string a in args)
            {
                string t = a.Trim();
                o.Raw.Add(t);
                if (t.Length == 0) { continue; }
                string low = t.ToLowerInvariant();
                if (low == "--quiet" || low == "-q") { o.Quiet = true; continue; }
                if (low == "--elevated") { o.Elevated = true; continue; }
                if (low == "--extended") { o.HasExtendedOpt = true; o.Extended = true; continue; }
                if (low == "--no-extended") { o.HasExtendedOpt = true; o.Extended = false; continue; }
                if (low.StartsWith("--menu-text=")) { o.MenuText = t.Substring("--menu-text=".Length).Trim('"'); continue; }
                if (low.StartsWith("--") || low.StartsWith("/")) { /* 未知开关：忽略，交给 help */ }
                if (o.Command.Length == 0 && !low.StartsWith("-")) { o.Command = low; continue; }
            }
            return o;
        }

        /// <summary>把原始参数重新拼成命令行，用于提权重启自己。</summary>
        public string ToArgs(string extra)
        {
            StringBuilder sb = new StringBuilder();
            foreach (string r in Raw)
            {
                if (r.Length == 0) { continue; }
                if (r.IndexOf(' ') >= 0) { sb.Append('"').Append(r).Append('"'); }
                else { sb.Append(r); }
                sb.Append(' ');
            }
            sb.Append(extra);
            return sb.ToString().Trim();
        }
    }

    internal static class Commands
    {
        public static int Run(Options o)
        {
            switch (o.Command)
            {
                case "install": return Install(o);
                case "uninstall": return Uninstall(o);
                case "status": return StatusCommand(o);
                case "verify": return VerifyCommand(o);
                case "help":
                case "?":
                case "h": return Help();
                default:
                    Console.WriteLine("unknown-command=" + o.Command);
                    Help();
                    return 2;
            }
        }

        // ---------------------------------------------------------------- install
        public static int Install(Options o)
        {
            int? child = ElevateIfNeeded(o);
            if (child.HasValue) { return child.Value; }

            SetupSettings s = SetupSettings.Load();
            if (o.HasExtendedOpt) { s.ExtendedOnly = o.Extended; }
            if (!string.IsNullOrEmpty(o.MenuText)) { s.MenuText = o.MenuText; }
            s.Save();

            List<string> log = new List<string>();
            IEngine engine = new PowerShellVbsEngine();
            bool ok = engine.Deploy(log);
            ok = MenuRegistry.Install(s, engine, log) && ok;

            Native.NotifyShellChanged();
            System.Threading.Thread.Sleep(700);

            VisibilityResult v = CheckVisibility(s.MenuText, s.ExtendedOnly);

            Console.WriteLine("action=install");
            Console.WriteLine("engine=" + engine.Id);
            Console.WriteLine("engineDeployed=" + Bool(engine.IsDeployed()));
            Console.WriteLine("menuText=" + s.MenuText);
            Console.WriteLine("extendedOnly=" + Bool(s.ExtendedOnly));
            Console.WriteLine("fileVisible=" + Bool(v.FileVisible));
            Console.WriteLine("folderVisible=" + Bool(v.FolderVisible));
            Console.WriteLine("visibleByDesign=" + Bool(v.ExtendedByDesign));
            Console.WriteLine("verifyDetail=" + v.Detail);
            Console.WriteLine("result=" + ((ok && v.Ok) ? "ok" : "problem"));

            // 明细必须落到日志文件里：GUI 走的是 --quiet（没有控制台），
            // 出问题时只能靠 setup.log 复盘。
            foreach (string line in log) { Logger.Write("  install: " + line); }

            if (!o.Quiet)
            {
                Console.WriteLine("--- 详细 ---");
                foreach (string line in log) { Console.WriteLine(line); }
                if (!v.Ok)
                {
                    Console.WriteLine("提示: 若菜单里看不到，多半被『右键菜单管理工具（审核）』隐藏了；");
                    Console.WriteLine("      本工具已自动清除隐藏标志，如仍不可见请在该工具里放行这一项。");
                }
            }
            Logger.Write("install result=" + ((ok && v.Ok) ? "ok" : "problem")
                + " file=" + v.FileVisible + " folder=" + v.FolderVisible
                + " extendedOnly=" + s.ExtendedOnly + " byDesign=" + v.ExtendedByDesign);
            return (ok && v.Ok) ? 0 : 1;
        }

        // ---------------------------------------------------------------- uninstall
        public static int Uninstall(Options o)
        {
            int? child = ElevateIfNeeded(o);
            if (child.HasValue) { return child.Value; }

            SetupSettings s = SetupSettings.Load();
            List<string> log = new List<string>();
            IEngine engine = new PowerShellVbsEngine();
            bool ok = MenuRegistry.Uninstall(s, engine, log);

            Native.NotifyShellChanged();
            System.Threading.Thread.Sleep(700);
            VisibilityResult v = CheckVisibility(s.MenuText, false);   // 卸载后本来就该看不见

            Console.WriteLine("action=uninstall");
            Console.WriteLine("installed=" + Bool(MenuRegistry.GetStatus().Installed));
            Console.WriteLine("fileVisible=" + Bool(v.FileVisible));
            Console.WriteLine("folderVisible=" + Bool(v.FolderVisible));
            Console.WriteLine("result=" + (ok ? "ok" : "problem"));
            foreach (string line in log) { Logger.Write("  uninstall: " + line); }
            if (!o.Quiet)
            {
                Console.WriteLine("--- 详细 ---");
                foreach (string line in log) { Console.WriteLine(line); }
            }
            Logger.Write("uninstall result=" + (ok ? "ok" : "problem"));
            return ok ? 0 : 1;
        }

        // ---------------------------------------------------------------- status / verify
        public static int StatusCommand(Options o)
        {
            string text = BuildStatusText();
            Console.Write(text);
            return text.IndexOf("installed=true", StringComparison.OrdinalIgnoreCase) >= 0 ? 0 : 1;
        }

        public static int VerifyCommand(Options o)
        {
            SetupSettings s = SetupSettings.Load();
            MenuStatus st = MenuRegistry.GetStatus();
            VisibilityResult v = CheckVisibility(s.MenuText, st.Installed ? st.ExtendedOnly : s.ExtendedOnly);
            Console.WriteLine("fileVisible=" + Bool(v.FileVisible));
            Console.WriteLine("folderVisible=" + Bool(v.FolderVisible));
            Console.WriteLine("extendedOnly=" + Bool(v.ExtendedOnly));
            Console.WriteLine("visibleByDesign=" + Bool(v.ExtendedByDesign));
            Console.WriteLine("verifyDetail=" + v.Detail);
            return v.Ok ? 0 : 1;
        }

        /// <summary>key=value 形态的状态文本 —— GUI、测试脚本、命令行共用同一份事实。</summary>
        public static string BuildStatusText()
        {
            SetupSettings s = SetupSettings.Load();
            MenuStatus st = MenuRegistry.GetStatus();
            IEngine engine = new PowerShellVbsEngine();
            bool extendedOnly = st.Installed ? st.ExtendedOnly : s.ExtendedOnly;
            VisibilityResult v = CheckVisibility(st.Installed ? st.MenuText : s.MenuText, extendedOnly);

            StringBuilder sb = new StringBuilder();
            sb.AppendLine("installed=" + Bool(st.Installed));
            sb.AppendLine("engine=" + engine.Id);
            sb.AppendLine("engineDeployed=" + Bool(engine.IsDeployed()));
            sb.AppendLine("menuText=" + (st.Installed ? st.MenuText : s.MenuText));
            sb.AppendLine("extendedOnly=" + Bool(st.Installed ? st.ExtendedOnly : s.ExtendedOnly));
            sb.AppendLine("multiSelectModel=" + st.MultiSelectModel);
            sb.AppendLine("command=" + st.Command);
            sb.AppendLine("hideFlags=" + Join(st.HideFlags));
            sb.AppendLine("staleKeys=" + Join(st.StaleKeys));
            sb.AppendLine("fileVisible=" + Bool(v.FileVisible));
            sb.AppendLine("folderVisible=" + Bool(v.FolderVisible));
            sb.AppendLine("visibleByDesign=" + Bool(v.ExtendedByDesign));
            sb.AppendLine("verifyDetail=" + v.Detail);
            sb.AppendLine("settingsFile=" + AppPaths.SettingsFile);
            sb.AppendLine("enginePs1=" + AppPaths.EnginePs1);
            sb.AppendLine("engineVbs=" + AppPaths.EngineVbs);
            return sb.ToString();
        }

        // ---------------------------------------------------------------- 提权
        private static int? ElevateIfNeeded(Options o)
        {
            if (AppPaths.IsAdmin) { return null; }
            if (o.Elevated)
            {
                Console.Error.WriteLine("elevation-failed=true");
                return 5;
            }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = AppPaths.ExePath;
                psi.Arguments = o.ToArgs("--elevated");
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    int code = p.ExitCode;
                    Console.WriteLine("elevatedChild=true exit=" + code);
                    Logger.Write("elevated child finished exit=" + code);
                    return code;
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("uac-cancelled=true " + ex.Message);
                Logger.Write("elevation-cancelled " + ex.Message);
                return 5;
            }
        }

        /// <summary>给 GUI 用：以管理员身份跑一个 --quiet 子命令，返回退出码。</summary>
        public static int RunElevatedQuiet(string args)
        {
            if (AppPaths.IsAdmin)
            {
                Options o = Options.Parse(args.Split(' '));
                return Run(o);
            }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = AppPaths.ExePath;
                psi.Arguments = args + " --elevated";
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    return p.ExitCode;
                }
            }
            catch (Exception ex)
            {
                Logger.Write("gui-elevation-cancelled " + ex.Message);
                return 5;
            }
        }

        // ---------------------------------------------------------------- 工具
        private static VisibilityResult CheckVisibility(string menuText, bool extendedOnly)
        {
            VisibilityResult v = ShellVerify.Check(menuText, extendedOnly);
            if (!v.Ok && !string.IsNullOrEmpty(menuText))
            {
                // 菜单文字被自定义过时，再用产品名兜一次
                VisibilityResult alt = ShellVerify.Check("永久删除", extendedOnly);
                if (alt.Ok) { alt.Detail = alt.Detail + "（按菜单文字未匹配，按产品名匹配到）"; return alt; }
            }
            // 「仅 Shift 显示」时枚举必然为空 —— 这不是故障。
            // 判据是注册表本身正常（键在、命令对），此时按预期放行，
            // 否则用户一勾这个选项，『添加 / 修复』就会报"未完全成功"，纯属误报。
            if (!v.Ok && extendedOnly && MenuRegistry.GetStatus().Installed)
            {
                v.ExtendedByDesign = true;
                v.Detail = v.Detail + "；注册表正常，判定为预期（按住 Shift 右键即可看到）";
            }
            return v;
        }

        private static string Bool(bool b) { return b ? "true" : "false"; }

        private static string Join(List<string> items)
        {
            if (items == null || items.Count == 0) { return ""; }
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < items.Count; i++)
            {
                if (i > 0) { sb.Append(','); }
                sb.Append(items[i]);
            }
            return sb.ToString();
        }

        public static int Help()
        {
            Console.WriteLine("PermanentDeleteSetup —— 右键菜单『永久删除（不进回收站）』一键添加/移除");
            Console.WriteLine("");
            Console.WriteLine("用法:");
            Console.WriteLine("  PermanentDeleteSetup.exe                       启动图形界面（推荐）");
            Console.WriteLine("  PermanentDeleteSetup.exe status                输出状态（key=value，含可见性自检）");
            Console.WriteLine("  PermanentDeleteSetup.exe verify                只做菜单可见性自检");
            Console.WriteLine("  PermanentDeleteSetup.exe install [--quiet] [--extended] [--menu-text=文字]");
            Console.WriteLine("  PermanentDeleteSetup.exe uninstall [--quiet]");
            Console.WriteLine("");
            Console.WriteLine("说明:");
            Console.WriteLine("  * 写入 HKLM\\SOFTWARE\\Classes，需要管理员权限，会自动弹一次 UAC；");
            Console.WriteLine("  * 安装时会自动清除右键菜单管理工具写上的隐藏标志，并实测菜单是否可见；");
            Console.WriteLine("  * 退出码: 0 成功 / 1 有问题 / 2 参数错误 / 5 用户取消了 UAC。");
            return 0;
        }
    }
}
