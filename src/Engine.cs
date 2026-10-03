// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 2604290100
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace PDSetup
{
    /// <summary>
    /// 引擎抽象 —— 后期换/加引擎时只实现这个接口，不动注册表与界面代码。
    /// 当前实现见 <see cref="PowerShellVbsEngine"/>；将来做"自带 exe 引擎"时
    /// 再加一个 <c>BuiltinExeEngine</c>（它必须是非提权 exe，见 README 的架构说明）。
    /// </summary>
    internal interface IEngine
    {
        string Id { get; }
        string DisplayName { get; }
        bool IsDeployed();
        bool Deploy(List<string> log);
        void Remove(List<string> log);
        string BuildVerbCommand();
    }

    /// <summary>
    /// 当前引擎：PowerShell 主脚本 + VBS 隐藏启动器。
    /// 两个脚本以资源形式内嵌在本 exe 里，部署时按字节释放（保留 BOM / 纯 ASCII 约束）。
    /// </summary>
    internal sealed class PowerShellVbsEngine : IEngine
    {
        public string Id { get { return "powershell-vbs"; } }
        public string DisplayName { get { return "PowerShell 脚本 + VBS 启动器"; } }

        private const string Ps1ResourceSuffix = "PermanentDelete.ps1";
        private const string VbsResourceSuffix = "launch_perm_delete.vbs";

        public bool IsDeployed()
        {
            return File.Exists(AppPaths.EnginePs1) && File.Exists(AppPaths.EngineVbs);
        }

        public bool Deploy(List<string> log)
        {
            bool ok = true;
            ok = Extract(Ps1ResourceSuffix, AppPaths.EnginePs1, log) && ok;
            ok = Extract(VbsResourceSuffix, AppPaths.EngineVbs, log) && ok;
            return ok;
        }

        public void Remove(List<string> log)
        {
            TryDelete(AppPaths.EnginePs1, log);
            TryDelete(AppPaths.EngineVbs, log);
        }

        public string BuildVerbCommand()
        {
            // %V = 整个选中集；尾部路径的引号由 VBS 负责加固
            return "wscript.exe \"" + AppPaths.EngineVbs + "\" %V";
        }

        private static void TryDelete(string path, List<string> log)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                    log.Add("删除引擎文件 " + path);
                }
            }
            catch (Exception ex) { log.Add("删除失败 " + path + " : " + ex.Message); }
        }

        private static bool Extract(string resourceSuffix, string targetPath, List<string> log)
        {
            try
            {
                Assembly asm = Assembly.GetExecutingAssembly();
                string found = null;
                foreach (string name in asm.GetManifestResourceNames())
                {
                    if (name.EndsWith(resourceSuffix, StringComparison.OrdinalIgnoreCase)) { found = name; break; }
                }
                if (found == null)
                {
                    log.Add("内置资源缺失: " + resourceSuffix);
                    return false;
                }

                byte[] data;
                using (Stream s = asm.GetManifestResourceStream(found))
                {
                    if (s == null) { log.Add("读取资源失败: " + found); return false; }
                    data = new byte[s.Length];
                    int read = 0;
                    while (read < data.Length)
                    {
                        int n = s.Read(data, read, data.Length - read);
                        if (n <= 0) { break; }
                        read += n;
                    }
                }

                if (File.Exists(targetPath) && SameBytes(targetPath, data))
                {
                    log.Add("引擎文件已是最新（未改动）: " + Path.GetFileName(targetPath));
                    return true;
                }

                Directory.CreateDirectory(Path.GetDirectoryName(targetPath));
                File.WriteAllBytes(targetPath, data);
                log.Add("释放引擎文件 " + Path.GetFileName(targetPath) + " (" + data.Length + " B, sha256 " + Short(data) + ")");
                return true;
            }
            catch (Exception ex)
            {
                log.Add("释放资源失败 " + resourceSuffix + " : " + ex.Message);
                return false;
            }
        }

        private static bool SameBytes(string path, byte[] data)
        {
            try
            {
                FileInfo fi = new FileInfo(path);
                if (fi.Length != data.Length) { return false; }
                byte[] cur = File.ReadAllBytes(path);
                for (int i = 0; i < cur.Length; i++)
                {
                    if (cur[i] != data[i]) { return false; }
                }
                return true;
            }
            catch { return false; }
        }

        private static string Short(byte[] data)
        {
            using (SHA256 sha = SHA256.Create())
            {
                byte[] h = sha.ComputeHash(data);
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < 8; i++) { sb.Append(h[i].ToString("x2")); }
                return sb.ToString();
            }
        }
    }
}
