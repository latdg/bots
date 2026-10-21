<#
=============================================================================
 AVISADOR DE LOTERIES — La TdG
 LoteriesLaTdG.ps1 · creat el 29.09.2026

 S'executa al portàtil de casa (Windows) amb el Programador de tasques.
 Les consultes les fa Microsoft Edge sense finestra (canvi 29.09.2026): la web
 oficial bloqueja PowerShell i curl, però no un navegador de veritat.
 Consulta les dades oficials de Loteries i Apostes de l'Estat (des de casa no
 estan bloquejades), busca on s'han venut els premis grossos de tots els jocs
 i, si algun s'ha venut a la Bisbal d'Empordà, Corçà, Cruïlles-Monells-Sant
 Sadurní de l'Heura o Forallac, envia un avís al bot privat latdg_infos.

 LOTERIES DE CATALUNYA (canvi 29.09.2026):
   Loteries de Catalunya no publica on es venen els premis (ni a l'API ni a la
   web). Quan una Grossa extraordinària o un premi gros de la 6/49 es ven a un
   poble, però, ho publica la premsa. Per això es busquen a Google Notícies les
   notícies dels últims $DiesNoticiesCat dies que parlin de la Grossa, la 6/49 o
   Loteries de Catalunya i d'algun poble de la zona, i s'avisa de les noves.

 FUNCIONAMENT:
   · Per a cada joc, demana els sorteigs dels últims $DiesEnrere dies (així, si
     el portàtil ha estat apagat, recupera els sorteigs que falten).
   · De cada premi gros obre la pàgina oficial del premi ("Puntos de venta
     relacionados") i mira on s'ha venut.
   · Recorda els premis ja revisats (fitxer a %LOCALAPPDATA%\LaTdG) per no
     avisar-ne dues vegades.

 ÚS (des d'una finestra de PowerShell, a la carpeta on hi ha aquest fitxer):
   0. Desa el testimoni i el chat_id del bot (una sola vegada; no cal editar el fitxer):
        powershell -ExecutionPolicy Bypass -File .\LoteriesLaTdG.ps1 -Configurar -Token "..." -ChatId "..."
   1. Prova, no envia res ni desa res; mostra tots els premis i on s'han venut:
        powershell -ExecutionPolicy Bypass -File .\LoteriesLaTdG.ps1 -Prova
   2. Crea la tasca programada (cada dia a $HoraTasca):
        powershell -ExecutionPolicy Bypass -File .\LoteriesLaTdG.ps1 -Instal
   3. Per treure-la:
        powershell -ExecutionPolicy Bypass -File .\LoteriesLaTdG.ps1 -Desinstal
=============================================================================
#>

param(
  [switch]$Configurar,
  [string]$Token,
  [string]$ChatId,
  [switch]$Prova,
  [switch]$Instal,
  [switch]$Desinstal
)


# -----------------------------------------------------------------------------
# CONFIGURACIÓ
# -----------------------------------------------------------------------------

# El testimoni (token) i el chat_id del bot latdg_infos es desen amb -Configurar
# al fitxer %LOCALAPPDATA%\LaTdG\loteries-config.json (no cal posar-los aquí).
$TelegramToken  = ""
$TelegramChatId = ""

# Quants dies enrere es revisen a cada execució.
$DiesEnrere = 7

# Hora de la tasca diària (els sorteigs acaben cap a les 22.00 h).
$HoraTasca = "23:15"

# Jocs de Loteries i Apostes de l'Estat (identificador: nom).
$Jocs = [ordered]@{
  "LNAC" = "Loteria Nacional"
  "BONO" = "Bonoloto"
  "LAPR" = "La Primitiva"
  "ELGR" = "El Gordo de la Primitiva"
  "EMIL" = "Euromillones"
  "EDMS" = "EuroDreams"
  "LOTU" = "Lototurf"
  "LAQU" = "La Quiniela"
  "QGOL" = "El Quinigol"
  "QUPL" = "Quíntuple Plus"
}

# Loteries de Catalunya: cerca a Google Notícies (Grossa, 6/49, Loteries de
# Catalunya + pobles de la zona). "Fonteta" no hi és per no confondre-la amb la
# Fonteta de València.
$DiesNoticiesCat = 14
$ConsultaNoticiesCat = '("Grossa" OR "6/49" OR "Loteries de Catalunya") ("Bisbal d''Empordà" OR "Corçà" OR "Cruïlles" OR "Monells" OR "Forallac" OR "Peratallada" OR "Vulpellac" OR "Casavells" OR "Canapost" OR "Sant Sadurní de l''Heura")'

# ONCE: cerca a Google Notícies (cupó, Cuponazo, Sueldazo... + pobles de la zona).
$ConsultaNoticiesOnce = '("ONCE" OR "cupó" OR "cupón" OR "Cuponazo" OR "Sueldazo" OR "Eurojackpot" OR "Triplex") ("Bisbal d''Empordà" OR "La Bisbal" OR "Corçà" OR "Cruïlles" OR "Monells" OR "Forallac" OR "Peratallada" OR "Vulpellac" OR "Casavells" OR "Canapost" OR "Sant Sadurní de l''Heura")'

# ONCE: llista de notícies oficials i nombre màxim de notes que es revisen cada nit.
$OnceNoticies = "https://www.once.es/noticias"
$OnceMaxNotes = 25

# Per trobar la frase on surt el poble dins d'un text (amb accents o sense).
$RxPoblesText = "Bisbal|Cor[çc][àa]|Cru[ïi]lles|Monells|Forallac|Peratallada|Vulpellac|Casavells|Canapost|Sadurn[íi] de l.Heura"

# Filtre del titular (en majúscules i sense accents) per a cada tipus de notícia.
$RxTitolCat  = "GROSSA|LOTERI|6/49|LOTTO"
$RxTitolOnce = "CUPON|\bCUPO\b|CUPONAZO|SUELDAZO|EUROJACKPOT|TRIPLEX|\bONCE\b.*(REPART|PREMI|EURO|€|MILIO|SORT|SUERTE)|(REPART|PREMI|EURO|€|MILIO|SORT|SUERTE).*\bONCE\b"

# Edicions de Google Notícies on es busca (català i castellà).
$EdicionsNoticies = @("hl=ca&gl=ES&ceid=ES:ca", "hl=es&gl=ES&ceid=ES:es")

# Poblacions de la zona (en majúscules, sense accents ni apòstrofs).
$Termes = @(
  "BISBAL DEMPORDA", "BISBAL DEL AMPURDAN", "CORCA", "CASAVELLS", "CRUILLES",
  "MONELLS", "SADURNI DE LHEURA", "FORALLAC", "VULPELLAC", "PERATALLADA",
  "CANAPOST", "FONTETA"
)

# Nom amb què surt cada població als avisos.
$NomsPobles = @{
  "BISBAL DEMPORDA" = "la Bisbal d'Empordà"; "BISBAL DEL AMPURDAN" = "la Bisbal d'Empordà"
  "CORCA" = "Corçà"; "CASAVELLS" = "Casavells"; "CRUILLES" = "Cruïlles"; "MONELLS" = "Monells"
  "SADURNI DE LHEURA" = "Sant Sadurní de l'Heura"; "FORALLAC" = "Forallac"; "VULPELLAC" = "Vulpellac"
  "PERATALLADA" = "Peratallada"; "CANAPOST" = "Canapost"; "FONTETA" = "Fonteta"
}

$NomTasca = "LaTdG Loteries"
$Base = "https://www.loteriasyapuestas.es"

# CANVI 21.10.2026 (GitHub): a GitHub la carpeta i la configuració les indica
# el bucle dels bots (LATDG_CARPETA, LATDG_CONFIG); al portàtil, com sempre.
$Carpeta      = if ($env:LATDG_CARPETA) { $env:LATDG_CARPETA } else { Join-Path $env:LOCALAPPDATA "LaTdG" }
$FitxerVistos = Join-Path $Carpeta "loteries-vistos.json"
$FitxerLog    = Join-Path $Carpeta "loteries.log"
$FitxerConfig = if ($env:LATDG_CONFIG) { $env:LATDG_CONFIG } else { Join-Path $Carpeta "loteries-config.json" }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Panell de la redacció (17.10.2026): cada avís enviat també es desa al panell.
$FitxerPanell = Join-Path $PSScriptRoot "PujarAlPanell.ps1"
if (Test-Path $FitxerPanell) { . $FitxerPanell }


# -----------------------------------------------------------------------------
# TASCA PROGRAMADA
# -----------------------------------------------------------------------------

if ($Instal) {
  $accio = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
  $activador = New-ScheduledTaskTrigger -Daily -At $HoraTasca
  $config = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

  Register-ScheduledTask -TaskName $NomTasca -Action $accio -Trigger $activador -Settings $config `
    -Description "Avisador de loteries de La TdG (premis venuts a la zona)" -Force | Out-Null

  Write-Host "Tasca '$NomTasca' creada: cada dia a les $HoraTasca."
  Write-Host "Si el portatil esta apagat a aquella hora, s'executara quan l'engeguis."
  exit
}

if ($Desinstal) {
  Unregister-ScheduledTask -TaskName $NomTasca -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Tasca '$NomTasca' eliminada."
  exit
}


# -----------------------------------------------------------------------------
# UTILITATS
# -----------------------------------------------------------------------------

if (-not (Test-Path $Carpeta)) { New-Item -ItemType Directory -Path $Carpeta | Out-Null }

if ($Configurar) {
  if (-not $Token -or -not $ChatId) {
    Write-Host "Cal indicar -Token i -ChatId."
    exit 1
  }
  @{ token = $Token.Trim(); chat_id = $ChatId.Trim() } | ConvertTo-Json | Set-Content -Path $FitxerConfig -Encoding UTF8
  Write-Host "Configuracio desada a $FitxerConfig"
  exit
}

if ((-not $TelegramToken -or -not $TelegramChatId) -and (Test-Path $FitxerConfig)) {
  try {
    $cfg = ConvertFrom-Json -InputObject (Get-Content -Path $FitxerConfig -Raw -Encoding UTF8)
    if (-not $TelegramToken) { $TelegramToken = $cfg.token }
    if (-not $TelegramChatId) { $TelegramChatId = $cfg.chat_id }
  } catch {}
}

function Registrar([string]$text) {
  $linia = (Get-Date).ToString("dd.MM.yyyy HH:mm:ss") + "  " + $text
  Write-Host $linia
  if (-not $Prova) { Add-Content -Path $FitxerLog -Value $linia -Encoding UTF8 }
}

# Majúscules, sense accents ni apòstrofs.
function Normalitzar([string]$t) {
  $n = $t.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $n.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
      [void]$sb.Append($c)
    }
  }
  return ($sb.ToString().ToUpper() -replace "['’``´]", "")
}

$RxTermes = "\b(" + (($Termes | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")\b"

function EsDeLaZona([string]$lloc) {
  $n = Normalitzar $lloc
  if ($n -notmatch $RxTermes) { return $false }
  if ($n -match "BISBAL DEMPORDA|BISBAL DEL AMPURDAN") { return $true }
  return ($n -match "\b(GIRONA|GERONA)\b")
}

# Descarrega una adreça amb Microsoft Edge sense finestra i en retorna l'HTML.
# (Canvi 29.09.2026: la sortida d'Edge passa per la canonada perquè PowerShell
# l'esperi; s'hi barregen avisos tècnics d'Edge, i se'n treu només l'HTML.)
function Obtenir([string]$url) {
  $tot = (& $Edge --headless=new --disable-gpu --disable-blink-features=AutomationControlled `
    --user-agent="$UA" --dump-dom $url 2>&1 | ForEach-Object { "$_" }) -join "`n"

  $i = $tot.IndexOf("<html", [StringComparison]::OrdinalIgnoreCase)
  $f = $tot.LastIndexOf("</html>", [StringComparison]::OrdinalIgnoreCase)

  if ($i -lt 0) {
    $motiu = ($tot -split "`n" | Where-Object { $_ -and $_ -notmatch "fallback_task_provider" } | Select-Object -First 2) -join " | "
    throw ("Edge no ha retornat la pàgina" + $(if ($motiu) { " (" + $motiu + ")" } else { "" }))
  }

  $html = if ($f -gt $i) { $tot.Substring($i, $f - $i + 7) } else { $tot.Substring($i) }

  if ($html -match "<title>Access Denied</title>") { throw "Access Denied (bloquejat)" }

  return $html
}

# Descarrega una adreça que retorna JSON (Edge el mostra dins d'un <pre>).
function ObtenirJson([string]$url) {
  $html = Obtenir $url
  $m = [regex]::Match($html, "<pre[^>]*>([\s\S]*?)</pre>")
  $text = if ($m.Success) { [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) } else { $html }
  return (ConvertFrom-Json -InputObject $text)
}

function EnviarTelegram([string]$text) {
  $cos = @{ chat_id = $TelegramChatId; text = $text; disable_web_page_preview = $true } | ConvertTo-Json -Compress
  try {
    Invoke-RestMethod -Uri "https://api.telegram.org/bot$TelegramToken/sendMessage" -Method Post `
      -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($cos)) -TimeoutSec 30 | Out-Null
  } catch {
    Registrar ("ERROR de Telegram: " + $_.Exception.Message)
    return $false
  }

  # Panell de la redacció (17.10.2026). Si falla, només ho diu: l'avís ja ha sortit.
  if (Get-Command Afegir-AlPanell -ErrorAction SilentlyContinue) {
    Afegir-AlPanell -Fitxer "loteries.json" -Titol "Loteries" -Textos @($text)
  }

  return $true
}

# Text net d'una pàgina (sense etiquetes ni scripts).
function TextNet([string]$html) {
  $t = $html -replace "<script[\s\S]*?</script>", " " -replace "<style[\s\S]*?</style>", " " -replace "<[^>]+>", " "
  return ([Net.WebUtility]::HtmlDecode($t) -replace "\s+", " ").Trim()
}

# Llista de vistos plana. (Canvi 11.10.2026: el PowerShell 5.1 la carregava
# com un sol element i el fitxer s'anava niant; així també es repara el fitxer.)
function AplanarVistos($x) {
  if ($null -eq $x) { return }
  if ($x -is [string]) {
    $x -split "\s+(?=https?://|once:|gn:|gt:)" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return
  }
  if ($x -is [System.Collections.IEnumerable]) { foreach ($e in $x) { AplanarVistos $e }; return }
  if ($x.PSObject.Properties["value"]) { AplanarVistos $x.value }
}

# Llocs de venda de la pàgina d'un premi ("Puntos de venta relacionados").
# (Canvi 29.09.2026: es llegeix cada enllaç "Punto de Venta" per separat; la
# descripció de la capçalera només es fa servir si no n'hi ha cap.)
function PuntsDeVenda([string]$html) {
  $punts = @()

  foreach ($p in [regex]::Matches($html, "Punto de Venta:\s*<a[^>]*>([^<]+)</a>", "IgnoreCase")) {
    $t = [Net.WebUtility]::HtmlDecode($p.Groups[1].Value).Trim()
    if ($t -and ($punts -notcontains $t)) { $punts += $t }
  }

  if ($punts.Count -eq 0) {
    $m = [regex]::Match($html, "PUNTOS DE VENTA RELACIONADOS([^""<]*)", "IgnoreCase")
    if ($m.Success) {
      foreach ($tros in ($m.Groups[1].Value -split "Punto de Venta:")) {
        $t = [Net.WebUtility]::HtmlDecode($tros).Trim()
        if ($t -and ($punts -notcontains $t)) { $punts += $t }
      }
    }
  }

  return $punts
}

# Import del premi segons el títol ("Primer", "Segundo"...) i l'escrutini.
function ImportPremi($sorteig, [string]$titol) {
  $cat = 0
  if ($titol -match "^Primer") { $cat = 1 }
  elseif ($titol -match "^Segundo") { $cat = 2 }
  elseif ($titol -match "^Tercer") { $cat = 3 }
  if ($cat -eq 0 -or -not $sorteig.escrutinio) { return "" }

  $fila = @($sorteig.escrutinio | Where-Object { $_.categoria -eq $cat })[0]
  if (-not $fila -or -not $fila.premio) { return "" }

  try {
    $valor = [decimal]::Parse(($fila.premio -replace ",", "."), [Globalization.CultureInfo]::InvariantCulture)
    return $valor.ToString("N2", [Globalization.CultureInfo]::GetCultureInfo("ca-ES")) + " €"
  } catch {
    return ""
  }
}


# -----------------------------------------------------------------------------
# REVISIÓ
# -----------------------------------------------------------------------------

if (-not $Prova -and (-not $TelegramToken -or -not $TelegramChatId)) {
  Write-Host "Falta el testimoni del bot: executa primer l'script amb -Configurar -Token ... -ChatId ... (o fes-ho amb -Prova)."
  exit 1
}

# Microsoft Edge (el que fa les consultes).
# CANVI 21.10.2026 (GitHub): a GitHub les consultes les fa Google Chrome
# (NAVEGADOR = navegador.sh); al portàtil, Microsoft Edge com sempre.
if ($env:NAVEGADOR) {
  $Edge = $env:NAVEGADOR
} else {
$Edge = @(
  (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
  (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $Edge) {
  Registrar "ERROR: no s'ha trobat Microsoft Edge."
  exit 1
}

$VersioEdge = if ($env:NAVEGADOR) { ([regex]::Match((& $Edge --version 2>$null | Out-String), "\d+(\.\d+)+")).Value } else { (Get-Item $Edge).VersionInfo.ProductVersion }
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$VersioEdge Safari/537.36 Edg/$VersioEdge"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$vistos = @()
if (Test-Path $FitxerVistos) {
  try {
    $brut = ConvertFrom-Json -InputObject (Get-Content -Path $FitxerVistos -Raw -Encoding UTF8)
    $vistos = @(AplanarVistos $brut | Select-Object -Unique)
  } catch { $vistos = @() }
}

$inici = (Get-Date).AddDays(-$DiesEnrere).ToString("yyyyMMdd")
$fi    = (Get-Date).ToString("yyyyMMdd")
$revisats = 0
$avisats  = 0

Registrar ("=== Revisio de loteries (" + $inici + " - " + $fi + ")" + $(if ($Prova) { " [PROVA]" } else { "" }) + " ===")

foreach ($id in $Jocs.Keys) {
  $nomJoc = $Jocs[$id]
  $url = "$Base/servicios/buscadorSorteos?game_id=$id&celebrados=true&fechaInicioInclusiva=$inici&fechaFinInclusiva=$fi"

  try {
    $sorteigs = @(ObtenirJson $url)
  } catch {
    Registrar ("  " + $nomJoc + ": ERROR " + $_.Exception.Message)
    continue
  }

  $ambPremi = 0

  foreach ($s in $sorteigs) {
    if (-not $s.contenidosRelacionados) { continue }

    # Premis del sorteig i, a l'Euromillones, també d'El Millón (canvi 29.09.2026).
    $totes = @($s.contenidosRelacionados.noticias)
    if ($s.millon -and $s.millon.contenidosRelacionados) { $totes += @($s.millon.contenidosRelacionados.noticias) }
    $noticies = @($totes | Where-Object { $_ -and $_.urlContenido -like "/premios/*" })

    foreach ($n in $noticies) {
      $urlPremi = "$Base/es" + $n.urlContenido
      $ambPremi++

      if (-not $Prova -and ($vistos -contains $urlPremi)) { continue }

      try {
        $punts = @(PuntsDeVenda (Obtenir $urlPremi))
      } catch {
        Registrar ("  " + $nomJoc + ": no s'ha pogut obrir " + $urlPremi + " (" + $_.Exception.Message + ")")
        continue
      }

      $revisats++

      # Si la pàgina encara no té els punts de venda, es tornarà a mirar el proper dia.
      if ($punts.Count -eq 0) {
        Registrar ("  " + $nomJoc + " | " + $n.tituloContenido + " | encara sense punts de venda")
        continue
      }

      $zona = @($punts | Where-Object { EsDeLaZona $_ })

      if ($Prova) {
        Registrar ("  " + $nomJoc + " | " + $n.tituloContenido + " | " + ($punts -join " / ") +
          $(if ($zona.Count) { "  <<< ZONA" } else { "" }))
        continue
      }

      $enviat = $true

      if ($zona.Count -gt 0) {
        $data = ""
        try { $data = ([datetime]::Parse($s.fecha_sorteo)).ToString("dd.MM.yyyy") } catch {}

        $linies = @("🍀 PREMI DE LOTERIA VENUT A LA ZONA", ($nomJoc + " · " + $n.tituloContenido))
        foreach ($z in $zona) { $linies += ("📍 " + $z) }
        if ($s.combinacion) { $linies += ("Combinació: " + $s.combinacion) }
        $import = ImportPremi $s $n.tituloContenido
        if ($import) { $linies += ("Premi per encertant: " + $import) }
        if ($data) { $linies += ("Sorteig del " + $data) }
        $linies += ("🔗 " + $urlPremi)

        $enviat = EnviarTelegram ($linies -join "`n")
        if ($enviat) {
          $avisats++
          Registrar ("  AVIS ENVIAT: " + $nomJoc + " | " + $n.tituloContenido + " | " + ($zona -join " / "))
        }
      }

      if ($enviat) { $vistos += $urlPremi }
    }
  }

  Registrar ("  " + $nomJoc + ": " + $sorteigs.Count + " sorteigs, " + $ambPremi + " premis grossos")
}

# -----------------------------------------------------------------------------
# NOTÍCIES DE GOOGLE NOTÍCIES (Loteries de Catalunya i ONCE)
# -----------------------------------------------------------------------------

function RevisarNoticies([string]$nom, [string]$consulta, [string]$rxTitol, [string]$capcalera) {
  Registrar ("  --- " + $nom + " (Google Noticies) ---")

  $limitData = (Get-Date).AddDays(-$DiesNoticiesCat)
  $vistesAra = @{}
  $resultats = 0
  $rellevants = 0

  foreach ($edicio in $EdicionsNoticies) {
    $url = "https://news.google.com/rss/search?q=" +
      [Uri]::EscapeDataString($consulta + " when:" + $DiesNoticiesCat + "d") + "&" + $edicio

    try {
      $r = Invoke-WebRequest -Uri $url -UserAgent $UA -UseBasicParsing -TimeoutSec 30
      [xml]$rss = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    } catch {
      Registrar ("  Google Noticies (" + $edicio.Substring(3, 2) + "): ERROR " + $_.Exception.Message)
      continue
    }

    foreach ($it in @($rss.rss.channel.item | Where-Object { $_ })) {
      $resultats++
      $titol = [string]$it.title
      $clau  = "gn:" + [string]$it.link

      # La mateixa notícia pot sortir a les dues edicions.
      $clauTitol = Normalitzar $titol
      if ($vistesAra.ContainsKey($clauTitol)) { continue }
      $vistesAra[$clauTitol] = $true

      # Filtre 1: només notícies dels últims dies.
      try { $dataNoticia = ([datetimeoffset]::Parse([string]$it.pubDate)).LocalDateTime } catch { continue }
      if ($dataNoticia -lt $limitData) { continue }
      $data = $dataNoticia.ToString("dd.MM.yyyy")

      # Filtre 2: el titular ha de parlar del joc i d'un poble de la zona. Als
      # titulars sovint només hi posa "la Bisbal": també es compta (pot colar-se
      # alguna notícia de la Bisbal del Penedès o de Falset, però no se'n perd cap).
      if ($clauTitol -notmatch $rxTitol) { continue }
      if ($clauTitol -notmatch $RxTermes -and $clauTitol -notmatch "\bBISBAL\b") { continue }

      $rellevants++

      if ($Prova) {
        Registrar ("    " + $data + " | " + $titol)
        continue
      }

      if (($vistos -contains $clau) -or ($vistos -contains ("gt:" + $clauTitol))) { continue }

      $font = if ($it.source -and $it.source.'#text') { [string]$it.source.'#text' } else { [string]$it.source }
      $linies = @($capcalera, $titol)
      $peu = @($font, $data) | Where-Object { $_ }
      if ($peu.Count) { $linies += ($peu -join " · ") }
      $linies += ("🔗 " + [string]$it.link)

      if (EnviarTelegram ($linies -join "`n")) {
        $script:vistos += $clau
        $script:vistos += ("gt:" + $clauTitol)
        $script:avisats++
        Registrar ("  AVIS ENVIAT (" + $nom + "): " + $titol)
      }
    }
  }

  Registrar ("  " + $nom + ": " + $resultats + " resultats, " + $rellevants + " noticies de la zona")
}

# ONCE: notes oficials d'once.es (la població surt dins del text).
function RevisarOnceOficial() {
  Registrar "  --- ONCE (notes oficials d'once.es) ---"

  $html = ""
  try {
    $r = Invoke-WebRequest -Uri $OnceNoticies -UserAgent $UA -UseBasicParsing -TimeoutSec 30
    $html = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
  } catch {
    # Si la connexió directa falla, es prova amb Edge.
    try { $html = Obtenir $OnceNoticies } catch { Registrar ("  once.es: ERROR " + $_.Exception.Message); return }
  }

  # Enllaços a notes de premis ("reparte", cupó, Cuponazo, Sueldazo...).
  $notes = @()
  foreach ($m in [regex]::Matches($html, "href=[""']((?:https://www\.once\.es)?/noticias/[a-z0-9\-]+)[""']", "IgnoreCase")) {
    $u = $m.Groups[1].Value
    if ($u -notmatch "^https") { $u = "https://www.once.es" + $u }
    if ($u -notmatch "repart|premi|cupon|cuponazo|sueldazo|eurojackpot|triplex|super-11|mi-dia|rasca|suerte|millon") { continue }
    if ($notes -notcontains $u) { $notes += $u }
  }
  $notes = @($notes | Select-Object -First $OnceMaxNotes)

  $revisades = 0
  $deLaZona = 0

  foreach ($u in $notes) {
    $clau = "once:" + $u
    if (-not $Prova -and ($vistos -contains $clau)) { continue }

    try {
      $r2 = Invoke-WebRequest -Uri $u -UserAgent $UA -UseBasicParsing -TimeoutSec 30
      $nota = [Text.Encoding]::UTF8.GetString($r2.RawContentStream.ToArray())
    } catch {
      try { $nota = Obtenir $u } catch { Registrar ("    no s'ha pogut obrir " + $u); continue }
    }

    $revisades++
    $titol = ""
    $mt = [regex]::Match($nota, "<h1[^>]*>([\s\S]*?)</h1>", "IgnoreCase")
    if ($mt.Success) { $titol = TextNet $mt.Groups[1].Value }
    if (-not $titol) { $titol = $u }

    $text = TextNet $nota
    $norm = Normalitzar $text
    $zona = ($norm -match $RxTermes) -or (($norm -match "\bBISBAL\b") -and ($norm -match "GIRONA|EMPORDA|AMPURDAN"))

    if ($zona) {
      $deLaZona++
      # Frase sencera on surt el poble (els punts de "350.000" no la tallen:
      # una frase acaba en punt seguit d'espai i majúscula).
      $frase = ""
      $mf = [regex]::Match($text, $RxPoblesText, "IgnoreCase")
      if ($mf.Success) {
        $inici = 0
        foreach ($mi in [regex]::Matches($text.Substring(0, $mf.Index), "\.\s+(?=[A-ZÀ-Ý¿¡«""])")) { $inici = $mi.Index + $mi.Length }
        $mfi = [regex]::Match($text.Substring($mf.Index), "\.\s+(?=[A-ZÀ-Ý¿¡«""])")
        $fi = if ($mfi.Success) { $mf.Index + $mfi.Index + 1 } else { [Math]::Min($text.Length, $mf.Index + 300) }
        $frase = $text.Substring($inici, $fi - $inici).Trim()
        if ($frase.Length -gt 400) { $frase = $frase.Substring(0, 400) + "…" }
      }

      if ($Prova) {
        Registrar ("    <<< ZONA: " + $titol + " | " + $frase)
        continue
      }

      $linies = @("🍀 ONCE: PREMI A LA ZONA", $titol)
      if ($frase) { $linies += ("«" + $frase + "»") }
      $linies += ("🔗 " + $u)

      if (EnviarTelegram ($linies -join "`n")) {
        $script:vistos += $clau
        $script:avisats++
        Registrar ("  AVIS ENVIAT (ONCE): " + $titol)
      }
    } elseif (-not $Prova) {
      $script:vistos += $clau
    }
  }

  Registrar ("  once.es: " + $notes.Count + " notes de premis a la llista, " + $revisades + " revisades, " + $deLaZona + " de la zona")
}

RevisarNoticies "Loteries de Catalunya" $ConsultaNoticiesCat $RxTitolCat "🍀 LOTERIES DE CATALUNYA: NOTÍCIA DE LA ZONA"
RevisarOnceOficial
RevisarNoticies "ONCE" $ConsultaNoticiesOnce $RxTitolOnce "🍀 ONCE: PREMI A LA ZONA"

if (-not $Prova) {
  $vistos = @($vistos | Select-Object -Last 3000)
  ConvertTo-Json -InputObject $vistos | Set-Content -Path $FitxerVistos -Encoding UTF8

  # El registre es limita a les 2.000 darreres línies.
  $log = @(Get-Content -Path $FitxerLog -Encoding UTF8 -ErrorAction SilentlyContinue)
  if ($log.Count -gt 2000) { $log | Select-Object -Last 2000 | Set-Content -Path $FitxerLog -Encoding UTF8 }

  # Canvi 19.10.2026: hora de la revisió al panell, també sense avisos.
  if (Get-Command Marcar-RevisatAlPanell -ErrorAction SilentlyContinue) {
    Marcar-RevisatAlPanell -Fitxer "loteries.json" -Titol "Loteries" -SenseAvisos "Revisat: cap premi ni notícia de la zona."
  }
}

Registrar ("=== Fi: " + $revisats + " premis revisats, " + $avisats + " avisos enviats ===")
