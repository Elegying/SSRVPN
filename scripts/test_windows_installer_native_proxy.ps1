$ErrorActionPreference='Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
# Real WinINet calls use a process-local HKCU override, never the user's settings.
$source=Get-Content "$root\SSRVPN_Windows\installer\proxy_transaction_state.ps1" -Encoding UTF8 -Raw
$m=[regex]::Match($source,'(?s)Add-Type -TypeDefinition @"\r?\n(.*?)\r?\n"@')
 $probe = @'
namespace Isolated {
using System;
using Microsoft.Win32;
using System.Runtime.InteropServices;
public static class Probe {
 [DllImport("wininet.dll",SetLastError=true)] static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);
 [DllImport("advapi32.dll")] static extern int RegOverridePredefKey(IntPtr h, IntPtr key);
 public static void Run() {
  string name="Software\\SSRVPNInstallerProbe-"+Guid.NewGuid().ToString("N");
  using(var key=Registry.CurrentUser.CreateSubKey(name)) {
   var hkcu=new IntPtr(unchecked((int)0x80000001));
   int error=RegOverridePredefKey(hkcu,key.Handle.DangerousGetHandle());
   if(error!=0) throw new Exception("Override failed "+error);
   try {
    string path="Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
    using(var settings=Registry.CurrentUser.CreateSubKey(path)) {
     settings.SetValue("ProxyEnable",0,RegistryValueKind.DWord);
     settings.SetValue("AutoDetect",0,RegistryValueKind.DWord);
    }
    using(var settings=Registry.CurrentUser.CreateSubKey(path+"\\Connections")) {
     using(var stream=new System.IO.MemoryStream()) {
      using(var writer=new System.IO.BinaryWriter(stream)) {
       writer.Write(70); writer.Write(1); writer.Write(15);
       foreach(var item in new[]{"127.0.0.1:7777","<local>","http://example.invalid/proxy.pac"}) {
        var bytes=System.Text.Encoding.ASCII.GetBytes(item); writer.Write(bytes.Length); writer.Write(bytes);
       }
       writer.Write(new byte[32]);
       settings.SetValue("DefaultConnectionSettings",stream.ToArray(),RegistryValueKind.Binary);
      }
     }
    }
    SsrVpnInstallerDirect.Seed();
    bool detected=false;
    try { SsrVpnInstallerDirect.Verify(); } catch(InvalidOperationException) { detected=true; }
    if(!detected) throw new Exception("Seed proxy flags were not detected");
    SsrVpnInstallerDirect.Reset();
    InternetSetOption(IntPtr.Zero,39,IntPtr.Zero,0);
    InternetSetOption(IntPtr.Zero,37,IntPtr.Zero,0);
    SsrVpnInstallerDirect.Verify();
    Console.WriteLine("Native seeded proxy flags cleared and verified");
    using(var settings=Registry.CurrentUser.OpenSubKey(path)) {
     foreach(var n in new[]{"ProxyEnable","AutoDetect","ProxyServer","AutoConfigURL"}) {
      var value=settings.GetValue(n);
      if(value != null && ((value is int && (int)value != 0) ||
          (value is string && ((string)value).Length != 0)))
        throw new Exception("Unexpected registry state after reset: "+n);
     }
    }
   } finally { RegOverridePredefKey(hkcu,IntPtr.Zero); }
  }
  Registry.CurrentUser.DeleteSubKeyTree(name);
 }
}
}
'@
$nativeSource=$m.Groups[1].Value
$start=$nativeSource.IndexOf('  public static void Reset()')
$end=$nativeSource.IndexOf('  public static void Verify()')
$seed=$nativeSource.Substring($start,$end-$start).Replace('Reset()', 'Seed()').Replace('Flags = 1', 'Flags = 15').Replace('Marshal.StringToHGlobalUni("")', 'Marshal.StringToHGlobalUni("http://127.0.0.1:7777")')
$nativeSource=$nativeSource.Insert($end,$seed)
Add-Type -TypeDefinition ($nativeSource + [Environment]::NewLine + $probe)
[Isolated.Probe]::Run()
