function Download-PosterFromCandidates {
  param(
    [string[]]$Urls,
    [string]$Path,
    [string]$UA = 'ShikiSync',
    [string]$Cookie = $null,
    [string]$Referer = $null,
    [int]$MinBytes = 15000,
    [bool]$CacheBust = $true,
    [switch]$Quiet
  )
  
  if (-not $Urls -or $Urls.Count -eq 0) {
    if (-not $Quiet) { Write-Host "No URLs for $Path" }
    return $false
  }
  
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) {
    try { 
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    } catch {
      return $false
    }
  }
  
  $bestAttempt = $null
  $bestSize = 0
  
  foreach ($url in $Urls) {
    if ([string]::IsNullOrWhiteSpace($url)) { continue }
    
    try {
      $uri = [System.Uri]$url
      if ($CacheBust -and $uri.Scheme -match '^https?$') {
        $busted = if ($url.Contains('?')) { "$url&t=$(Get-Date -UFormat %s)" } else { "$url?t=$(Get-Date -UFormat %s)" }
        $url = $busted
      }
      
      $hdr = @{ 'User-Agent' = $UA }
      if ($Referer) { $hdr['Referer'] = $Referer }
      if ($Cookie) { $hdr['Cookie'] = $Cookie }
      
      $tmp = [System.IO.Path]::GetTempFileName()
      try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url `
          -Headers $hdr `
          -OutFile $tmp `
          -ErrorAction Stop `
          -TimeoutSec 60 `
          -MaximumRetryCount 3 `
          -RetryIntervalSec 2
        
        $fi = Get-Item $tmp -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 0) {
          # Сохраняем лучший вариант, даже если < MinBytes
          if ($fi.Length -gt $bestSize) {
            if ($bestAttempt) { Remove-Item $bestAttempt -Force -ErrorAction SilentlyContinue }
            $bestAttempt = $tmp
            $bestSize = $fi.Length
            
            # Если больше MinBytes - сохраняем сразу
            if ($fi.Length -ge $MinBytes) {
              if (Test-Path $Path) { Remove-Item $Path -Force }
              Move-Item $tmp $Path -Force
              if (-not $Quiet) { Write-Host "✓ $Path ($($fi.Length)B)" }
              return $true
            }
          } else {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
          }
        } else {
          Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
      } catch [System.Net.WebException] {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        continue
      } catch [System.TimeoutException] {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        continue
      } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        continue
      }
    } catch {
      # pass
    }
  }
  
  # Если нет файла >= MinBytes, сохраняем лучший найденный
  if ($bestAttempt -and $bestSize -gt 0) {
    try {
      if (Test-Path $Path) { Remove-Item $Path -Force }
      Move-Item $bestAttempt $Path -Force
      if (-not $Quiet) { Write-Host "✓ $Path ($($bestSize)B, <min)" }
      return $true
    } catch {
      if (Test-Path $bestAttempt) { Remove-Item $bestAttempt -Force -ErrorAction SilentlyContinue }
    }
  }
  
  return $false
}

Export-ModuleMember -Function Download-PosterFromCandidates