# Shikimori API wrappers with disk cache + self-contained retry logic

function Get-ShikiAnimeDisplayTitle {
  param($Obj)
  if (-not $Obj) { return '?' }
  $ru = $Obj.russian
  $en = $Obj.name
  if ($ru -and "$ru".Trim()) { return $ru.Trim() }
  if ($en -and "$en".Trim()) { return $en.Trim() }
  return ('id {0}' -f $Obj.id)
}

function Write-ShikiLogOnly {
  param([string]$TranscriptPath, [string]$Line)
  if ([string]::IsNullOrWhiteSpace($TranscriptPath)) { return }
  try {
    Add-Content -LiteralPath $TranscriptPath -Value $Line -Encoding utf8 -ErrorAction Stop
  } catch { }
}

function Write-ShikiAnimeConsole {
  param([int]$Id, $Data, [ValidateSet('кэш','API')][string]$Source)
  $t = Get-ShikiAnimeDisplayTitle $Data
  if ($t.Length -gt 90) { $t = $t.Substring(0, 87) + '...' }
  Write-Host ("  {0,6}  {1}  [{2}]" -f $Id, $t, $Source)
}

function Invoke-JsonWithRetry {
  param(
    [string]$Url,
    [hashtable]$Headers,
    [string]$Method = 'GET',
    [int]$MaxRetries = 8,
    [int]$BaseDelayMs = 800
  )
  $attempt = 0
  while ($true) {
    try {
      return Invoke-RestMethod -Uri $Url -Headers $Headers -Method $Method -ErrorAction Stop
    } catch {
      $attempt++
      $status = $null; $retryAf = $null
      if ($_.Exception -and $_.Exception.Response) {
        try { $status  = $_.Exception.Response.StatusCode.value__ } catch {}
        try {
          $h = $_.Exception.Response.Headers
          if ($h -and $h['Retry-After']) { $retryAf = $h['Retry-After'] | Select-Object -First 1 }
        } catch {}
      }
      if ($status -eq 429 -or $status -eq 503) {
        $delayMs = $null
        if ($retryAf) {
          if ($retryAf -match '^\d+$') { $delayMs = [int]$retryAf*1000 }
          else {
            try { $date=[datetime]::Parse($retryAf); $delayMs=[int]([math]::Max(0,($date-(Get-Date)).TotalMilliseconds)) } catch {}
          }
        }
        if (-not $delayMs) { $delayMs = [int]([math]::Min(60000, $BaseDelayMs * [math]::Pow(2,[double]$attempt))) }
        Start-Sleep -Milliseconds $delayMs
        if ($attempt -lt $MaxRetries) { continue }
      }
      throw
    }
  }
}

function Get-ShikiProfile {
  param([string]$Base,[pscustomobject]$Tokens,[string]$UA = 'ShikiSync')
  $hdr = @{
    'Authorization' = "Bearer $($Tokens.access_token)"
    'User-Agent'    = $UA
    'Accept'        = 'application/json'
  }
  return (Invoke-JsonWithRetry -Url "$Base/api/users/whoami" -Headers $hdr -Method GET)
}

function Get-ShikiAllRates {
  param([string]$Base,[pscustomobject]$Tokens,[string]$UA = 'ShikiSync',[int]$UserId,[int]$Limit=200,[int]$MaxPages=1000)
  $hdr = @{
    'Authorization' = "Bearer $($Tokens.access_token)"
    'User-Agent'    = $UA
    'Accept'        = 'application/json'
  }
  $all=@(); $page=1
  while($page -le $MaxPages){
    $url="$Base/api/users/$UserId/anime_rates?limit=$Limit&page=$page"
    $chunk = Invoke-JsonWithRetry -Url $url -Headers $hdr -Method GET
    if(-not $chunk){ break }
    $all += $chunk
    if(($chunk|Measure-Object).Count -lt $Limit){ break }
    $page++
  }
  return ($all | Sort-Object -Property id -Unique)
}

function Get-ShikiAnimeOne {
  param(
    [string]$Base,
    [pscustomobject]$Tokens,
    [string]$UA = 'ShikiSync',
    [int]$Id
  )
  $hdr = @{
    'Authorization' = "Bearer $($Tokens.access_token)"
    'User-Agent'    = $UA
    'Accept'        = 'application/json'
  }
  return (Invoke-JsonWithRetry -Url "$Base/api/animes/$Id" -Headers $hdr -Method GET)
}

function Get-ShikiDetailsBatched {
  param(
    [int[]]$Ids,
    [pscustomobject]$Tokens,
    [string]$UA = 'ShikiSync',
    [string]$Base,
    [int]$BatchSize=50,
    [int]$Throttle=3,
    [string]$CacheDir,
    [int]$CacheTtlHours = 336,
    [int]$ProgressStep = 5,
    [int]$ProgressTotal = 8,
    [string]$TranscriptPath = $null,
    [string]$ModulePath = $null,
    [switch]$VerboseCacheLog
  )
  $hdr = @{
    'Authorization' = "Bearer $($Tokens.access_token)"
    'User-Agent'    = $UA
    'Accept'        = 'application/json'
  }

  if($CacheDir){
    try{ New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }catch{}
  }
  Write-Host ("Кэш деталей: {0}" -f $CacheDir)
  if ($TranscriptPath) { Write-ShikiLogOnly -TranscriptPath $TranscriptPath -Line ('# Get-ShikiDetailsBatched: CACHE_DIR={0}' -f $CacheDir) }

  $now = Get-Date
  $out=@{}
  $cacheWritten = 0
  $cacheFailed = 0
  $cacheDeleted = 0
  $processedTotal = 0
  $idTotal = [math]::Max(1, $Ids.Count)

  for($i=0;$i -lt $Ids.Count;$i+=$BatchSize){
    $slice = $Ids[$i..([math]::Min($i+$BatchSize-1,$Ids.Count-1))]
    $batchEnd = [math]::Min($i+$BatchSize,$Ids.Count)

    $pending = New-Object System.Collections.Generic.List[Object]
    foreach($aid in $slice){
      $aid = [int]$aid
      $cached = $false
      if($CacheDir){
        $p = Join-Path $CacheDir ("{0}.json" -f $aid)
        if(Test-Path $p){
          try{
            $fi = Get-Item $p
            if($fi.LastWriteTimeUtc -gt ($now.ToUniversalTime().AddHours(-$CacheTtlHours))){
              $data = Get-Content -Raw $p | ConvertFrom-Json -ErrorAction SilentlyContinue
              if($data -and $data.id){
                $out[$aid] = $data
                $cached = $true
                $processedTotal++
                Write-ShikiAnimeConsole -Id $aid -Data $data -Source 'кэш'
                Write-Progress -Id 1 -Activity ("Шаг {0}/{1} — детали аниме" -f $ProgressStep, $ProgressTotal) -Status ("Обработано {0} из {1}" -f $processedTotal, $Ids.Count) -CurrentOperation ("Из кэша: id {0}" -f $aid) -PercentComplete ([int]([math]::Min(100, 100.0 * $processedTotal / $idTotal)))
              }
            }
          }catch{}
        }
      }
      if(-not $cached){ $pending.Add($aid) | Out-Null }
    }

    if($pending.Count -eq 0){ continue }

    $useParallel = ($PSVersionTable.PSVersion.Major -ge 7) -and ($Throttle -gt 1) -and (-not [string]::IsNullOrWhiteSpace($ModulePath)) -and (Test-Path -LiteralPath $ModulePath)
    if ($useParallel) {
      Write-Host ("  Параллельные запросы к API: до {0} одновременно (PS {1})" -f $Throttle, $PSVersionTable.PSVersion)
      $pendArr = @($pending)
      $fetchResults = $pendArr | ForEach-Object -Parallel {
        $aid = [int]$_
        Import-Module $using:ModulePath -Force -DisableNameChecking
        try {
          $d = Get-ShikiAnimeOne -Base $using:Base -Tokens $using:Tokens -UA $using:UA -Id $aid
          [pscustomobject]@{ Id = $aid; Data = $d; Err = $null }
        } catch {
          [pscustomobject]@{ Id = $aid; Data = $null; Err = $_.Exception.Message }
        }
      } -ThrottleLimit $Throttle

      foreach ($row in $fetchResults) {
        $aid = [int]$row.Id
        $data = $row.Data
        if ($null -ne $row.Err) {
          Write-Host "API_ERROR: ID=$aid error=$($row.Err)"
          Write-ShikiLogOnly -TranscriptPath $TranscriptPath -Line "API_ERROR: ID=$aid error=$($row.Err)"
        }
        elseif ($data -and $data.id -and $data.name) {
          $out[$aid] = $data
          if ($CacheDir) {
            try {
              $cachePath = Join-Path $CacheDir ("{0}.json" -f $aid)
              $json = $data | ConvertTo-Json -Depth 10 -Compress:$false -ErrorAction Stop
              $json | Out-File -Encoding utf8 -FilePath $cachePath -Force -ErrorAction Stop
              $cacheWritten++
              Write-ShikiLogOnly -TranscriptPath $TranscriptPath -Line "CACHE_OK: ID=$aid"
              if ($VerboseCacheLog) { Write-ShikiLogOnly -TranscriptPath $TranscriptPath -Line "VERBOSE CACHE_OK (API write): ID=$aid" }
            } catch {
              $cacheFailed++
              Write-Host "CACHE_FAIL: ID=$aid error=$_"
            }
          }
        } else {
          Write-Host "CACHE_NO_DATA: ID=$aid (empty or no name)"
          Write-ShikiLogOnly -TranscriptPath $TranscriptPath -Line "CACHE_NO_DATA: ID=$aid (empty or no name)"
        }
        if ($data -and $data.id -and $data.name) {
          Write-ShikiAnimeConsole -Id $aid -Data $data -Source 'API'
        }
        $processedTotal++
        Write-Progress -Id 1 -Activity ("Шаг {0}/{1} — детали аниме" -f $ProgressStep, $ProgressTotal) -Status ("Обработано {0} из {1}" -f $processedTotal, $Ids.Count) -CurrentOperation ("API: id {0}" -f $aid) -PercentComplete ([int]([math]::Min(100, 100.0 * $processedTotal / $idTotal)))
      }
    }
    else {
      if (($PSVersionTable.PSVersion.Major -lt 7) -or ($Throttle -le 1)) {
        Write-Host "  Детали через API: по одному запросу (параллельность выключена или PS < 7)."
      } elseif ([string]::IsNullOrWhiteSpace($ModulePath) -or -not (Test-Path -LiteralPath $ModulePath)) {
        Write-Host "  Параллельность пропущена: не передан путь к shiki.shiki.psm1."
      }
      foreach($aid in $pending){
        $aid = [int]$aid
        $data = $null
        try{
          $data = Get-ShikiAnimeOne -Base $Base -Tokens $Tokens -UA $UA -Id $aid
          if($data -and $data.id -and $data.name){
            $out[$aid]=$data
            if($CacheDir){
              try{
                $cachePath = Join-Path $CacheDir ("{0}.json" -f $aid)
                $json = $data | ConvertTo-Json -Depth 10 -Compress:$false -ErrorAction Stop
                $json | Out-File -Encoding utf8 -FilePath $cachePath -Force -ErrorAction Stop
                $cacheWritten++
                Write-ShikiLogOnly -TranscriptPath $TranscriptPath -Line "CACHE_OK: ID=$aid"
                if ($VerboseCacheLog) { Write-ShikiLogOnly -TranscriptPath $TranscriptPath -Line "VERBOSE CACHE_OK (API write): ID=$aid" }
              }catch{
                $cacheFailed++
                Write-Host "CACHE_FAIL: ID=$aid error=$_"
              }
            }
          } else {
            Write-Host "CACHE_NO_DATA: ID=$aid (empty or no name)"
            Write-ShikiLogOnly -TranscriptPath $TranscriptPath -Line "CACHE_NO_DATA: ID=$aid (empty or no name)"
          }
        }catch{
          Write-Host "API_ERROR: ID=$aid error=$_"
          Write-ShikiLogOnly -TranscriptPath $TranscriptPath -Line "API_ERROR: ID=$aid error=$_"
        }
        finally {
          if ($data -and $data.id -and $data.name) {
            Write-ShikiAnimeConsole -Id $aid -Data $data -Source 'API'
          }
          $processedTotal++
          Write-Progress -Id 1 -Activity ("Шаг {0}/{1} — детали аниме" -f $ProgressStep, $ProgressTotal) -Status ("Обработано {0} из {1}" -f $processedTotal, $Ids.Count) -CurrentOperation ("API: id {0}" -f $aid) -PercentComplete ([int]([math]::Min(100, 100.0 * $processedTotal / $idTotal)))
        }
      }
    }
  }
  
  Write-Progress -Id 1 -Activity ("Шаг {0}/{1} — детали аниме" -f $ProgressStep, $ProgressTotal) -Completed
  
  # Удаляем кэшированные файлы, которые больше не в списке (удалены на сайте)
  if($CacheDir -and (Test-Path $CacheDir)){
    $cachedFiles = Get-ChildItem -Path $CacheDir -Filter "*.json" -ErrorAction SilentlyContinue
    foreach($file in $cachedFiles){
      $fid = [int]($file.BaseName)
      if($fid -and -not $out.ContainsKey($fid)){
        try{
          Remove-Item -Path $file.FullName -Force -ErrorAction Stop
          $cacheDeleted++
          Write-Host "CACHE_DELETED: ID=$fid (not in current list)"
        }catch{
          Write-Host "CACHE_DELETE_FAIL: ID=$fid error=$_"
        }
      }
    }
  }
  
  Write-Host "=== CACHE SUMMARY: Written=$cacheWritten Failed=$cacheFailed Deleted=$cacheDeleted Total=$($out.Count) ==="
  return $out
}

Export-ModuleMember -Function Get-ShikiProfile,Get-ShikiAllRates,Get-ShikiAnimeOne,Get-ShikiDetailsBatched
