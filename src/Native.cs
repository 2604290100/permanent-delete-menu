// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 2604290100
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace PDSetup
{
    internal static class Native
    {
        [DllImport("shell32.dll")]
        private static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

        [DllImport("kernel32.dll")]
        private static extern bool AttachConsole(int dwProcessId);

        [DllImport("kernel32.dll")]
        private static extern bool AllocConsole();

        private const int SHCNE_ASSOCCHANGED = 0x08000000;
        private const int ATTACH_PARENT_PROCESS = -1;

        /// <summary>通知资源管理器刷新关联/菜单，不必重启。</summary>
        public static void NotifyShellChanged()
        {
            try { SHChangeNotify(SHCNE_ASSOCCHANGED, 0, IntPtr.Zero, IntPtr.Zero); }
            catch { }
        }

        /// <summary>CLI 模式下把自己挂到父控制台，这样命令行里能看到输出。</summary>
        public static void AttachParentConsole()
        {
            try { AttachConsole(ATTACH_PARENT_PROCESS); }
            catch { }
        }
    }

    /// <summary>菜单可见性自检结果。</summary>
    internal sealed class VisibilityResult
    {
        public bool FileVisible;
        public bool FolderVisible;
        /// <summary>该项被注册为「仅 Shift 扩展菜单显示」（动词键上有 Extended 值）。</summary>
        public bool ExtendedOnly;
        /// <summary>已确认"注册表正常 + 仅 Shift 显示"，所以枚举不到是预期行为，不是故障。</summary>
        public bool ExtendedByDesign;
        public string Detail = "";

        /// <summary>纯粹由 Shell 枚举得到的可见性（不看任何预期）。</summary>
        public bool Visible { get { return FileVisible && FolderVisible; } }

        /// <summary>是否可以认为"这一项该在的时候在"。仅 Shift 显示时枚举必然为空，按预期放行。</summary>
        public bool Ok { get { return Visible || ExtendedByDesign; } }
    }

    /// <summary>
    /// 用系统 Shell 自己枚举动词来判断"菜单里到底能不能看到这一项"。
    /// 这是唯一可信的检查方式：注册表写对了 ≠ 菜单里看得见
    /// （第三方菜单管理工具的隐藏标志会让它消失）。
    /// </summary>
    internal static class ShellVerify
    {
        public static VisibilityResult Check(string verbMatch, bool extendedOnly)
        {
            VisibilityResult r = new VisibilityResult();
            r.ExtendedOnly = extendedOnly;
            string probeRoot = Path.Combine(Path.GetTempPath(), "pdverify_" + Guid.NewGuid().ToString("N").Substring(0, 8));
            try
            {
                Directory.CreateDirectory(probeRoot);
                string probeFile = Path.Combine(probeRoot, "verify.txt");
                File.WriteAllText(probeFile, "probe");

                Type shellType = Type.GetTypeFromProgID("Shell.Application");
                if (shellType == null)
                {
                    r.Detail = "无法创建 Shell.Application（COM 不可用）";
                    return r;
                }
                dynamic shell = Activator.CreateInstance(shellType);
                dynamic folder = shell.NameSpace(probeRoot);
                dynamic fileItem = folder.ParseName("verify.txt");
                r.FileVisible = HasVerb(fileItem, verbMatch);

                string parent = Path.GetDirectoryName(probeRoot);
                string leaf = Path.GetFileName(probeRoot);
                dynamic parentFolder = shell.NameSpace(parent);
                dynamic dirItem = parentFolder.ParseName(leaf);
                r.FolderVisible = HasVerb(dirItem, verbMatch);

                r.Detail = "文件=" + (r.FileVisible ? "可见" : "不可见") + " 文件夹=" + (r.FolderVisible ? "可见" : "不可见");
                if (extendedOnly)
                {
                    // 动词键上写了 Extended 之后，Shell 只在按住 Shift 时列出它；
                    // Shell.Application 的 Verbs() 没法模拟按 Shift，所以这里枚举不到是正常的。
                    r.Detail = r.Detail + "；本项注册为『仅 Shift 扩展菜单显示』，非 Shift 时枚举不到属预期";
                }
            }
            catch (Exception ex)
            {
                r.Detail = "枚举失败: " + ex.Message;
            }
            finally
            {
                try { if (Directory.Exists(probeRoot)) { Directory.Delete(probeRoot, true); } }
                catch { }
            }
            return r;
        }

        /// <summary>列出某个项目当前的所有右键动词名（排障用）。</summary>
        public static List<string> ListVerbs(string folderPath, string itemName)
        {
            List<string> names = new List<string>();
            try
            {
                Type shellType = Type.GetTypeFromProgID("Shell.Application");
                if (shellType == null) { return names; }
                dynamic shell = Activator.CreateInstance(shellType);
                dynamic folder = shell.NameSpace(folderPath);
                if (folder == null) { return names; }
                dynamic item = folder.ParseName(itemName);
                if (item == null) { return names; }
                dynamic verbs = item.Verbs();
                int count = (int)verbs.Count;
                for (int i = 0; i < count; i++)
                {
                    dynamic v = verbs.Item(i);
                    string n = (string)v.Name;
                    if (!string.IsNullOrEmpty(n)) { names.Add(n); }
                }
            }
            catch { }
            return names;
        }

        private static bool HasVerb(dynamic item, string match)
        {
            if (item == null) { return false; }
            dynamic verbs = item.Verbs();
            int count = (int)verbs.Count;
            for (int i = 0; i < count; i++)
            {
                dynamic v = verbs.Item(i);
                string n = (string)v.Name;
                if (!string.IsNullOrEmpty(n) && n.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }
            }
            return false;
        }
    }
}
