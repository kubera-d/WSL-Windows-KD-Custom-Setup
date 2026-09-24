// DevControl.exe - starts DevControl.ps1 in Windows PowerShell with no console window.
// Compiled by Install.ps1 with the .NET Framework csc.exe (/target:winexe).
using System;
using System.Diagnostics;
using System.IO;

static class Launcher
{
    static void Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "DevControl.ps1");
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        string extra = string.Join(" ", args);
        var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + script + "\" " + extra);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
