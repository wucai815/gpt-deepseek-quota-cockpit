using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Quota Cockpit")]
[assembly: AssemblyDescription("GPT and DeepSeek secondary-screen dashboard")]
[assembly: AssemblyCompany("Personal Tools")]
[assembly: AssemblyProduct("Quota Cockpit")]
[assembly: AssemblyVersion("1.3.0.0")]
[assembly: AssemblyFileVersion("1.3.0.0")]

internal static class Launcher
{
    // A single file executable with an embedded application payload. Credentials are never embedded.
    [STAThread]
    private static int Main(string[] args)
    {
        bool diagnostic = Array.IndexOf(args, "--self-test") >= 0 || Array.IndexOf(args, "--smoke-test") >= 0;
        try
        {
            foreach (string arg in args)
                if (arg != "--demo" && arg != "--windowed" && arg != "--self-test" && arg != "--smoke-test" && arg != "--settings")
                    throw new ArgumentException("Unsupported option: " + arg);

            string dataRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GptQuotaMonitor");
            byte[] payload;
            using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("Cockpit.Payload"))
            using (MemoryStream memory = new MemoryStream())
            {
                if (source == null) throw new InvalidDataException("Application payload is missing.");
                source.CopyTo(memory);
                payload = memory.ToArray();
            }
            string hash;
            using (SHA256 sha = SHA256.Create())
                hash = BitConverter.ToString(sha.ComputeHash(payload)).Replace("-", "").ToLowerInvariant();
            string runtime = Path.Combine(dataRoot, "App", hash.Substring(0, 20));
            using (Mutex mutex = new Mutex(false, "Local\\QuotaCockpitExtract_" + hash.Substring(0, 20)))
            {
                bool held = false;
                try
                {
                    try { held = mutex.WaitOne(30000); }
                    catch (AbandonedMutexException) { held = true; }
                    if (!held) throw new IOException("Application is being prepared. Please try again shortly.");
                    Directory.CreateDirectory(runtime);
                    string prefix = Path.GetFullPath(runtime).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                    using (MemoryStream input = new MemoryStream(payload, false))
                    using (ZipArchive archive = new ZipArchive(input, ZipArchiveMode.Read))
                    {
                        foreach (ZipArchiveEntry entry in archive.Entries)
                        {
                            string target = Path.GetFullPath(Path.Combine(runtime, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
                            if (!target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Invalid payload path.");
                            Directory.CreateDirectory(Path.GetDirectoryName(target));
                            using (Stream source = entry.Open())
                            using (FileStream output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.Read))
                                source.CopyTo(output);
                        }
                    }
                    string config = Path.Combine(dataRoot, "config.json");
                    if (!File.Exists(config)) File.Copy(Path.Combine(runtime, "config.json"), config);
                }
                finally { if (held) mutex.ReleaseMutex(); }
            }

            if (Array.IndexOf(args, "--self-test") >= 0)
            {
                foreach (string required in new string[] { "Monitor.ps1", "Dashboard.xaml", "QuotaSource.ps1", "DeepSeekSource.ps1", "DeepSeekPanel.ps1", "DeepSeekTariff.ps1", "pricing-rules.json", "Set-DeepSeekKey.ps1" })
                    if (!File.Exists(Path.Combine(runtime, required))) throw new InvalidDataException("Missing " + required);
                File.WriteAllText(Path.Combine(dataRoot, "exe-self-test.txt"), "PASS\r\nPayload SHA256: " + hash + "\r\nRuntime: " + runtime, Encoding.UTF8);
                return 0;
            }

            bool settings = Array.IndexOf(args, "--settings") >= 0;
            string script = Path.Combine(runtime, settings ? "Set-DeepSeekKey.ps1" : "Monitor.ps1");
            string command = "-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File " + Quote(script);
            if (!settings) command += " -ConfigPath " + Quote(Path.Combine(dataRoot, "config.json"));
            if (!settings && Array.IndexOf(args, "--demo") >= 0) command += " -Demo";
            if (!settings && Array.IndexOf(args, "--windowed") >= 0) command += " -Windowed";
            if (!settings && Array.IndexOf(args, "--smoke-test") >= 0) command += " -SmokeTest";
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            info.Arguments = command;
            info.WorkingDirectory = runtime;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            // Lets future integrations identify the entry point without embedding machine paths.
            info.EnvironmentVariables["QUOTA_COCKPIT_EXE"] = Assembly.GetExecutingAssembly().Location;
            info.RedirectStandardOutput = diagnostic;
            info.RedirectStandardError = diagnostic;
            using (Process process = Process.Start(info))
            {
                if (diagnostic)
                {
                    System.Threading.Tasks.Task<string> output = process.StandardOutput.ReadToEndAsync();
                    System.Threading.Tasks.Task<string> error = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit(60000)) { process.Kill(); throw new TimeoutException("Dashboard smoke test timed out."); }
                    File.WriteAllText(Path.Combine(dataRoot, "exe-smoke-test.txt"), output.Result + error.Result, Encoding.UTF8);
                }
                else process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            if (!diagnostic) MessageBox.Show("无法启动额度驾驶舱：\r\n" + error.Message, "额度驾驶舱", MessageBoxButtons.OK, MessageBoxIcon.Error);
            else
            {
                string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GptQuotaMonitor");
                Directory.CreateDirectory(root);
                File.WriteAllText(Path.Combine(root, "exe-test-error.txt"), error.GetType().Name + ": " + error.Message);
            }
            return 1;
        }
    }

    private static string Quote(string value)
    {
        // CommandLineToArgvW-compatible quoting; supports spaces and Chinese folder names.
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') result.Append('\\', slashes * 2 + 1);
            else result.Append('\\', slashes);
            result.Append(c);
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        return result.Append('"').ToString();
    }
}
