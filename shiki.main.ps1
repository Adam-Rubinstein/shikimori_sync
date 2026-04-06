#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- Корень проекта ----------
$ROOT = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ROOT)) { $ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ROOT)) { $ROOT = (Get-Location).Path }

# ---------- Конфиг ----------
$ConfigPath = Join-Path $ROOT 'shiki.config.psd1'
$cfg = Import-PowerShellDataFile $ConfigPath

function Get-Cfg {
  param(
    [hashtable]$H,
    [string]$Key,
    [object]$Default = $null
  )
  if ($H -and $H.ContainsKey($Key) -and $null -ne $H[$Key] -and "$($H[$Key])" -ne '') {
    return $H[$Key]
  }
  return $Default
}

function Normalize-ShikiUrl {
  param([string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
  return $Url.Trim().TrimEnd('/')
}

# API OAuth и ссылки в заметках: задайте SiteUrl (или устаревший Base). CDN картинок: StaticUrl или StaticBase.
$_site = Normalize-ShikiUrl (Get-Cfg $cfg 'SiteUrl' $null)
if (-not $_site) { $_site = Normalize-ShikiUrl (Get-Cfg $cfg 'Base' $null) }
if (-not $_site) { $_site = 'https://shikimori.io' }
$cfg.Base = $_site

$_static = Normalize-ShikiUrl (Get-Cfg $cfg 'StaticUrl' $null)
if (-not $_static) { $_static = Normalize-ShikiUrl (Get-Cfg $cfg 'StaticBase' $null) }
if (-not $_static) { $_static = 'https://desu.shikimori.one' }
$cfg.StaticBase = $_static

$_link = Normalize-ShikiUrl (Get-Cfg $cfg 'LinkSiteUrl' $null)
if (-not $_link) { $_link = $cfg.Base }
$cfg.LinkSiteUrl = $_link

# ---------- Vault из vault.path ----------
$vaultPathFile = Join-Path $ROOT 'vault.path'
if (-not (Test-Path $vaultPathFile)) { throw "vault.path not found: $vaultPathFile" }
$vault = (Get-Content -Raw $vaultPathFile).Trim()
if ([string]::IsNullOrWhiteSpace($vault)) { throw "Vault path in vault.path is empty" }
if (-not (Test-Path $vault)) { throw "Vault directory not found: $vault" }

# Дефолты относительных подпапок в конфиге
if ([string]::IsNullOrWhiteSpace($cfg.NotesRel))   { $cfg.NotesRel   = 'Base/00_Anime' }
if ([string]::IsNullOrWhiteSpace($cfg.PostersRel)) { $cfg.PostersRel = 'Files/AnimePosters' }

# Абсолютные директории внутри Vault
$NotesDir   = Join-Path $vault $cfg.NotesRel
$PostersDir = Join-Path $vault $cfg.PostersRel
if ([string]::IsNullOrWhiteSpace($NotesDir))   { throw "NotesDir is empty (check NotesRel)" }
if ([string]::IsNullOrWhiteSpace($PostersDir)) { throw "PostersDir is empty (check PostersRel)" }

# Пути по умолчанию относительно папки скрипта (с обратной совместимостью)
$TokensPath     = if ($cfg.ContainsKey('SecretPath')     -and $cfg.SecretPath)     { $cfg.SecretPath }     else { Join-Path $ROOT 'shiki_tokens.json' }
$TranscriptPath = if ($cfg.ContainsKey('TranscriptPath') -and $cfg.TranscriptPath) { $cfg.TranscriptPath } else { Join-Path $ROOT 'shiki-sync.log' }
$CacheDir       = if ($cfg.ContainsKey('CacheDir')       -and $cfg.CacheDir)       { $cfg.CacheDir }       else { Join-Path $ROOT 'shiki_cache' }

# ---------- Подготовка папок и лог ----------
New-Item -ItemType Directory -Force -Path $NotesDir        | Out-Null
New-Item -ItemType Directory -Force -Path $PostersDir      | Out-Null
New-Item -ItemType Directory -Force -Path $CacheDir        | Out-Null
$logDir = Split-Path -Parent $TranscriptPath
if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
Start-Transcript -Path $TranscriptPath -Append

# ---------- Модули ----------
Remove-Module shiki.notes -Force -ErrorAction SilentlyContinue
Remove-Module shiki.http -Force -ErrorAction SilentlyContinue
Remove-Module shiki.oauth -Force -ErrorAction SilentlyContinue
Remove-Module shiki.shiki -Force -ErrorAction SilentlyContinue
Remove-Module shiki.notify -Force -ErrorAction SilentlyContinue

Import-Module (Join-Path $ROOT 'shiki.http.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $ROOT 'shiki.oauth.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $ROOT 'shiki.shiki.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $ROOT 'shiki.notes.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $ROOT 'shiki.notify.psm1') -Force -DisableNameChecking
$httpModulePath = Join-Path $ROOT 'shiki.http.psm1'
$shikiModulePath = Join-Path $ROOT 'shiki.shiki.psm1'
$detailBatchSize = [int](Get-Cfg $cfg 'BatchSize' 50)
$detailParallel  = [int](Get-Cfg $cfg 'DetailThrottle' 3)
if ($detailParallel -lt 1) { $detailParallel = 1 }

Write-Host "[1/8] Старт — данные с API: $($cfg.Base) (CDN постеров: $($cfg.StaticBase))"
Write-Host "[2/8] OAuth и профиль пользователя..."
$tokens  = Get-ShikiTokens -Path $TokensPath -Base $cfg.Base -UA $cfg.UA
$profile = Get-ShikiProfile -Base $cfg.Base -Tokens $tokens -UA $cfg.UA
Write-Host ("  Профиль: {0} (user id={1})" -f $profile.nickname, $profile.id)

Write-Host "[3/8] Загрузка списка оценок с сайта..."
$allRates = Get-ShikiAllRates -Base $cfg.Base -Tokens $tokens -UA $cfg.UA -UserId $profile.id
Write-Host ("  Всего записей в списке: {0}" -f $allRates.Count)

$ids = @($allRates | ForEach-Object { [int]$_.anime.id }) | Select-Object -Unique
Write-Host "[4/8] Уникальных тайтлов для карточек: $($ids.Count)"

Write-Host "[5/8] Детали аниме (кэш на диске + запросы к API; батч $detailBatchSize, параллель до $detailParallel)..."
$details = Get-ShikiDetailsBatched `
             -Base $cfg.Base `
             -Tokens $tokens `
             -UA $cfg.UA `
             -Ids $ids `
             -BatchSize $detailBatchSize `
             -Throttle $detailParallel `
             -CacheDir $CacheDir `
             -ProgressStep 5 `
             -ProgressTotal 8 `
             -TranscriptPath $TranscriptPath `
             -ModulePath $shikiModulePath

Write-Host ("  В карте деталей: {0} тайтлов" -f $details.Keys.Count)

# ---------- Параметры загрузчика постеров ----------
$cookie    = Get-Cfg $cfg 'ShikiCookie'   $null
$minBytes  = [int](Get-Cfg $cfg 'MinPosterBytes' 15000)
$cacheBust = [bool](Get-Cfg $cfg 'CacheBust' $true)
$posterPreferScreenshot = [bool](Get-Cfg $cfg 'PosterPreferScreenshot' $true)

Write-Host "[6/8] Запись заметок Markdown и очередь на скачивание постеров..."
$posterQueue = New-Object System.Collections.ArrayList

foreach($rate in $allRates){
  $aid = [int]$rate.anime.id
  if(-not $aid){ continue }

  $anime = $details[$aid]
  if(-not $anime){ continue }

  $info = New-AnimeNote `
            -Rate $rate `
            -Anime $anime `
            -NotesDir $NotesDir `
            -Vault $vault `
            -PostersDir $PostersDir `
            -Base $cfg.Base `
            -LinkBase $cfg.LinkSiteUrl `
            -StaticBase $cfg.StaticBase `
            -MaxScore $cfg.MaxScore `
            -PosterPreferScreenshot:$posterPreferScreenshot

  if($info.PosterUrls -and $info.PosterUrls.Count -gt 0 -and $info.PosterPath){
    [void]$posterQueue.Add([pscustomobject]@{
      Urls = $info.PosterUrls
      Path = $info.PosterPath
      UA   = $cfg.UA
      Cookie    = $cookie
      MinBytes  = $minBytes
      CacheBust = $cacheBust
      Referer   = ("{0}/animes/{1}" -f $cfg.Base,$aid)
      HttpModulePath = $httpModulePath
    })
  }
}

$posterResults=@()
if($posterQueue.Count -gt 0){
  Write-Host ("[7/8] Скачивание постеров: {0} файлов (параллельность {1})..." -f $posterQueue.Count, $cfg.PosterThrottle)

  if($PSVersionTable.PSVersion.Major -ge 7){
    $posterResults = $posterQueue | ForEach-Object -Parallel {
      Import-Module $_.HttpModulePath -Force -DisableNameChecking
      $ok = Download-PosterFromCandidates `
              -Urls $_.Urls `
              -Path $_.Path `
              -UA $_.UA `
              -Cookie $_.Cookie `
              -Referer $_.Referer `
              -MinBytes $_.MinBytes `
              -CacheBust:([bool]$_.CacheBust) `
              -Quiet
      [pscustomobject]@{ ok=$ok; path=$_.Path }
    } -ThrottleLimit $cfg.PosterThrottle
  }
  else{
    Import-Module $httpModulePath -Force -DisableNameChecking
    foreach($it in $posterQueue){
      $ok = Download-PosterFromCandidates `
              -Urls $it.Urls `
              -Path $it.Path `
              -UA $it.UA `
              -Cookie $it.Cookie `
              -Referer $it.Referer `
              -MinBytes $it.MinBytes `
              -CacheBust:([bool]$it.CacheBust) `
              -Quiet
      $posterResults += [pscustomobject]@{ ok=$ok; path=$it.Path }
    }
  }
}

$okCount  = @($posterResults | Where-Object { $_.ok }).Count
$allCount = $posterQueue.Count
if ($posterQueue.Count -eq 0) {
  Write-Host "[7/8] Постеры: очередь пуста (обложки не требовались или нет URL)."
}
Write-Host ("[8/8] Готово. Постеров успешно: {0}/{1}. Деталей аниме в карте: {2}." -f $okCount, $allCount, $details.Keys.Count)

Stop-Transcript