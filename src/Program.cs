// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 2604290100
using System;
using System.Windows.Forms;

namespace PDSetup
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            Options o = Options.Parse(args);

            if (o.Command.Length == 0)
            {
                // 无命令 → 图形界面
                try
                {
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    Application.Run(new MainForm());
                    return 0;
                }
                catch (Exception ex)
                {
                    Logger.Write("gui-fatal " + ex);
                    MessageBox.Show("界面启动失败: " + ex.Message + "\r\n详见 " + AppPaths.SetupLog,
                        "永久删除", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }
            }

            // 有命令 → 命令行模式（挂到父控制台，这样在终端里能看到输出）
            Native.AttachParentConsole();
            try
            {
                return Commands.Run(o);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("fatal=" + ex.Message);
                Logger.Write("cli-fatal " + ex);
                return 1;
            }
        }
    }
}
