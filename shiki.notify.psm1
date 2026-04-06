function Notify-Done {
  param([string]$Summary)
  $notified=$false
  try {
    Import-Module BurntToast -ErrorAction Stop
    $audio = New-BTAudio -Silent
    New-BurntToastNotification -Text "Shiki Sync", $Summary -Audio $audio -UniqueIdentifier "ShikiSyncDone" | Out-Null
    $notified=$true
  } catch { }
  if (-not $notified) {
    try {
      Add-Type -AssemblyName System.Windows.Forms
      [System.Windows.Forms.MessageBox]::Show($Summary,"Shiki Sync",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
    } catch { }
  }
}
Export-ModuleMember -Function Notify-Done
