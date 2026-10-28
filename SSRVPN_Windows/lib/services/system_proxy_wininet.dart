part of 'system_proxy_service.dart';

// LAN connection flags are not the Internet Settings\\AutoDetect DWORD.
// Query the UI flags so a user's LAN-dialog edit is visible to ownership checks.
const windowsProxyFlagsInterop = r'''
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class SsrvpnConnectionFlags {
  [StructLayout(LayoutKind.Explicit)] struct Value {
    [FieldOffset(0)] public uint Number;
    [FieldOffset(0)] public IntPtr Pointer;
    [FieldOffset(0)] public long Time;
  }
  [StructLayout(LayoutKind.Sequential)] struct Option {
    public uint Id;
    public Value Data;
  }
  [StructLayout(LayoutKind.Sequential)] struct Options {
    public uint Size;
    public IntPtr Connection;
    public uint Count;
    public uint Error;
    public IntPtr Items;
  }
  [DllImport("wininet.dll", EntryPoint="InternetQueryOptionW", SetLastError=true)]
  static extern bool Query(IntPtr handle, uint option, ref Options list, ref uint size);
  [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", SetLastError=true)]
  static extern bool Set(IntPtr handle, uint option, ref Options list, uint size);
  static uint Access(bool write, uint flags) {
    var item = new Option { Id = write ? 1u : 10u, Data = new Value { Number = flags } };
    IntPtr memory = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Option)));
    try {
      var list = new Options { Size = (uint)Marshal.SizeOf(typeof(Options)), Count = 1, Items = memory };
      Marshal.StructureToPtr(item, memory, false);
      uint size = list.Size;
      bool ok = write ? Set(IntPtr.Zero, 75, ref list, size) : Query(IntPtr.Zero, 75, ref list, ref size);
      if (!ok && !write && Marshal.GetLastWin32Error() == 87) {
        item.Id = 1;
        Marshal.StructureToPtr(item, memory, false);
        size = list.Size;
        ok = Query(IntPtr.Zero, 75, ref list, ref size);
      }
      if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
      return ((Option)Marshal.PtrToStructure(memory, typeof(Option))).Data.Number;
    } finally { Marshal.FreeHGlobal(memory); }
  }
  public static uint Read() { return Access(false, 0); }
  public static void Write(uint flags) {
    using (var root = Microsoft.Win32.RegistryKey.OpenBaseKey(
        Microsoft.Win32.RegistryHive.LocalMachine, Microsoft.Win32.RegistryView.Registry64))
    using (var policy = root.OpenSubKey(@"SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings", false)) {
      object value = policy == null ? null : policy.GetValue("ProxySettingsPerUser", null);
      if (value != null && (!(value is int) || (int)value != 1))
        throw new InvalidOperationException("ProxySettingsPerUser forbids per-user WinINet writes");
    }
    if (flags > 15) throw new ArgumentOutOfRangeException("flags");
    Access(true, flags);
    if (Read() != flags) throw new InvalidOperationException("WinINet flags were not restored");
  }
}
"@
''';

const windowsProxyCaptureFlagsScript = '$windowsProxyFlagsInterop\n'
    r'$ssrvpnPreservedFlags = [SsrvpnConnectionFlags]::Read()';

String windowsProxySetFlagsScript(String expression,
        {bool includeInterop = true}) =>
    '${includeInterop ? windowsProxyFlagsInterop : ''}\n'
    '[SsrvpnConnectionFlags]::Write([uint32]($expression))';
