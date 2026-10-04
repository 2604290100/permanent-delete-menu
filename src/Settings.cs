// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mxx1.cn
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace PDSetup
{
    /// <summary>
    /// 安装器设置（setup.ini，key=value）。
    /// 将来加功能：加一个字段 + 一个键，GUI 里加一个控件即可，不需要动注册表逻辑。
    /// </summary>
    internal sealed class SetupSettings
    {
        public string MenuText = AppPaths.Product;
        public string Icon = "shell32.dll,247";
        public string Position = "Bottom";          // Bottom | Top | (空)
        public bool ExtendedOnly = false;           // true = 只在按住 Shift 的扩展菜单里出现
        public bool RemoveEngineOnUninstall = false; // 卸载时是否连引擎脚本一起删
        public string Engine = "powershell-vbs";    // 预留：将来可切到 "builtin-exe"

        public static SetupSettings Load()
        {
            SetupSettings s = new SetupSettings();
            try
            {
                if (!File.Exists(AppPaths.SettingsFile)) { return s; }
                foreach (string raw in File.ReadAllLines(AppPaths.SettingsFile, Encoding.UTF8))
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith("#") || line.StartsWith(";")) { continue; }
                    int eq = line.IndexOf('=');
                    if (eq <= 0) { continue; }
                    string k = line.Substring(0, eq).Trim().ToLowerInvariant();
                    string v = line.Substring(eq + 1).Trim();
                    switch (k)
                    {
                        case "menutext": if (v.Length > 0) { s.MenuText = v; } break;
                        case "icon": if (v.Length > 0) { s.Icon = v; } break;
                        case "position": s.Position = v; break;
                        case "extendedonly": s.ExtendedOnly = ParseBool(v); break;
                        case "removeengineonuninstall": s.RemoveEngineOnUninstall = ParseBool(v); break;
                        case "engine": if (v.Length > 0) { s.Engine = v; } break;
                    }
                }
            }
            catch (Exception ex) { Logger.Write("settings-load-fail " + ex.Message); }
            return s;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(AppPaths.AppRoot);
                List<string> lines = new List<string>();
                lines.Add("# 永久删除右键菜单 · 安装器设置（可手改；改完在窗口里点『重新检测』或重新添加）");
                lines.Add("MenuText=" + MenuText);
                lines.Add("Icon=" + Icon);
                lines.Add("Position=" + Position);
                lines.Add("ExtendedOnly=" + (ExtendedOnly ? "true" : "false"));
                lines.Add("RemoveEngineOnUninstall=" + (RemoveEngineOnUninstall ? "true" : "false"));
                lines.Add("Engine=" + Engine);
                File.WriteAllLines(AppPaths.SettingsFile, lines.ToArray(), new UTF8Encoding(false));
            }
            catch (Exception ex) { Logger.Write("settings-save-fail " + ex.Message); }
        }

        private static bool ParseBool(string v)
        {
            v = v.Trim().ToLowerInvariant();
            return v == "1" || v == "true" || v == "yes" || v == "on";
        }
    }
}
