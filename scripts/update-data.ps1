<#
  update-data.ps1
  Consulta la API REST de Windsor.ai para la cuenta GNP (Aseguradora Intermediario CANTEC)
  y genera data.json que consume el dashboard. Pensado para correr en GitHub Actions (pwsh).

  Requiere variable de entorno: WINDSOR_API_KEY
  Uso local:  $env:WINDSOR_API_KEY="..."; ./scripts/update-data.ps1
#>
$ErrorActionPreference = "Stop"

$apiKey  = $env:WINDSOR_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw "Falta WINDSOR_API_KEY en el entorno." }

$account   = "993894886753623"            # Aseguradora Intermediario CANTEC (GNP Auto)
$dateFrom  = "2026-05-21"                  # inicio de la campaña
$dateTo    = (Get-Date).ToString("yyyy-MM-dd")
$outFile   = Join-Path $PSScriptRoot "..\data.json"

function Get-Windsor([string]$fields) {
  $url = "https://connectors.windsor.ai/facebook?api_key=$apiKey&date_from=$dateFrom&date_to=$dateTo&fields=$fields"
  $resp = Invoke-RestMethod -Uri $url -TimeoutSec 120
  # Filtra a la cuenta GNP (el parámetro account_id de la URL no filtra del lado servidor)
  return @($resp.data | Where-Object { $_.account_id -eq $account })
}
function N($v) { if ($null -eq $v) { return 0 } else { return [double]$v } }
function Sum($rows, $field) { ($rows | ForEach-Object { N $_.$field } | Measure-Object -Sum).Sum }

# ---------- 1) Totales ----------
$tot = Get-Windsor "account_id,campaign,spend,impressions,reach,clicks,link_clicks,actions_lead,actions_onsite_conversion_messaging_conversation_started_7d"
$spend   = Sum $tot "spend"
$impr    = Sum $tot "impressions"
$reach   = Sum $tot "reach"
$clicks  = Sum $tot "clicks"
$lclicks = Sum $tot "link_clicks"
$leads   = Sum $tot "actions_lead"
$msgs    = Sum $tot "actions_onsite_conversion_messaging_conversation_started_7d"
$days    = ([datetime]$dateTo - [datetime]$dateFrom).Days + 1

$kpis = [ordered]@{
  leads        = [int]$leads
  cpl          = if ($leads) { [math]::Round($spend/$leads,2) } else { 0 }
  spend        = [math]::Round($spend,0)
  reach        = [int]$reach
  frequency    = if ($reach) { [math]::Round($impr/$reach,2) } else { 0 }
  impressions  = [int]$impr
  cpm          = if ($impr) { [math]::Round($spend/$impr*1000,0) } else { 0 }
  linkClicks   = [int]$lclicks
  ctr          = if ($impr) { [math]::Round($clicks/$impr*100,2) } else { 0 }
  cpc          = if ($lclicks) { [math]::Round($spend/$lclicks,1) } else { 0 }
  convRate     = if ($lclicks) { [math]::Round($leads/$lclicks*100,1) } else { 0 }
  conversations= [int]$msgs
  leadsPerDay  = if ($days) { [math]::Round($leads/$days,1) } else { 0 }
  spendPerDay  = if ($days) { [math]::Round($spend/$days,0) } else { 0 }
  days         = $days
}

# ---------- 2) Serie diaria ----------
$daily = Get-Windsor "account_id,date,spend,impressions,actions_lead"
$dailyArr = @($daily | Group-Object date | Sort-Object Name | ForEach-Object {
  $sp = Sum $_.Group "spend"; $im = Sum $_.Group "impressions"
  [ordered]@{ date=$_.Name; spend=[math]::Round($sp,2); leads=[int](Sum $_.Group "actions_lead"); cpm= if($im){[math]::Round($sp/$im*1000,0)}else{0} }
})

# ---------- 3) Edad / género ----------
$ag = Get-Windsor "account_id,age,gender,spend,link_clicks,actions_lead"
$ages = @("18-24","25-34","35-44","45-54","55-64","65+")
$male   = @($ages | ForEach-Object { $a=$_; [int](Sum (@($ag | Where-Object { $_.age -eq $a -and $_.gender -eq "male" })) "actions_lead") })
$female = @($ages | ForEach-Object { $a=$_; [int](Sum (@($ag | Where-Object { $_.age -eq $a -and $_.gender -eq "female" })) "actions_lead") })

# Tabla de segmentos: hombres por edad + mujeres (todas)
$segments = @()
foreach ($a in $ages) {
  $g = @($ag | Where-Object { $_.age -eq $a -and $_.gender -eq "male" })
  $sl = [int](Sum $g "actions_lead"); $ss = Sum $g "spend"
  if ($sl -gt 0) { $segments += [ordered]@{ label="Hombres $a"; spend=[math]::Round($ss,0); leads=$sl; cpl=[math]::Round($ss/$sl,1) } }
}
$fem = @($ag | Where-Object { $_.gender -eq "female" })
$fl = [int](Sum $fem "actions_lead"); $fs = Sum $fem "spend"
if ($fl -gt 0) { $segments += [ordered]@{ label="Mujeres (todas)"; spend=[math]::Round($fs,0); leads=$fl; cpl=[math]::Round($fs/$fl,1) } }
$segments = @($segments | Sort-Object { $_.leads } -Descending)
# marca el mejor CPL
if ($segments.Count) { $best = ($segments | Sort-Object { $_.cpl })[0].label }
foreach ($s in $segments) { $s.tier = if ($s.label -eq $best) { "best" } else { "" } }

# ---------- 4) Regiones (top 7 + resto) ----------
$reg = Get-Windsor "account_id,region,spend"
$regGrouped = @($reg | Group-Object region | ForEach-Object { [ordered]@{ region=$_.Name; spend=[math]::Round((Sum $_.Group "spend"),0) } } | Sort-Object { $_.spend } -Descending)
$top = @($regGrouped | Select-Object -First 7)
$rest = ($regGrouped | Select-Object -Skip 7 | ForEach-Object { $_.spend } | Measure-Object -Sum).Sum
$regions = @($top)
if ($rest -gt 0) { $regions += [ordered]@{ region="__RESTO__"; spend=[math]::Round($rest,0) } }

# ---------- 5) Artes (por anuncio) ----------
$adMap = @{
  "Nuevo anuncio de Clientes potenciales" = "nuevo"
  "Auto Chocado 1Prueba"                  = "chocado1"
  "Auto Chocado 2Prueba"                  = "chocado2"
}
$ads = Get-Windsor "account_id,ad_name,spend,impressions,clicks,link_clicks,actions_lead,actions_onsite_conversion_messaging_conversation_started_7d"
$artesRaw = @($ads | Group-Object ad_name | ForEach-Object {
  $sp=Sum $_.Group "spend"; $im=Sum $_.Group "impressions"; $cl=Sum $_.Group "clicks"
  $ld=[int](Sum $_.Group "actions_lead"); $cv=[int](Sum $_.Group "actions_onsite_conversion_messaging_conversation_started_7d")
  [ordered]@{
    id   = if ($adMap.ContainsKey($_.Name)) { $adMap[$_.Name] } else { ($_.Name -replace '\W','').ToLower() }
    adName = $_.Name
    leads=$ld; spend=[math]::Round($sp,0)
    cpl= if($ld){[math]::Round($sp/$ld,2)}else{0}
    ctr= if($im){[math]::Round($cl/$im*100,2)}else{0}
    conversations=$cv
    pct= if($leads){[math]::Round($ld/$leads*100,0)}else{0}
  }
})
$artes = @($artesRaw | Sort-Object { $_.leads } -Descending)
# tier (ascii) — el texto bonito y emojis los pone el index.html
for ($i=0; $i -lt $artes.Count; $i++) {
  $artes[$i].rankNum = $i + 1
  if ($i -eq 0)                   { $artes[$i].tier = "win" }
  elseif ($artes[$i].leads -le 2) { $artes[$i].tier = "low" }
  else                            { $artes[$i].tier = "mid" }
}

# ---------- Ensamblar y guardar ----------
$data = [ordered]@{
  updatedAt  = $dateTo
  periodFrom = $dateFrom
  periodTo   = $dateTo
  account    = $account
  kpis       = $kpis
  daily      = $dailyArr
  demo       = [ordered]@{ ages=$ages; male=$male; female=$female }
  segments   = $segments
  regions    = $regions
  artes      = $artes
}
$json = $data | ConvertTo-Json -Depth 8
$resolved = [IO.Path]::GetFullPath($outFile)
[IO.File]::WriteAllText($resolved, $json, [Text.UTF8Encoding]::new($false))
Write-Host "data.json generado: leads=$($kpis.leads) cpl=$($kpis.cpl) spend=$($kpis.spend) artes=$($artes.Count) dias=$($kpis.days)"
