// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 2604290100
using System;
using System.Diagnostics;
using System.IO;

namespace PDSetup
{
    /// <summary>
    /// 全局路径与常量。要加新功能时，先看这里：新增文件位置统一挂在这。
    /// </summary>
    internal static class AppPaths
    {
        public const string Product = "永久删除（不进回收站）";
        public const string VerbName = "PermanentDelete";
        public const string VerbSubKey = @"AllFilesystemObjects\shell\" + VerbName;
        public const string VerbHklmDisplay = @"HKLM\SOFTWARE\Classes\" + VerbSubKey;

        /// <summary>历史/错误的位置：安装时一并清理，避免旧注册项造成"调用两次"。</summary>
        public static readonly string[] StaleVerbSubKeys = new string[]
        {
            @"*\shell\" + VerbName,
            @"Directory\shell\" + VerbName,
            @"Directory\Background\shell\" + VerbName,
            @"Drive\shell\" + VerbName
        };

        /// <summary>
        /// 第三方"右键菜单管理/审核"工具会给新动词写上这些值，只要有，菜单里就看不到。
        /// 安装流程必须清除它们（本机实测就是被这些标志藏起来的）。
        /// </summary>
        public static readonly string[] HideFlagNames = new string[]
        {
            "LegacyDisable",
            "ProgrammaticAccessOnly",
            "HideBasedOnVelocityId",
            "ExtendedVerbs"
        };

        public static string LocalAppData
        {
            get { return Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); }
        }

        public static string AppRoot { get { return Path.Combine(LocalAppData, "PermanentDelete"); } }
        public static string EnginePs1 { get { return Path.Combine(LocalAppData, "PermanentDelete.ps1"); } }
        public static string EngineVbs { get { return Path.Combine(LocalAppData, "launch_perm_delete.vbs"); } }
        public static string SetupLog { get { return Path.Combine(AppRoot, "setup.log"); } }
        public static string SettingsFile { get { return Path.Combine(AppRoot, "setup.ini"); } }
        public static string DeleteLog { get { return Path.Combine(AppRoot, "delete.log"); } }

        public static string ExePath
        {
            get { return Process.GetCurrentProcess().MainModule.FileName; }
        }

        /// <summary>当前进程是否管理员。</summary>
        public static bool IsAdmin
        {
            get
            {
                try
                {
                    System.Security.Principal.WindowsIdentity id = System.Security.Principal.WindowsIdentity.GetCurrent();
                    System.Security.Principal.WindowsPrincipal p = new System.Security.Principal.WindowsPrincipal(id);
                    return p.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
                }
                catch { return false; }
            }
        }
    }
}
