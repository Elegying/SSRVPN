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
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DuplicateHandle(IntPtr process, IntPtr source, IntPtr target,
      out SafeFileHandle duplicate, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")] static extern uint GetFileType(SafeFileHandle handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint size);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr process,
      out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern uint PssCaptureSnapshot(IntPtr process, uint flags, uint context, out IntPtr snapshot);
    [DllImport("kernel32.dll")] static extern uint PssFreeSnapshot(IntPtr process, IntPtr snapshot);
    [DllImport("kernel32.dll")] static extern uint PssWalkMarkerCreate(IntPtr allocator, out IntPtr marker);
    [DllImport("kernel32.dll")] static extern uint PssWalkMarkerFree(IntPtr marker);
    [DllImport("kernel32.dll")] static extern uint PssWalkSnapshot(IntPtr snapshot, int kind, IntPtr marker, out HandleEntry entry, uint size);
    [StructLayout(LayoutKind.Explicit, Size = 48)] struct HandleSpecific { }
    [StructLayout(LayoutKind.Sequential)] struct HandleEntry {
      public IntPtr Handle;
      public uint Flags, Type;
      public System.Runtime.InteropServices.ComTypes.FILETIME Captured;
      public uint Attributes, Access, Handles, Pointers, Paged, NonPaged;
      public System.Runtime.InteropServices.ComTypes.FILETIME Created;
      public ushort TypeLength;
      public IntPtr TypeName;
      public ushort NameLength;
      public IntPtr Name;
      public HandleSpecific Specific;
    }
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
        // FILE_LIST_DIRECTORY participates in sharing checks; READ_ATTRIBUTES
        // alone does not prevent rename even without FILE_SHARE_DELETE.
        var handle = CreateFile(parent, 0x81, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
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
    public static ProgramFile PinParentsFor(string path) {
      var item = new ProgramFile();
      try { item.PinParents(path, true); return item; }
      catch { item.Dispose(); throw; }
    }
    public void Delete() {
      byte value = 1;
      if (!SetFileInformationByHandle(stream.SafeFileHandle, 4, ref value, 1))
        throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot remove verified program file.");
    }
    public static void RemoveEmptyDirectory(string path) {
      using (var item = new ProgramFile()) {
        item.PinParents(path, false);
        using (var handle = CreateFile(path, 0x10080, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
          Check(handle, path, true);
          // Delete this verified directory object, never a re-resolved path.
          // Windows rejects nonempty directories, including late arrivals.
          byte value = 1;
          if (!SetFileInformationByHandle(handle, 4, ref value, 1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot remove verified empty directory.");
        }
      }
    }
    public string ReadUtf8Text(long maxBytes) {
      if (stream.Length > maxBytes) throw new IOException("Verified metadata exceeds its size limit.");
      stream.Position = 0;
      try {
        using (var reader = new StreamReader(stream, new UTF8Encoding(false, true), false, 4096, true))
          return reader.ReadToEnd();
      } finally { stream.Position = 0; }
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
    // Inno holds its DAT exclusively while synchronously waiting for this
    // helper. Read a read-only duplicate of that same verified caller's handle;
    // never close its handle, relax sharing/ACLs, inject code or write data.
    // Duplicate handles share a file position, so restore it before returning.
    public static void VerifyInnoData(int pid, string image, long created,
      string path, long length, string sha256) {
      if (IntPtr.Size != 8) throw new IOException("64-bit metadata verification is required.");
      var process = OpenProcess(0x440, false, pid); // query information + duplicate handle
      if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
      IntPtr snapshot = IntPtr.Zero, marker = IntPtr.Zero;
      try {
        var name = new StringBuilder(32768); uint size = (uint)name.Capacity;
        long birth, end, kernel, user;
        if (!QueryFullProcessImageName(process, 0, name, ref size) ||
            !GetProcessTimes(process, out birth, out end, out kernel, out user) ||
            birth != created || !String.Equals(name.ToString(), image, StringComparison.OrdinalIgnoreCase))
          throw new IOException("The active Inno caller changed.");
        uint error = PssCaptureSnapshot(process, 4, 0, out snapshot); // handles only, no memory/threads
        if (error != 0) throw new Win32Exception((int)error);
        error = PssWalkMarkerCreate(IntPtr.Zero, out marker);
        if (error != 0) throw new Win32Exception((int)error);
        for (int count = 0; count < 8192; count++) {
          HandleEntry entry;
          error = PssWalkSnapshot(snapshot, 2, marker, out entry, (uint)Marshal.SizeOf(typeof(HandleEntry)));
          if (error == 259) break;
          if (error != 0) throw new Win32Exception((int)error);
          SafeFileHandle duplicate;
          if (!DuplicateHandle(process, entry.Handle, GetCurrentProcess(), out duplicate, 0x100081, false, 0)) continue;
          using (duplicate) {
            if (GetFileType(duplicate) != 1) continue;
            try { Check(duplicate, path, false); } catch (IOException) { continue; } catch (Win32Exception) { continue; }
            using (var input = new FileStream(duplicate, FileAccess.Read)) {
              long position = input.Position;
              try {
                if (input.Length != length) throw new IOException("Inno DAT length changed.");
                input.Position = 0;
                using (var hash = SHA256.Create()) {
                  var digest = BitConverter.ToString(hash.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
                  if (digest != sha256) throw new IOException("Inno DAT failed its committed SHA-256.");
                }
              } finally { input.Position = position; }
            }
            return;
          }
        }
        throw new IOException("The verified Inno caller does not own this DAT handle.");
      } finally {
        if (marker != IntPtr.Zero) PssWalkMarkerFree(marker);
        if (snapshot != IntPtr.Zero) PssFreeSnapshot(GetCurrentProcess(), snapshot);
        CloseHandle(process);
      }
    }
    public void Dispose() {
      if (stream != null) { stream.Dispose(); stream = null; }
      for (int i = parents.Count - 1; i >= 0; --i) parents[i].Dispose();
      parents.Clear();
    }
  }
}
