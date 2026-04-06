# OAuth и заголовки

function Refresh-AccessToken {
  param([pscustomobject]$Cfg,[string]$Base,[string]$UA)
  $now = [int][double]::Parse((Get-Date -UFormat %s))
  if ($Cfg.expires_at -le $now + 60) {
    $body = "grant_type=refresh_token&client_id=$($Cfg.client_id)&client_secret=$($Cfg.client_secret)&refresh_token=$($Cfg.refresh_token)"
    $resp = Invoke-RestMethod -Uri "$Base/oauth/token" -Method Post -Headers @{ "User-Agent" = $UA } -ContentType "application/x-www-form-urlencoded" -Body $body -ErrorAction Stop
    $Cfg.access_token  = $resp.access_token
    $Cfg.refresh_token = $resp.refresh_token
    $Cfg.expires_at    = $now + [int]$resp.expires_in
  }
  return $Cfg
}

function Get-ShikiTokens {
  param([string]$Path,[string]$Base,[string]$UA)
  if(-not (Test-Path $Path)){ throw "Tokens file not found: $Path" }
  $cfg = Get-Content -Raw $Path | ConvertFrom-Json
  $cfg = Refresh-AccessToken -Cfg $cfg -Base $Base -UA $UA
  try{ ($cfg | ConvertTo-Json -Depth 5) | Out-File -Encoding utf8 $Path }catch{}
  return $cfg
}

function New-ShikiHeaders {
  param([pscustomobject]$Tokens,[string]$UA)
  return @{
    "Authorization" = "Bearer $($Tokens.access_token)"
    "User-Agent"    = $UA
    "Accept"        = "application/json"
  }
}

Export-ModuleMember -Function Refresh-AccessToken,Get-ShikiTokens,New-ShikiHeaders
