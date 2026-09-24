// Windows PowerShell 5.1 / .NET Framework. No path-based deletion after hashing.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace SsrvpnInstaller {
  public sealed class ProgramFile : IDisposable {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share,
      IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path,
      uint length, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind,
      ref byte data, uint size);
    [StructLayout(LayoutKind.Sequential)]
    struct Info {
      public uint Attributes;
      public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
      public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    readonly List<SafeFileHandle> parents = new List<SafeFileHandle>();
    FileStream stream;
    public long Length { get { return stream.Length; } }
    public string Sha256 { get; private set; }
    static void Check(SafeFileHandle handle, string path, bool directory) {
      if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), path);
      Info info;
      if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception();
      if ((info.Attributes & 0x400) != 0 || (((info.Attributes & 0x10) != 0) != directory) ||
          (!directory && info.Links != 1)) throw new IOException("Unsafe program path: " + path);
      var final = new StringBuilder(32768);
      var size = GetFinalPathNameByHandle(handle, final, (uint)final.Capacity, 0);
      if (size == 0 || size >= final.Capacity) throw new IOException("Cannot resolve program path.");
      var actual = final.ToString();
      if (actual.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) actual = @"\\" + actual.Substring(8);
      else if (actual.StartsWith(@"\\?\", StringComparison.Ordinal)) actual = actual.Substring(4);
      if (!String.Equals(actual.TrimEnd('\\'), Path.GetFullPath(path).TrimEnd('\\'),
          StringComparison.OrdinalIgnoreCase)) throw new IOException("Program path changed: " + path);
    }
    void PinParents(string path, bool create) {
      var stack = new Stack<string>();
      var parent = Path.GetDirectoryName(Path.GetFullPath(path));
      while (!String.IsNullOrEmpty(parent)) {
        stack.Push(parent);
        var next = Path.GetDirectoryName(parent);
        if (next == parent) break;
        parent = next;
      }
      while (stack.Count > 0) {
        parent = stack.Pop();
        if (create && !Directory.Exists(parent)) Directory.CreateDirectory(parent);
        // No FILE_SHARE_DELETE: a pinned directory cannot be exchanged for a junction.
        var handle = CreateFile(parent, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        parents.Add(handle);
        Check(handle, parent, true);
      }
    }
    public static ProgramFile Open(string path, bool deleteAccess) {
      var item = new ProgramFile();
      SafeFileHandle handle = null;
      try {
        item.PinParents(path, false);
        handle = CreateFile(path, 0x80000000u | (deleteAccess ? 0x10000u : 0),
          1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        Check(handle, path, false);
        item.stream = new FileStream(handle, FileAccess.Read);
        handle = null;
        using (var hash = SHA256.Create()) {
          item.Sha256 = BitConverter.ToString(hash.ComputeHash(item.stream)).Replace("-", "").ToLowerInvariant();
        }
        item.stream.Position = 0;
        return item;
      } catch { if (handle != null) handle.Dispose(); item.Dispose(); throw; }
    }
    public void Delete() {
      byte value = 1;
      if (!SetFileInformationByHandle(stream.SafeFileHandle, 4, ref value, 1))
        throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot remove verified program file.");
    }
    public void CopyNew(string path) {
      using (var target = new ProgramFile()) {
        target.PinParents(path, true);
        var handle = CreateFile(path, 0xC0010000, 0, IntPtr.Zero, 1, 0x00200000, IntPtr.Zero);
        try { Check(handle, path, false); target.stream = new FileStream(handle, FileAccess.ReadWrite); }
        catch { handle.Dispose(); throw; }
        try {
          stream.Position = 0;
          stream.CopyTo(target.stream);
          target.stream.Flush(true);
          target.stream.Position = 0;
          using (var hash = SHA256.Create()) {
            var digest = BitConverter.ToString(hash.ComputeHash(target.stream)).Replace("-", "").ToLowerInvariant();
            if (digest != Sha256) throw new IOException("Copied program file did not verify.");
          }
        } catch { target.Delete(); throw; }
      }
    }
    public void Dispose() {
      if (stream != null) { stream.Dispose(); stream = null; }
      for (int i = parents.Count - 1; i >= 0; --i) parents[i].Dispose();
      parents.Clear();
    }
  }
}
