function Sanitize([string]$name){
  if(-not $name){return ""}
  ($name -replace '[\\/:*?"<>|]',' ').Trim()
}

function Build-SafeNotePath {
  param([string]$BaseDir,[int]$Id,[string]$Title)
  $prefix=("{0:D5} - " -f $Id); $suffix=".md"
  $clean=$Title -replace '[<>:"\\|?*]',' '
  $clean=$clean.Trim().TrimEnd('.')
  if([string]::IsNullOrWhiteSpace($clean) -or $clean -eq "Untitled"){ $clean="Anime $Id" }
  $maxTotal=240; $sepLen=1
  $room=$maxTotal-($BaseDir.Length+$sepLen+$prefix.Length+$suffix.Length)
  if($room -lt 20){$room=20}
  if($clean.Length -gt $room){$clean=$clean.Substring(0,$room)}
  return (Join-Path $BaseDir ($prefix+$clean+$suffix))
}

function MakeTag([string]$val){
  if(-not $val){return $null}
  $t=$val.ToLower() -replace '\s+',' ' -replace '[^\p{L}\p{Nd}]+' ,'_'
  return $t.Trim('_')
}

function Strip-Html([string]$html){
  if([string]::IsNullOrWhiteSpace($html)){ return "" }
  $t = [System.Text.RegularExpressions.Regex]::Replace($html,'<[^>]+>',' ')
  $t = [System.Net.WebUtility]::HtmlDecode($t)
  return ($t -replace '\s+',' ').Trim()
}

function Get-ScoreFromComment([string]$s,[double]$MaxScore){
  if([string]::IsNullOrWhiteSpace($s)){ return $null }
  $m=[regex]::Match($s,'(?<!\d)(\d{1,2}(?:[.,]\d{1,2})?)(?!\d)')
  if($m.Success){
    $txt=$m.Groups[1].Value -replace ',', '.'
    try{
      $v=[double]::Parse($txt,[System.Globalization.CultureInfo]::InvariantCulture)
      if($v -ge 0 -and $v -le $MaxScore){ return $v }
    }catch{}
  }
  return $null
}

function Get-RatingCanonical {
  param([string]$raw)
  if([string]::IsNullOrWhiteSpace($raw)){ return $null }
  $s = $raw.Trim()
  $code = ($s.ToLower() -replace '\s+','' -replace '[-_]','')
  switch ($code) {
    'g'     { return 'G' }
    'pg'    { return 'PG' }
    'pg13'  { return 'PG-13' }
    'r'     { return 'R-17' }
    'r17'   { return 'R-17' }
    'rplus' { return 'R+' }
    'rx'    { return 'Rx' }
    default {
      $t = $s.ToUpper()
      if ($t -match '^PG[-\s]?13$') { return 'PG-13' }
      if ($t -match '^R[-\s]?17\+?$') { return 'R-17' }
      if ($t -eq 'R+') { return 'R+' }
      if ($t -eq 'RX') { return 'Rx' }
      if ($t -eq 'G' -or $t -eq 'PG') { return $t }
      return $null
    }
  }
}

function New-AnimeNote {
  param(
    [pscustomobject]$Rate,
    [pscustomobject]$Anime,
    [string]$NotesDir,
    [string]$Vault,
    [string]$PostersDir,
    [string]$Base,
    [string]$LinkBase,
    [string]$StaticBase,
    [double]$MaxScore
  )

  $aid=$Rate.anime.id
  $linkRoot = if ([string]::IsNullOrWhiteSpace($LinkBase)) { $Base.Trim().TrimEnd('/') } else { $LinkBase.Trim().TrimEnd('/') }
  $ru=$Anime.russian; $en=$Anime.name
  $ttl=if($ru){$ru}elseif($en){$en}else{"Anime $aid"}
  if([string]::IsNullOrWhiteSpace($ttl) -or $ttl -eq "Untitled"){ $ttl="Anime $aid" }
  $safe=Sanitize $ttl
  if([string]::IsNullOrWhiteSpace($safe)){ $safe="Anime $aid" }

  # Студии
  $studios=@()
  if ($Anime.studios) {
    if ($Anime.studios -is [string]) { $studios=@([string]$Anime.studios) }
    elseif ($Anime.studios -is [array]) { $studios=@($Anime.studios | ForEach-Object { $_.name }) }
    elseif ($Anime.studios.PSObject -and $Anime.studios.name) { $studios=@([string]$Anime.studios.name) }
  }
  $primaryStudio = if ($studios.Count -gt 0) { $studios[0] } else { $null }

  # Пути и cover
  $posterPath = Join-Path $PostersDir "$aid.jpg"
  $posterRel  = $posterPath.Replace($Vault,"").TrimStart("\").Replace("\","/")

  # Функция проверки плейсхолдера
  $isMissing = {
    param($u)
    if(-not $u){ return $true }
    $s=$u.ToString().ToLower()
    return ($s -like '*/assets/globals/missing*' -or $s -like '*/missing_*')
  }

  # Основной источник + ВСЕ фоллбэки
  $posterUrls = @()
  $bases=@()
  if($Base){ $bases+=$Base }
  if($StaticBase){ $bases+=$StaticBase }
  $bases = $bases | Select-Object -Unique

  # Основной источник: image.original и image.preview
  if($Anime.image){
    $orig = $Anime.image.original
    $prev = $Anime.image.preview
    
    if($orig -and -not (& $isMissing $orig)){
      foreach($b in $bases){ $posterUrls += ( $orig.StartsWith("http") ? $orig : "$b$orig" ) }
    }
    
    if($prev -and -not (& $isMissing $prev)){
      foreach($b in $bases){ $posterUrls += ( $prev.StartsWith("http") ? $prev : "$b$prev" ) }
    }
  }

  # Фоллбэк на image.x48, x96, x148, x296
  if($posterUrls.Count -eq 0 -and $Anime.image){
    @('x296', 'x148', 'x96', 'x48') | ForEach-Object {
      if($posterUrls.Count -eq 0){
        $field = $Anime.image.$_
        if($field -and -not (& $isMissing $field)){
          foreach($b in $bases){ $posterUrls += ( $field.StartsWith("http") ? $field : "$b$field" ) }
        }
      }
    }
  }

  # 3️⃣ Фоллбэк на screenshot[0].original если основной источник пуст
  if($posterUrls.Count -eq 0 -and $Anime.screenshots -and $Anime.screenshots.Count -gt 0){
    $screenOrig = $Anime.screenshots[0].original
    if($screenOrig -and -not (& $isMissing $screenOrig)){
      foreach($b in $bases){ $posterUrls += ( $screenOrig.StartsWith("http") ? $screenOrig : "$b$screenOrig" ) }
    }
  }

  # Фоллбэк на screenshot[0] с другими размерами
  if($posterUrls.Count -eq 0 -and $Anime.screenshots -and $Anime.screenshots.Count -gt 0){
    $screen = $Anime.screenshots[0]
    @('x296', 'x148', 'x96', 'preview') | ForEach-Object {
      if($posterUrls.Count -eq 0 -and $screen.$_){
        $url = $screen.$_
        if($url -and -not (& $isMissing $url)){
          foreach($b in $bases){ $posterUrls += ( $url.StartsWith("http") ? $url : "$b$url" ) }
        }
      }
    }
  }

  # Рейтинг аудитории
  $ratingCanonical = $null
  if ($Anime.rating) { $ratingCanonical = Get-RatingCanonical $Anime.rating }
  elseif ($Anime.nsfw) { $ratingCanonical = Get-RatingCanonical $Anime.nsfw }

  # Продолжительность
  $minutes=$null
  if($Anime.average_episode_duration){ $minutes=[int]([double]$Anime.average_episode_duration/60) }
  elseif($Anime.duration){ $minutes=[int]$Anime.duration }

  # Жанры на английском (fallback на russian)
  $genres=@()
  if($Anime.genres_v2){ $genres=$Anime.genres_v2 | ForEach-Object{ if($_.name){$_.name}else{$_.russian} } }
  elseif($Anime.genres){ $genres=$Anime.genres   | ForEach-Object{ if($_.name){$_.name}else{$_.russian} } }

  # Оценка пользователя
  $myScore=$null; $scoreSource=$null
  $plain=$Rate.text
  if([string]::IsNullOrWhiteSpace($plain) -and $Rate.text_html){ $plain = Strip-Html $Rate.text_html }
  $scFromComment = Get-ScoreFromComment $plain $MaxScore
  if($scFromComment -ne $null){ $myScore=$scFromComment; $scoreSource="comment" }
  elseif($Rate.score -ne $null){ $myScore=[double]$Rate.score; $scoreSource="rate" }

  # Теги
  $tagFranchise=MakeTag $Anime.franchise
  $tagKind=MakeTag $Anime.kind
  $tagStudio=$null; if($primaryStudio){ $tagStudio=MakeTag $primaryStudio }
  $genreTags=@()
  if($genres){ $genreTags = @($genres | ForEach-Object { MakeTag $_ } | Where-Object { $_ }) }
  $baseTags=@("anime")
  if($tagFranchise){ $baseTags+=$tagFranchise }
  if($tagKind){      $baseTags+=$tagKind }
  if($tagStudio){    $baseTags+=$tagStudio }
  if($genreTags.Count -gt 0){ $baseTags += $genreTags }
  $baseTags = $baseTags | Select-Object -Unique

  # YAML
  $yaml=@()
  $yaml+="---"
  $yaml+="name: ""$ttl"""
  $yaml+=('tags: ["{0}"]' -f ($baseTags -join '","'))
  $yaml+="shikimori_id: $aid"
  $yaml+="shikimori_url: ""$linkRoot/animes/$aid"""
  $yaml+="cover: ""$posterRel"""
  if($Rate.status){        $yaml+="status: ""$($Rate.status)""" }
  if($myScore -ne $null){  $yaml+="my_score: $myScore"; $yaml+="my_score_source: ""$scoreSource""" }
  if($Anime.score){        $yaml+="shikimori_score: $($Anime.score)" }
  if($Anime.episodes){     $yaml+="episodes: $($Anime.episodes)" }
  if($minutes){            $yaml+="minutes_per_ep: $minutes" }
  if($Anime.aired_on){     $yaml+="aired_on: ""$($Anime.aired_on)""" }
  if($Anime.released_on){  $yaml+="released_on: ""$($Anime.released_on)""" }
  if($primaryStudio){      $yaml+="studio: ""$primaryStudio""" }
  if($studios.Count -gt 0){ $yaml += ('studios: ["{0}"]' -f ($studios -join '","')) }
  if($genres.Count  -gt 0){ $yaml += ('genres: ["{0}"]'  -f ($genres  -join '","')) }
  if($ratingCanonical){    $yaml+="rating: ""$ratingCanonical""" }
  $yaml+="---"

  # Атомарная запись файла
  $notePath=Build-SafeNotePath -BaseDir $NotesDir -Id $aid -Title $safe
  $dir=[System.IO.Path]::GetDirectoryName($notePath)
  if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp=[System.IO.Path]::Combine($dir,[System.IO.Path]::GetRandomFileName()+".tmp")
  [System.IO.File]::WriteAllText($tmp, (($yaml -join "`r`n") + "`r`n# $ttl`r`n`r`n"), [System.Text.Encoding]::UTF8)
  for($i2=0;$i2 -lt 5;$i2++){
    try{
      if(Test-Path $notePath){Remove-Item $notePath -Force}
      Move-Item $tmp $notePath -Force
      break
    } catch { Start-Sleep -Milliseconds (200*($i2+1)) }
  }

  return @{
    PosterUrls = $posterUrls
    PosterPath = $posterPath
  }
}

Export-ModuleMember -Function Sanitize,Build-SafeNotePath,MakeTag,Strip-Html,Get-ScoreFromComment,Get-RatingCanonical,New-AnimeNote
