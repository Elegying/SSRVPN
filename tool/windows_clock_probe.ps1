$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows') {
  throw 'This diagnostic requires a disposable GitHub Windows runner.'
}
$exe = Join-Path $env:RUNNER_TEMP 'ssrvpn-clock-probe.exe'
Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public class ClockProbe {
  [DllImport("kernel32.dll")] static extern void GetSystemTimeAsFileTime(out long time);
  [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long time);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(
    IntPtr handle, out long creation, out long exit, out long kernel, out long user);
  public static int Main(string[] args) {
    if (args.Length > 0 && args[0] == "worker") { Thread.Sleep(60000); return 0; }
    string exe = Process.GetCurrentProcess().MainModule.FileName;
    int coarseBefore = 0, coarseAfter = 0, preciseBefore = 0, preciseAfter = 0;
    long minCoarseStart = long.MaxValue, minCoarseEnd = long.MaxValue;
    long minPreciseStart = long.MaxValue, minPreciseEnd = long.MaxValue;
    Stopwatch elapsed = Stopwatch.StartNew();
    for (int i = 0; i < 3000; i++) {
      long cs, ps, ce, pe, creation, exit, kernel, user;
      GetSystemTimeAsFileTime(out cs);
      GetSystemTimePreciseAsFileTime(out ps);
      using (Process child = Process.Start(new ProcessStartInfo(exe, "worker") {
        UseShellExecute = false, CreateNoWindow = true
      })) {
        try {
          GetSystemTimePreciseAsFileTime(out pe);
          GetSystemTimeAsFileTime(out ce);
          if (!GetProcessTimes(child.Handle, out creation, out exit, out kernel, out user))
            throw new InvalidOperationException("GetProcessTimes failed " + Marshal.GetLastWin32Error());
          if (creation < cs) coarseBefore++;
          if (creation > ce) coarseAfter++;
          if (creation < ps) preciseBefore++;
          if (creation > pe) preciseAfter++;
          minCoarseStart = Math.Min(minCoarseStart, creation - cs);
          minCoarseEnd = Math.Min(minCoarseEnd, ce - creation);
          minPreciseStart = Math.Min(minPreciseStart, creation - ps);
          minPreciseEnd = Math.Min(minPreciseEnd, pe - creation);
          if ((creation < cs || creation > ce || creation < ps || creation > pe) &&
              coarseBefore + coarseAfter + preciseBefore + preciseAfter <= 30)
            Console.WriteLine("sample={0} cs={1} ps={2} creation={3} pe={4} ce={5}", i, cs, ps, creation, pe, ce);
        } finally {
          // Only the exact child created and held by this diagnostic is stopped.
          if (!child.HasExited) child.Kill();
          if (!child.WaitForExit(5000)) throw new TimeoutException("Owned diagnostic child did not exit");
        }
      }
    }
    Console.WriteLine("samples=3000 coarseBefore={0} coarseAfter={1} preciseBefore={2} preciseAfter={3}",
      coarseBefore, coarseAfter, preciseBefore, preciseAfter);
    Console.WriteLine("minimumMargins100ns coarseStart={0} coarseEnd={1} preciseStart={2} preciseEnd={3} elapsedMs={4}",
      minCoarseStart, minCoarseEnd, minPreciseStart, minPreciseEnd, elapsed.ElapsedMilliseconds);
    return 0;
  }
}
'@
& $exe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
