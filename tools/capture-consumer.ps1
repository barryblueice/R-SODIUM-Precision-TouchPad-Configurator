param(
    [int]$Seconds = 30,
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\verification\consumer-input.log')
)
$ErrorActionPreference = 'Stop'
if ($Seconds -lt 1 -or $Seconds -gt 60) { throw 'Capture duration must be 1..60 seconds.' }
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
Add-Type @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;
public static class ConsumerCapture {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
 static void Log(StreamWriter log, string text) { Console.WriteLine(text); log.WriteLine(text); }
 public static void Run(string path, int seconds, string outputPath) {
  using(var log = new StreamWriter(outputPath, false)) {
  log.AutoFlush = true;
  using(var handle = CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero)) {
   if(handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   using(var stream = new FileStream(handle, FileAccess.Read, 65, true))
   using(var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds))) {
    Log(log, "CAPTURE_READY " + DateTime.UtcNow.ToString("O"));
    var buffer = new byte[65];
    int count=0;
    try {
     while(true) {
      int n=stream.ReadAsync(buffer,0,buffer.Length,timeout.Token).GetAwaiter().GetResult();
      if(n==0) break;
      Log(log, DateTime.UtcNow.ToString("O") + " " + BitConverter.ToString(buffer,0,n));
      count++;
     }
    } catch(OperationCanceledException) { }
    Log(log, "CAPTURE_DONE reports="+count);
   }
  }
  }
 }
}
"@
$devices = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^HID\\VID_0D00&PID_072C&MI_02&COL02\\' })
if ($devices.Count -ne 1) { throw "Expected one Consumer collection, found $($devices.Count)" }
$devicePath = '\\?\' + $devices[0].InstanceId.Replace('\','#') + '#{4d1e55b2-f16f-11cf-88cb-001111000030}'
[ConsumerCapture]::Run($devicePath,$Seconds,$OutputPath)
