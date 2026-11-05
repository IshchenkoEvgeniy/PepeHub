param([switch]$Configure)
$ErrorActionPreference = 'Stop'
$data = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'reminder.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$taskName = 'PepeHub.GoalReminder.' + $identity.User.Value
$appId = 'app.pepehub.reminders'
if ($Configure) {
    if (-not $data.enabled) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
        exit 0
    }
    if ([int]$data.minute -lt 0 -or [int]$data.minute -ge 1440) { throw 'Invalid reminder time' }
    # A desktop toast needs a Start-menu shortcut with an AppUserModelID.
    $folder = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    $link = Join-Path $folder 'PepeHub reminders.lnk'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    $shortcut.TargetPath = [string]$data.exe
    $shortcut.WorkingDirectory = Split-Path -Parent ([string]$data.exe)
    $shortcut.IconLocation = [string]$data.exe
    $shortcut.Description = 'PepeHub'
    $shortcut.Save()
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential, Pack=4)] public struct ReminderKey { public Guid fmtid; public uint pid; }
[StructLayout(LayoutKind.Explicit, Size=24)] public struct ReminderVariant {
  [FieldOffset(0)] public ushort vt;
  [FieldOffset(8)] public IntPtr ptr;
}
[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ReminderProperties {
  [PreserveSig] int GetCount(out uint count);
  [PreserveSig] int GetAt(uint index, out ReminderKey key);
  [PreserveSig] int GetValue(ref ReminderKey key, out ReminderVariant value);
  [PreserveSig] int SetValue(ref ReminderKey key, ref ReminderVariant value);
  [PreserveSig] int Commit();
}
public static class ReminderShortcut {
  [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=true)]
  static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr bind, uint flags, ref Guid iid, out ReminderProperties store);
  [DllImport("ole32.dll")] static extern int PropVariantClear(ref ReminderVariant value);
  public static void SetId(string path, string id) {
    Guid iid = new Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");
    ReminderProperties store;
    Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 2, ref iid, out store));
    var key = new ReminderKey { fmtid = new Guid("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3"), pid = 5 };
    var value = new ReminderVariant { vt = 31, ptr = Marshal.StringToCoTaskMemUni(id) };
    try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); Marshal.ThrowExceptionForHR(store.Commit()); }
    finally { PropVariantClear(ref value); Marshal.ReleaseComObject(store); }
  }
}
'@
    [ReminderShortcut]::SetId($link, $appId)
    $scriptPath = $MyInvocation.MyCommand.Path
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Daily -At ([DateTime]::Today.AddMinutes([int]$data.minute))
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    exit 0
}
if (-not $data.enabled) { exit 0 }
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null
$body = [Security.SecurityElement]::Escape([string]$data.body)
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>PepeHub</text><text>' + $body + '</text></binding></visual></toast>')
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
$toast.Tag = 'goals'
$toast.Group = 'PepeHub'
$toast.ExpirationTime = [DateTimeOffset]::Now.AddHours(2)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
