// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 2604290100
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace PDSetup
{
    /// <summary>安装器自己的日志（和引擎的 delete.log 分开）。</summary>
    internal static class Logger
    {
        private static readonly object Gate = new object();
        private const long MaxBytes = 2 * 1024 * 1024;

        public static void Write(string message)
        {
            lock (Gate)
            {
                try
                {
                    Directory.CreateDirectory(AppPaths.AppRoot);
                    string file = AppPaths.SetupLog;
                    if (File.Exists(file) && new FileInfo(file).Length > MaxBytes)
                    {
                        string bak = file + ".1";
                        if (File.Exists(bak)) { File.Delete(bak); }
                        File.Move(file, bak);
                    }
                    StringBuilder sb = new StringBuilder();
                    sb.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff"));
                    sb.Append("|pid ");
                    sb.Append(Process.GetCurrentProcess().Id);
                    sb.Append('|');
                    sb.Append(message);
                    sb.Append(Environment.NewLine);
                    File.AppendAllText(file, sb.ToString(), new UTF8Encoding(false));
                }
                catch { }
            }
        }

        public static string Tail(int lines)
        {
            try
            {
                if (!File.Exists(AppPaths.SetupLog)) { return ""; }
                string[] all = File.ReadAllLines(AppPaths.SetupLog, Encoding.UTF8);
                int start = all.Length - lines;
                if (start < 0) { start = 0; }
                StringBuilder sb = new StringBuilder();
                for (int i = start; i < all.Length; i++)
                {
                    sb.AppendLine(all[i]);
                }
                return sb.ToString();
            }
            catch { return ""; }
        }
    }
}
