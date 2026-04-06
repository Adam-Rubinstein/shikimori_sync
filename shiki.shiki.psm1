# Shikimori API wrappers with disk cache + self-contained retry logic

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

function Get-ShikiDetailsBatched {
  param(
    [int[]]$Ids,
    [pscustomobject]$Tokens,
    [string]$UA = 'ShikiSync',
    [string]$Base,
    [int]$BatchSize=50,
    [int]$Throttle=3,
    [string]$CacheDir,
    [int]$CacheTtlHours = 336
  )
  $hdr = @{
    'Authorization' = "Bearer $($Tokens.access_token)"
    'User-Agent'    = $UA
    'Accept'        = 'application/json'
  }

  if($CacheDir){
    try{ New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }catch{}
  }
  Write-Host "CACHE_DIR: $CacheDir"
  
  $now = Get-Date
  $out=@{}
  $cacheWritten = 0
  $cacheFailed = 0
  $cacheDeleted = 0

  for($i=0;$i -lt $Ids.Count;$i+=$BatchSize){
    $slice = $Ids[$i..([math]::Min($i+$BatchSize-1,$Ids.Count-1))]

    try { Write-Host ("[6/8] Детали: {0}-{1} из {2}" -f $i,([math]::Min($i+$BatchSize,$Ids.Count)),$Ids.Count) } catch {}

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
              }
            }
          }catch{}
        }
      }
      if(-not $cached){ $pending.Add($aid) | Out-Null }
    }

    if($pending.Count -eq 0){ continue }

    # Последовательная обработка БЕЗ -Parallel
    foreach($aid in $pending){
      $aid = [int]$aid
      try{
        $url = "$Base/api/animes/$aid"
        $data = Invoke-JsonWithRetry -Url $url -Headers $hdr -Method GET
        
        if($data -and $data.id -and $data.name){ 
          $out[$aid]=$data
          
          if($CacheDir){
            try{
              $cachePath = Join-Path $CacheDir ("{0}.json" -f $aid)
              $json = $data | ConvertTo-Json -Depth 10 -Compress:$false -ErrorAction Stop
              $json | Out-File -Encoding utf8 -FilePath $cachePath -Force -ErrorAction Stop
              $cacheWritten++
              Write-Host "CACHE_OK: ID=$aid"
            }catch{
              $cacheFailed++
              Write-Host "CACHE_FAIL: ID=$aid error=$_"
            }
          }
        } else {
          Write-Host "CACHE_NO_DATA: ID=$aid (empty or no name)"
        }
      }catch{
        Write-Host "API_ERROR: ID=$aid error=$_"
      }
    }
  }
  
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

Export-ModuleMember -Function Get-ShikiProfile,Get-ShikiAllRates,Get-ShikiDetailsBatched
