// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 2604290100
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using Microsoft.Win32;

namespace PDSetup
{
    internal sealed class MenuStatus
    {
        public bool Installed;
        public string Command = "";
        public string MenuText = "";
        public bool ExtendedOnly;
        public string MultiSelectModel = "";
        public List<string> HideFlags = new List<string>();
        public List<string> StaleKeys = new List<string>();
        public bool EngineDeployed;
    }

    /// <summary>
    /// 右键动词的注册表读写。
    ///
    /// 只注册在一个类上：HKLM\SOFTWARE\Classes\AllFilesystemObjects\shell\PermanentDelete
    ///   * 这个类对"文件 + 文件夹"同时生效（系统自带"发送到"就在这里）
    ///   * 只注册一处，才不会被 Shell 当成两个动词各调用一次
    ///   * HKLM 是必须的：实测 HKCU\Software\Classes 下的静态动词 Explorer 不认
    ///     （所以本工具需要管理员权限）
    /// </summary>
    internal static class MenuRegistry
    {
        private const string ClassesPath = @"SOFTWARE\Classes";

        private static RegistryKey OpenClasses(bool writable)
        {
            RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            return baseKey.OpenSubKey(ClassesPath, writable);
        }

        public static MenuStatus GetStatus()
        {
            MenuStatus st = new MenuStatus();
            try
            {
                using (RegistryKey classes = OpenClasses(false))
                {
                    st.EngineDeployed = File.Exists(AppPaths.EnginePs1) && File.Exists(AppPaths.EngineVbs);
                    if (classes == null) { return st; }
                    using (RegistryKey key = classes.OpenSubKey(AppPaths.VerbSubKey))
                    {
                        if (key != null)
                        {
                            st.Installed = true;
                            st.MenuText = AsString(key.GetValue(""));
                            st.MultiSelectModel = AsString(key.GetValue("MultiSelectModel"));
                            st.ExtendedOnly = key.GetValue("Extended") != null;
                            using (RegistryKey cmd = key.OpenSubKey("command"))
                            {
                                if (cmd != null) { st.Command = AsString(cmd.GetValue("")); }
                            }
                            foreach (string name in key.GetValueNames())
                            {
                                if (Array.IndexOf(AppPaths.HideFlagNames, name) >= 0) { st.HideFlags.Add(name); }
                            }
                        }
                    }
                    foreach (string stale in AppPaths.StaleVerbSubKeys)
                    {
                        using (RegistryKey k = classes.OpenSubKey(stale))
                        {
                            if (k != null) { st.StaleKeys.Add(stale); }
                        }
                    }
                }
            }
            catch (Exception ex) { Logger.Write("status-fail " + ex.Message); }
            return st;
        }

        public static bool Install(SetupSettings settings, IEngine engine, List<string> log)
        {
            bool ok = true;
            try
            {
                CleanStale(log);

                using (RegistryKey classes = OpenClasses(true))
                {
                    if (classes == null)
                    {
                        log.Add("无法写入 HKLM\\SOFTWARE\\Classes（需要管理员权限）");
                        return false;
                    }
                    using (RegistryKey key = classes.CreateSubKey(AppPaths.VerbSubKey))
                    {
                        if (key == null)
                        {
                            log.Add("创建注册表项失败: " + AppPaths.VerbSubKey);
                            return false;
                        }
                        key.SetValue("", settings.MenuText, RegistryValueKind.String);
                        if (!string.IsNullOrEmpty(settings.Icon))
                        {
                            key.SetValue("Icon", settings.Icon, RegistryValueKind.String);
                        }
                        if (!string.IsNullOrEmpty(settings.Position))
                        {
                            key.SetValue("Position", settings.Position, RegistryValueKind.String);
                        }
                        key.SetValue("MultiSelectModel", "Player", RegistryValueKind.String);

                        if (settings.ExtendedOnly)
                        {
                            key.SetValue("Extended", "", RegistryValueKind.String);
                            log.Add("已设为『仅 Shift 扩展菜单显示』");
                        }
                        else if (key.GetValue("Extended") != null)
                        {
                            key.DeleteValue("Extended", false);
                            log.Add("已取消『仅 Shift 扩展菜单显示』");
                        }

                        // 关键：清掉第三方"右键菜单审核/管理"工具写上的隐藏标志
                        foreach (string flag in AppPaths.HideFlagNames)
                        {
                            if (key.GetValue(flag) != null)
                            {
                                key.DeleteValue(flag, false);
                                log.Add("清除隐藏标志 " + flag + "（多半是右键菜单管理工具写的）");
                            }
                        }

                        using (RegistryKey cmd = key.CreateSubKey("command"))
                        {
                            cmd.SetValue("", engine.BuildVerbCommand(), RegistryValueKind.String);
                        }
                    }

                    // 回读校验
                    using (RegistryKey check = classes.OpenSubKey(AppPaths.VerbSubKey + @"\command"))
                    {
                        string actual = check == null ? "" : AsString(check.GetValue(""));
                        log.Add("注册完成: " + AppPaths.VerbHklmDisplay);
                        log.Add("  command = " + actual);
                        if (actual.Length == 0) { ok = false; }
                    }
                }
            }
            catch (Exception ex)
            {
                log.Add("安装失败: " + ex.Message);
                ok = false;
            }
            return ok;
        }

        public static bool Uninstall(SetupSettings settings, IEngine engine, List<string> log)
        {
            bool ok = true;
            try
            {
                BackupKey(AppPaths.VerbSubKey, log);

                using (RegistryKey classes = OpenClasses(true))
                {
                    if (classes != null)
                    {
                        if (classes.OpenSubKey(AppPaths.VerbSubKey) != null)
                        {
                            classes.DeleteSubKeyTree(AppPaths.VerbSubKey, false);
                            log.Add("已删除 " + AppPaths.VerbHklmDisplay);
                        }
                        foreach (string stale in AppPaths.StaleVerbSubKeys)
                        {
                            if (classes.OpenSubKey(stale) != null)
                            {
                                classes.DeleteSubKeyTree(stale, false);
                                log.Add("已删除历史注册项 " + stale);
                            }
                        }
                    }
                }

                // 顺手清理 HKCU 下可能存在的同名项
                try
                {
                    using (RegistryKey cu = Registry.CurrentUser.OpenSubKey(@"Software\Classes", true))
                    {
                        if (cu != null)
                        {
                            if (cu.OpenSubKey(AppPaths.VerbSubKey) != null) { cu.DeleteSubKeyTree(AppPaths.VerbSubKey, false); }
                            foreach (string stale in AppPaths.StaleVerbSubKeys)
                            {
                                if (cu.OpenSubKey(stale) != null) { cu.DeleteSubKeyTree(stale, false); }
                            }
                        }
                    }
                }
                catch { }

                if (settings.RemoveEngineOnUninstall)
                {
                    engine.Remove(log);
                }
                else
                {
                    log.Add("引擎脚本保留（如需删除请勾选『卸载时同时删除引擎脚本』）");
                }
            }
            catch (Exception ex)
            {
                log.Add("卸载失败: " + ex.Message);
                ok = false;
            }
            return ok;
        }

        private static void CleanStale(List<string> log)
        {
            try
            {
                using (RegistryKey classes = OpenClasses(true))
                {
                    if (classes == null) { return; }
                    foreach (string stale in AppPaths.StaleVerbSubKeys)
                    {
                        if (classes.OpenSubKey(stale) != null)
                        {
                            BackupKey(stale, log);
                            classes.DeleteSubKeyTree(stale, false);
                            log.Add("清理历史注册项 " + stale + "（它会造成『混合选中弹多个框』）");
                        }
                    }
                }
            }
            catch (Exception ex) { log.Add("清理历史项失败: " + ex.Message); }
        }

        private static void BackupKey(string subKey, List<string> log)
        {
            try
            {
                Directory.CreateDirectory(AppPaths.AppRoot);
                string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmssfff");
                string safe = subKey.Replace('\\', '_').Replace('*', '_');
                string file = Path.Combine(AppPaths.AppRoot, "backup-" + stamp + "-" + safe + ".reg");
                ProcessStartInfo psi = new ProcessStartInfo("reg.exe",
                    "export \"HKLM\\" + ClassesPath + "\\" + subKey + "\" \"" + file + "\" /y");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                using (Process p = Process.Start(psi))
                {
                    p.StandardOutput.ReadToEnd();
                    p.StandardError.ReadToEnd();
                    p.WaitForExit(15000);
                    if (p.ExitCode == 0) { log.Add("已备份到 " + file); }
                }
            }
            catch (Exception ex) { log.Add("备份失败（继续）: " + ex.Message); }
        }

        private static string AsString(object value)
        {
            return value == null ? "" : Convert.ToString(value);
        }
    }
}
