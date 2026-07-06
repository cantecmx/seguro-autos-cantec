<#
  update-data.ps1
  Consulta la API REST de Windsor.ai para la cuenta GNP (Aseguradora Intermediario CANTEC)
  y genera data.json (estructura por meses) que consume el dashboard.
  Pensado para correr en GitHub Actions (pwsh).

  Requiere variable de entorno: WINDSOR_API_KEY
  Uso local:  $env:WINDSOR_API_KEY="..."; ./scripts/update-data.ps1

  Reglas de meses:
   - "Junio" = campaña completa hasta hoy (incluye el arranque del 21-may).
   - Julio en adelante = solo ese mes calendario; se desbloquean al iniciar el mes.
   - Mes por defecto = mes en curso.
#>
$ErrorActionPreference = "Stop"

$apiKey = $env:WINDSOR_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw "Falta WINDSOR_API_KEY en el entorno." }

$account     = "993894886753623"     # Aseguradora Intermediario CANTEC (GNP Auto)
$campaignFrom= "2026-05-21"          # inicio real de la campaña
$today       = Get-Date
$todayStr    = $today.ToString("yyyy-MM-dd")
$outFile     = Join-Path $PSScriptRoot "..\data.json"

function N($v) { if ($null -eq $v) { return 0 } else { return [double]$v } }
function Sum($rows, $field) { ($rows | ForEach-Object { N $_.$field } | Measure-Object -Sum).Sum }

function Get-Windsor([string]$fields, [string]$from, [string]$to) {
  $url = "https://connectors.windsor.ai/facebook?api_key=$apiKey&date_from=$from&date_to=$to&fields=$fields"
  $attempt = 0
  while ($true) {
    $attempt++
    try {
      # 300s por intento: la 1a consulta del día Windsor sincroniza datos frescos (lento/cold)
      $resp = Invoke-RestMethod -Uri $url -TimeoutSec 300
      return @($resp.data | Where-Object { $_.account_id -eq $account })  # filtro de cuenta client-side
    } catch {
      if ($attempt -ge 4) { throw }
      Write-Host "  Reintento $attempt (Windsor lento/cold): $($_.Exception.Message)"
      Start-Sleep -Seconds 12
    }
  }
}

function Compute-Block([string]$from, [string]$to) {
  # 1) Totales
  $tot = Get-Windsor "account_id,campaign,spend,impressions,reach,clicks,link_clicks,actions_lead,actions_onsite_conversion_messaging_conversation_started_7d" $from $to
  $spend=Sum $tot "spend"; $impr=Sum $tot "impressions"; $reach=Sum $tot "reach"
  $clicks=Sum $tot "clicks"; $lclicks=Sum $tot "link_clicks"
  $leads=Sum $tot "actions_lead"; $msgs=Sum $tot "actions_onsite_conversion_messaging_conversation_started_7d"
  $days=([datetime]$to - [datetime]$from).Days + 1

  $kpis=[ordered]@{
    leads=[int]$leads
    cpl= if($leads){[math]::Round($spend/$leads,2)}else{0}
    spend=[math]::Round($spend,0)
    reach=[int]$reach
    frequency= if($reach){[math]::Round($impr/$reach,2)}else{0}
    impressions=[int]$impr
    cpm= if($impr){[math]::Round($spend/$impr*1000,0)}else{0}
    linkClicks=[int]$lclicks
    ctr= if($impr){[math]::Round($clicks/$impr*100,2)}else{0}
    cpc= if($lclicks){[math]::Round($spend/$lclicks,1)}else{0}
    convRate= if($lclicks){[math]::Round($leads/$lclicks*100,1)}else{0}
    conversations=[int]$msgs
    leadsPerDay= if($days){[math]::Round($leads/$days,1)}else{0}
    spendPerDay= if($days){[math]::Round($spend/$days,0)}else{0}
    days=$days
  }

  # 2) Serie diaria (con CPL y CPM)
  $daily = Get-Windsor "account_id,date,spend,impressions,actions_lead" $from $to
  $dailyArr = @($daily | Group-Object date | Sort-Object Name | ForEach-Object {
    $sp=Sum $_.Group "spend"; $im=Sum $_.Group "impressions"; $ld=[int](Sum $_.Group "actions_lead")
    [ordered]@{
      date=$_.Name; spend=[math]::Round($sp,2); leads=$ld
      cpm= if($im){[math]::Round($sp/$im*1000,0)}else{0}
      cpl= if($ld){[math]::Round($sp/$ld,2)}else{$null}
    }
  })

  # 3) Edad / género
  $ag = Get-Windsor "account_id,age,gender,spend,link_clicks,actions_lead" $from $to
  $ages=@("18-24","25-34","35-44","45-54","55-64","65+")
  $male  =@($ages|ForEach-Object{$a=$_;[int](Sum (@($ag|Where-Object{$_.age -eq $a -and $_.gender -eq "male"})) "actions_lead")})
  $female=@($ages|ForEach-Object{$a=$_;[int](Sum (@($ag|Where-Object{$_.age -eq $a -and $_.gender -eq "female"})) "actions_lead")})
  $segments=@()
  foreach($a in $ages){
    $g=@($ag|Where-Object{$_.age -eq $a -and $_.gender -eq "male"})
    $sl=[int](Sum $g "actions_lead"); $ss=Sum $g "spend"
    if($sl -gt 0){ $segments+=[ordered]@{label="Hombres $a";spend=[math]::Round($ss,0);leads=$sl;cpl=[math]::Round($ss/$sl,1)} }
  }
  $fem=@($ag|Where-Object{$_.gender -eq "female"}); $fl=[int](Sum $fem "actions_lead"); $fs=Sum $fem "spend"
  if($fl -gt 0){ $segments+=[ordered]@{label="Mujeres (todas)";spend=[math]::Round($fs,0);leads=$fl;cpl=[math]::Round($fs/$fl,1)} }
  $segments=@($segments|Sort-Object {$_.leads} -Descending)
  if($segments.Count){ $best=($segments|Sort-Object {$_.cpl})[0].label }
  foreach($s in $segments){ $s.tier= if($s.label -eq $best){"best"}else{""} }

  # 4) Regiones (top 7 + resto)
  $reg = Get-Windsor "account_id,region,spend" $from $to
  $regGrouped=@($reg|Group-Object region|ForEach-Object{[ordered]@{region=$_.Name;spend=[math]::Round((Sum $_.Group "spend"),0)}}|Sort-Object {$_.spend} -Descending)
  $regions=@($regGrouped|Select-Object -First 7)
  $rest=($regGrouped|Select-Object -Skip 7|ForEach-Object{$_.spend}|Measure-Object -Sum).Sum
  if($rest -gt 0){ $regions+=[ordered]@{region="__RESTO__";spend=[math]::Round($rest,0)} }

  # 5) Artes (por anuncio)
  $adMap=@{
    "Nuevo anuncio de Clientes potenciales"="nuevo"
    "Auto Chocado 1Prueba"="chocado1"
    "Auto Chocado 2Prueba"="chocado2"
    "Anuncio Impulsado 01 Llaves"="llaves"
    "Anuncio Motos"="motos"
  }
  $ads = Get-Windsor "account_id,ad_name,spend,impressions,clicks,link_clicks,actions_lead,actions_onsite_conversion_messaging_conversation_started_7d" $from $to
  $artesRaw=@($ads|Group-Object ad_name|ForEach-Object{
    $sp=Sum $_.Group "spend"; $im=Sum $_.Group "impressions"; $cl=Sum $_.Group "clicks"
    $ld=[int](Sum $_.Group "actions_lead"); $cv=[int](Sum $_.Group "actions_onsite_conversion_messaging_conversation_started_7d")
    [ordered]@{
      id= if($adMap.ContainsKey($_.Name)){$adMap[$_.Name]}else{($_.Name -replace '\W','').ToLower()}
      adName=$_.Name; leads=$ld; spend=[math]::Round($sp,0)
      cpl= if($ld){[math]::Round($sp/$ld,2)}else{0}
      cpConv= if($cv){[math]::Round($sp/$cv,2)}else{$null}
      ctr= if($im){[math]::Round($cl/$im*100,2)}else{0}
      conversations=$cv
      pct= if($leads){[math]::Round($ld/$leads*100,0)}else{0}
    }
  })
  $artes=@($artesRaw|Sort-Object -Property @{Expression={$_.leads};Descending=$true},@{Expression={$_.conversations};Descending=$true})
  for($i=0;$i -lt $artes.Count;$i++){
    $artes[$i].rankNum=$i+1
    if($artes[$i].leads -gt 0){
      if($i -eq 0){$artes[$i].tier="win"} elseif($artes[$i].leads -le 2){$artes[$i].tier="low"} else{$artes[$i].tier="mid"}
    } else {
      if($artes[$i].conversations -gt 0){$artes[$i].tier="conv"} else{$artes[$i].tier="low"}
    }
  }

  return [ordered]@{
    periodFrom=$from; periodTo=$to; kpis=$kpis; daily=$dailyArr
    demo=[ordered]@{ages=$ages;male=$male;female=$female}; segments=$segments; regions=$regions; artes=$artes
  }
}

# ---------- Meses de la campaña (2026) ----------
$monthDefs = @(
  @{key="2026-06";label="Junio";from=$campaignFrom},   # Junio = campaña completa (incluye mayo)
  @{key="2026-07";label="Julio";from="2026-07-01"},
  @{key="2026-08";label="Agosto";from="2026-08-01"},
  @{key="2026-09";label="Septiembre";from="2026-09-01"},
  @{key="2026-10";label="Octubre";from="2026-10-01"},
  @{key="2026-11";label="Noviembre";from="2026-11-01"},
  @{key="2026-12";label="Diciembre";from="2026-12-01"}
)

$months=@()
foreach($m in $monthDefs){
  $y=[int]$m.key.Substring(0,4); $mo=[int]$m.key.Substring(5,2)
  $monthStart=[datetime]::new($y,$mo,1)
  $monthEnd=$monthStart.AddMonths(1).AddDays(-1)
  $started = $today -ge $monthStart
  if($started){
    $to = if($today -lt $monthEnd){$todayStr}else{$monthEnd.ToString("yyyy-MM-dd")}
    Write-Host "Calculando $($m.label) ($($m.from) -> $to)..."
    $block = Compute-Block $m.from $to
    $months += [ordered]@{ key=$m.key; label=$m.label; locked=$false; data=$block }
  } else {
    $months += [ordered]@{ key=$m.key; label=$m.label; locked=$true; data=$null }
  }
}

# Mes por defecto = mes en curso si está en la lista y desbloqueado; si no, Junio
$curKey = $today.ToString("yyyy-MM")
$defaultMonth = if(($months|Where-Object{$_.key -eq $curKey -and -not $_.locked})){ $curKey } else { "2026-06" }

$data=[ordered]@{
  updatedAt=$todayStr
  account=$account
  defaultMonth=$defaultMonth
  months=$months
}
$json = $data | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText([IO.Path]::GetFullPath($outFile), $json, [Text.UTF8Encoding]::new($false))
$jun = ($months|Where-Object{$_.key -eq "2026-06"}).data
Write-Host "data.json OK | default=$defaultMonth | Junio: leads=$($jun.kpis.leads) cpl=$($jun.kpis.cpl) spend=$($jun.kpis.spend)"
