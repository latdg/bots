<#
=============================================================================
 AVISADOR DEL PARLAMENT DE CATALUNYA — La TdG
 ParlamentLaTdG.ps1 · creat el 29.09.2026
 Canvi 03.10.2026: cerca tots els nuclis dels quatre municipis i les Gavarres,
 amb filtres per descartar falsos positius (cruïlles de carreteres, la Fonteta
 de València, Sant Pol de Mar...) i un fragment del text a cada avís. La
 primera nit, els termes nous registren
 sense avisar el que ja hi ha. Hora: 23.20 h (Loteries: 23.15 h); per aplicar
 la nova hora, torna a executar -Instal.

 S'executa al portàtil de casa (Windows) amb el Programador de tasques.
 El cercador de documents del Parlament (Oracle APEX) carrega els resultats
 amb peticions lligades a una sessió del navegador: des d'Apps Script no es pot
 fer. Aquí la cerca la fa Microsoft Edge sense finestra, que obre el cercador,
 espera que es carreguin els resultats i en llegeix la taula.

 Per a cada poble de la zona cerca "dins del document" a la legislatura actual
 i avisa al bot privat latdg_infos de cada document NOU (resolucions, mocions,
 preguntes, publicacions al BOPC...).

 Fa servir el testimoni i el chat_id desats per LoteriesLaTdG.ps1 (fitxer
 %LOCALAPPDATA%\LaTdG\loteries-config.json). Si encara no hi són, executa:
   powershell -ExecutionPolicy Bypass -File .\LoteriesLaTdG.ps1 -Configurar -Token "..." -ChatId "..."

 La PRIMERA execució normal no avisa de res: registra els documents que ja hi
 ha. A partir d'aleshores, només els nous.

 ÚS (des de PowerShell, a la carpeta on hi ha aquest fitxer):
   1. Prova, no envia ni desa res:
        powershell -ExecutionPolicy Bypass -File .\ParlamentLaTdG.ps1 -Prova
   2. Crea la tasca programada (cada dia a $HoraTasca):
        powershell -ExecutionPolicy Bypass -File .\ParlamentLaTdG.ps1 -Instal
   3. Per treure-la:
        powershell -ExecutionPolicy Bypass -File .\ParlamentLaTdG.ps1 -Desinstal
=============================================================================
#>

param(
  [switch]$Prova,
  [switch]$Instal,
  [switch]$Desinstal
)


# -----------------------------------------------------------------------------
# CONFIGURACIÓ
# -----------------------------------------------------------------------------

$Legislatura = "15"
$HoraTasca   = "23:20"   # canvi 03.10.2026: a prop de les Loteries (23.15 h)

# Temps (ms) que Edge espera que es carreguin els resultats de cada cerca.
$EsperaResultatsMs = 20000

# Termes de cerca (canvi 03.10.2026). Clau = el que es busca; valor = com surt a l'avís.
#  · Apòstrofs: el cercador no troba res amb "d'Empordà"; s'escriu "d Empordà"
#    (la "d" separada), que troba la Bisbal i cap Bisbal del Penedès (comprovat).
#    El mateix amb "Castell d Empordà" i "Sant Sadurní de l Heura".
#  · "Cassà de Pelràs" sempre sencer: "Cassà" sol trobaria Cassà de la Selva.
#  · Els falsos positius (cruïlles de carreteres, la Fonteta de València, Sant
#    Pol de Mar...) es descarten amb $Filtres, més avall.
$Termes = [ordered]@{
  # La Bisbal d'Empordà
  "Bisbal d Empordà"       = "la Bisbal d'Empordà"
  "Castell d Empordà"      = "Castell d'Empordà (la Bisbal d'Empordà)"
  "Sant Pol"               = "Sant Pol (la Bisbal d'Empordà)"
  # Corçà
  "Corçà"                  = "Corçà"
  "Casavells"              = "Casavells (Corçà)"
  "Matajudaica"            = "Matajudaica (Corçà)"
  "Cassà de Pelràs"        = "Cassà de Pelràs (Corçà)"
  "Planils"                = "Planils (Corçà)"
  "Anyells"                = "Anyells (Corçà)"
  # Forallac
  "Forallac"               = "Forallac"
  "Fitor"                  = "Fitor (Forallac)"
  "Fonteta"                = "Fonteta (Forallac)"
  "Peratallada"            = "Peratallada (Forallac)"
  "Vulpellac"              = "Vulpellac (Forallac)"
  "Canapost"               = "Canapost (Forallac)"
  "Santa Susanna de Peralta" = "Santa Susanna de Peralta (Forallac)"
  "Sant Climent de Peralta"  = "Sant Climent de Peralta (Forallac)"
  # Cruïlles, Monells i Sant Sadurní de l'Heura
  "Cruïlles, Monells i Sant Sadurní de l Heura" = "Cruïlles, Monells i Sant Sadurní de l'Heura"
  "Cruïlles"               = "Cruïlles (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Monells"                = "Monells (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Sant Sadurní de l Heura" = "Sant Sadurní de l'Heura (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Sies"                   = "Sies (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Rabioses"               = "Rabioses (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Sant Joan de Salelles"  = "Sant Joan de Salelles (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Sant Miquel de Cruïlles" = "Sant Miquel de Cruïlles (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Sant Cebrià dels Alls"  = "Sant Cebrià dels Alls (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Sant Cebrià de Lledó"   = "Sant Cebrià de Lledó (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Els Metges"             = "els Metges (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  "Santa Pellaia"          = "Santa Pellaia (Cruïlles, Monells i Sant Sadurní de l'Heura)"
  # Ullastret (31.10.2026). La primera cerca d'un terme nou només registra el que
  # ja hi ha, sense avisar; a partir d'aleshores avisa de les novetats.
  "Ullastret"              = "Ullastret"
  # Espai natural
  "Gavarres"               = "les Gavarres"
}

# Filtres dels termes que poden donar falsos positius (canvi 03.10.2026). Es
# miren sobre el text de la fila de resultats (títol, tipus, data...).
#  · Descarta: si el text hi coincideix, el document NO es té en compte.
#  · NomesAmb: el document només es té en compte si el text hi coincideix.
#  · Context:  si el text NO hi coincideix, s'avisa igualment però amb una nota
#              "comprova-ho", perquè la paraula pot ser dins del document sense
#              que el títol digui de quin lloc parla.
$Filtres = @{
  # Canvi 03.10.2026: el nom complet del municipi porta el mateix filtre que
  # "Cruïlles", perquè el cercador en busca les paraules per separat.
  "Cruïlles, Monells i Sant Sadurní de l Heura" = @{
    Descarta = "carreter|rotond|intersecci|vial|trànsit|transit|semàfor|semafor|autovia|autopista|\b(N|C|GI|GIV|A|AP|B|T|L|LV)-\d"
    Context  = "Monells|Sadurn|Bisbal|Empord|Gavarres|Cruïlles, Monells"
    NomesAmb = "Monells|Sadurn|Empord|Bisbal|Gavarres|Sant Miquel de Cru"
  }
  "Cruïlles" = @{
    Descarta = "carreter|rotond|intersecci|vial|trànsit|transit|semàfor|semafor|autovia|autopista|\b(N|C|GI|GIV|A|AP|B|T|L|LV)-\d"
    Context  = "Monells|Sadurn|Bisbal|Empord|Gavarres|Cruïlles, Monells"
    # Canvi 03.10.2026: "les cruïlles" (de carrers) i el festival Cruïlla
    # passaven el filtre; ara només compta si el text parla també de la zona.
    NomesAmb = "Monells|Sadurn|Empord|Bisbal|Gavarres|Sant Miquel de Cru"
  }
  "Fonteta" = @{
    # Canvi 03.10.2026: "la Fonteta" (amb article) és un carrer o un passeig
    # d'una altra població; el poble de Forallac és "Fonteta", sense article.
    Descarta = "Val[eè]ncia|Alacant|Alicante|Sueca|Albufera|Castelló de la Plana|Castellón|País Valencià|\bla Fonteta"
    Context  = "Forallac|Empord|Peratallada|Bisbal"
  }
  "Sant Pol" = @{
    # Canvi 03.10.2026: també Sant Pol de Sant Feliu de Guíxols i els pobles del Maresme.
    Descarta = "Sant Pol de Mar|Maresme|Sant Feliu de Gu[ií]xols|Canet de Mar|Cabrils|Arenys|Calella"
    Context  = "Bisbal|Empord"
  }
  # "Els Metges" surt a molts documents de sanitat: només compta si el text
  # també parla de Cruïlles, Monells o Sant Sadurní.
  "Els Metges" = @{
    NomesAmb = "Cru[ïi]lles|Monells|Sadurn"
  }
  # "Sies" (canvi 03.10.2026): la prova en va trobar molts que no eren de la
  # zona; igual que "Els Metges", només compta amb Cruïlles, Monells o Sant Sadurní.
  # "Monells" (canvi 03.10.2026): fora l'empresa Embutidos Monells (Osona).
  "Monells" = @{
    Descarta = "Embutidos Monells|Balenyà"
  }
  "Sies" = @{
    NomesAmb = "Cru[ïi]lles|Monells|Sadurn"
  }
}

$Cercador = "https://www.parlament.cat/ext/r/pcat_portal/siap-cerca/cerca-de-documents"
$NomTasca = "LaTdG Parlament"

# CANVI 21.10.2026 (GitHub): a GitHub la carpeta i la configuració les indica
# el bucle dels bots (LATDG_CARPETA, LATDG_CONFIG); al portàtil, com sempre.
$Carpeta      = if ($env:LATDG_CARPETA) { $env:LATDG_CARPETA } else { Join-Path $env:LOCALAPPDATA "LaTdG" }
$FitxerConfig = if ($env:LATDG_CONFIG) { $env:LATDG_CONFIG } else { Join-Path $Carpeta "loteries-config.json" }
$FitxerVistos = Join-Path $Carpeta "parlament-vistos.json"
# Termes que ja han fet la seva primera cerca (canvi 03.10.2026): els nous
# registren sense avisar el que ja hi ha, perquè no t'arribi tot de cop.
$FitxerTermes = Join-Path $Carpeta "parlament-termes.json"
# Perfil propi d'Edge (canvi 03.10.2026), perquè no topi amb el d'Edge de les
# Loteries si alguna nit les dues tasques coincideixen.
$PerfilEdge   = if ($env:LATDG_CARPETA) { Join-Path ([IO.Path]::GetTempPath()) "edge-parlament" } else { Join-Path $Carpeta "edge-parlament" }
$FitxerLog    = Join-Path $Carpeta "parlament.log"

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
    -Description "Avisador del Parlament de Catalunya de La TdG" -Force | Out-Null

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

function Registrar([string]$text) {
  $linia = (Get-Date).ToString("dd.MM.yyyy HH:mm:ss") + "  " + $text
  Write-Host $linia
  if (-not $Prova) { Add-Content -Path $FitxerLog -Value $linia -Encoding UTF8 }
}

function TextNet([string]$html) {
  $t = $html -replace "<script[\s\S]*?</script>", " " -replace "<style[\s\S]*?</style>", " " -replace "<[^>]+>", " "
  return ([Net.WebUtility]::HtmlDecode($t) -replace "\s+", " ").Trim()
}

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

if (-not $Edge) { Registrar "ERROR: no s'ha trobat Microsoft Edge."; exit 1 }

$VersioEdge = if ($env:NAVEGADOR) { ([regex]::Match((& $Edge --version 2>$null | Out-String), "\d+(\.\d+)+")).Value } else { (Get-Item $Edge).VersionInfo.ProductVersion }
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$VersioEdge Safari/537.36 Edg/$VersioEdge"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# Obre una pàgina amb Edge, espera que s'executin les peticions de la pàgina i
# en retorna l'HTML final (amb els resultats ja carregats).
function ObtenirRenderitzat([string]$url) {
  $tot = (& $Edge --headless=new --disable-gpu --disable-blink-features=AutomationControlled `
    --user-data-dir="$PerfilEdge" --no-first-run `
    --user-agent="$UA" --virtual-time-budget=$EsperaResultatsMs --dump-dom $url 2>&1 | ForEach-Object { "$_" }) -join "`n"

  $i = $tot.IndexOf("<html", [StringComparison]::OrdinalIgnoreCase)
  $f = $tot.LastIndexOf("</html>", [StringComparison]::OrdinalIgnoreCase)

  if ($i -lt 0) { throw "Edge no ha retornat la pàgina" }
  if ($f -gt $i) { return $tot.Substring($i, $f - $i + 7) }
  return $tot.Substring($i)
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
    Afegir-AlPanell -Fitxer "parlament.json" -Titol "Parlament de Catalunya" -Textos @($text)
  }

  return $true
}

# Fragment del text al voltant del terme cercat (canvi 03.10.2026), perquè
# l'avís expliqui de què parla el document quan el títol és només "BOPC 590".
# Els espais del terme accepten també apòstrofs: "Bisbal d Empordà" troba
# "Bisbal d'Empordà".
function Fragment([string]$text, [string]$terme) {
  if (-not $text) { return "" }
  $patro = [regex]::Escape($terme) -replace '\\ ', "[\s'’]+"
  $m = [regex]::Match($text, $patro, "IgnoreCase")
  if (-not $m.Success) { return "" }
  $ini = [Math]::Max(0, $m.Index - 140)
  $fi  = [Math]::Min($text.Length, $m.Index + $m.Length + 140)
  $f = $text.Substring($ini, $fi - $ini).Trim()
  if ($ini -gt 0) { $f = "…" + ($f -replace '^\S*\s+', '') }
  if ($fi -lt $text.Length) { $f = ($f -replace '\s+\S*$', '') + "…" }
  return $f
}

# Documents de la taula de resultats: una fila per document, amb l'enllaç a
# l'expedient (p15_num_expedient) i/o al document (id_document).
function DocumentsDeLaPagina([string]$html) {
  $docs = @()

  foreach ($fila in [regex]::Matches($html, "<tr\b[\s\S]*?</tr>", "IgnoreCase")) {
    $h = $fila.Value
    $exp = [regex]::Match($h, "p15_num_expedient[:=]([0-9]{3}-[0-9]{5}/[0-9]+)", "IgnoreCase")
    $doc = [regex]::Match($h, "id_document=(\d+)", "IgnoreCase")
    if (-not $exp.Success -and -not $doc.Success) { continue }

    $cel = @([regex]::Matches($h, "<td\b[\s\S]*?</td>", "IgnoreCase") | ForEach-Object { TextNet $_.Value })
    $text = TextNet $h

    $titol = if ($cel.Count) { $cel[0] } else { $text }
    if ($titol.Length -gt 400) { $titol = $titol.Substring(0, 400) + "…" }

    $data = ([regex]::Match($text, "\b\d{2}/\d{2}/\d{4}\b")).Value
    $expedient = if ($exp.Success) { $exp.Groups[1].Value } else { "" }
    $tipus = if ($cel.Count -ge 5) { $cel[4] } else { "" }

    $url = if ($expedient) { "https://www.parlament.cat/ext/f?p=siap-cerca:expedient:::::p15_num_expedient:" + $expedient }
           else { "https://www.parlament.cat/api/siapcerca/v1/document?id_document=" + $doc.Groups[1].Value }

    $clau = if ($doc.Success) { "doc:" + $doc.Groups[1].Value } else { "exp:" + $expedient + "|" + $titol.Substring(0, [Math]::Min(80, $titol.Length)) }

    if (@($docs | Where-Object { $_.clau -eq $clau }).Count) { continue }

    # Text dels fragments (canvi 03.10.2026): el que ve després de la data i
    # del tipus de document, sense el títol ni la legislatura del principi.
    $cos = $text
    if ($data) {
      $pos = $cos.IndexOf($data)
      if ($pos -ge 0) { $cos = $cos.Substring($pos + $data.Length).Trim() }
    }
    if ($tipus -and $cos.StartsWith($tipus)) { $cos = $cos.Substring($tipus.Length).Trim() }
    $cos = $cos -replace '\s*\[\.\.\.\]\s*', ' … '

    $docs += [pscustomobject]@{ clau = $clau; titol = $titol; expedient = $expedient; data = $data; tipus = $tipus; url = $url; text = $text; cos = $cos }
  }

  return $docs
}


# -----------------------------------------------------------------------------
# REVISIÓ
# -----------------------------------------------------------------------------

$TelegramToken = ""
$TelegramChatId = ""
if (Test-Path $FitxerConfig) {
  try {
    $cfg = ConvertFrom-Json -InputObject (Get-Content -Path $FitxerConfig -Raw -Encoding UTF8)
    $TelegramToken = $cfg.token
    $TelegramChatId = $cfg.chat_id
  } catch {}
}

if (-not $Prova -and (-not $TelegramToken -or -not $TelegramChatId)) {
  Write-Host "Falta el testimoni del bot: executa LoteriesLaTdG.ps1 amb -Configurar (o fes aquesta prova amb -Prova)."
  exit 1
}

# Canvi 03.10.2026: el Windows PowerShell 5.1 (el que fa servir la tasca
# programada) retorna la llista desada com UN SOL element (la llista sencera a
# dins d'una altra). Aleshores "-contains" no trobava mai cap clau, cada
# execució ho tornava a avisar tot i el fitxer s'anava niant. Ara la llista es
# llegeix aplanada (també recupera les claus dels fitxers ja niats) i es desa
# com una llista simple de textos. Si el fitxer no es pot llegir, es fa com la
# primera vegada: es registra tot sense avisar.
function AplanarVistos($x) {
  foreach ($e in @($x)) {
    if ($null -eq $e) { continue }
    if ($e -is [string]) { $e }
    elseif ($e -is [System.Collections.IEnumerable]) { AplanarVistos $e }
    elseif ($e.PSObject.Properties["value"]) { AplanarVistos $e.value }
  }
}

$primeraVegada = -not (Test-Path $FitxerVistos)
$vistos = @()
if (-not $primeraVegada) {
  try {
    $vistos = @(AplanarVistos (ConvertFrom-Json -InputObject (Get-Content -Path $FitxerVistos -Raw -Encoding UTF8)) | Select-Object -Unique)
  } catch { $vistos = @() }
  if ($vistos.Count -eq 0) { $primeraVegada = $true }
}

Registrar ("=== Revisio del Parlament" + $(if ($Prova) { " [PROVA]" } elseif ($primeraVegada) { " [PRIMERA EXECUCIO: es registra sense avisar]" } else { "" }) + " ===")

# Termes que ja havien fet la primera cerca (canvi 03.10.2026).
$termesFets = @()
if (Test-Path $FitxerTermes) {
  try { $termesFets = @(AplanarVistos (ConvertFrom-Json -InputObject (Get-Content -Path $FitxerTermes -Raw -Encoding UTF8))) } catch { $termesFets = @() }
} else {
  # Primera vegada amb la llista nova: els termes que ja es cercaven abans
  # continuen avisant amb normalitat.
  $termesFets = @("Bisbal d Empordà", "Corçà", "Monells", "Forallac", "Peratallada", "Vulpellac")
}
$termesFetsAra = @()

$trobats = [ordered]@{}   # clau -> @{ doc; pobles; segur; nomesNous }
$cerquesOk = 0
$descartats = 0

foreach ($terme in $Termes.Keys) {
  $url = $Cercador + "?clear=100" +
    "&p100_text_a_cercar=" + [Uri]::EscapeDataString($terme) +
    "&p100_legislatura=" + $Legislatura +
    "&p100_ordenacio=DATA_DOC_DESC&p100_page_limit=50&p100_cerca_executada=S"

  try {
    $html = ObtenirRenderitzat $url
  } catch {
    Registrar ("  """ + $terme + """: ERROR " + $_.Exception.Message)
    continue
  }

  $docs = @(DocumentsDeLaPagina $html)
  $cerquesOk++
  Registrar ("  """ + $terme + """: " + $docs.Count + " documents")

  # En mode de prova, si no surt res, un tros de la pàgina per saber per què.
  if ($Prova -and $docs.Count -eq 0) {
    $t = TextNet $html
    $p = $t.IndexOf("Resultats", [StringComparison]::OrdinalIgnoreCase)
    Registrar ("    (pagina: " + $t.Substring([Math]::Max(0, $p), [Math]::Min(400, $t.Length - [Math]::Max(0, $p))) + ")")
  }

  $termeNou = -not $primeraVegada -and ($termesFets -notcontains $terme)
  $termesFetsAra += $terme
  $f = $Filtres[$terme]

  foreach ($d in $docs) {
    # Filtres de falsos positius (canvi 03.10.2026).
    $segur = $true
    if ($f) {
      if ($f.Descarta -and $d.text -match $f.Descarta) {
        $descartats++
        if ($Prova) { Registrar ("    [descartat per ""$terme""] " + $d.titol.Substring(0, [Math]::Min(120, $d.titol.Length))) }
        continue
      }
      if ($f.NomesAmb -and $d.text -notmatch $f.NomesAmb) {
        $descartats++
        if ($Prova) { Registrar ("    [descartat per ""$terme""] " + $d.titol.Substring(0, [Math]::Min(120, $d.titol.Length))) }
        continue
      }
      if ($f.Context -and $d.text -notmatch $f.Context) { $segur = $false }
    }

    if (-not $trobats.Contains($d.clau)) { $trobats[$d.clau] = @{ doc = $d; pobles = @(); segur = $false; nomesNous = $true; fragment = "" } }
    if (-not $trobats[$d.clau].fragment) {
      $fr = Fragment $d.cos $terme
      # Si el fragment ja és dins del títol, no aporta res.
      if ($fr -and $d.titol.IndexOf($fr.Trim("…"), [StringComparison]::OrdinalIgnoreCase) -lt 0) { $trobats[$d.clau].fragment = $fr }
    }
    if ($trobats[$d.clau].pobles -notcontains $Termes[$terme]) { $trobats[$d.clau].pobles += $Termes[$terme] }
    if ($segur) { $trobats[$d.clau].segur = $true }
    if (-not $termeNou) { $trobats[$d.clau].nomesNous = $false }
  }
}

if ($descartats) { Registrar ("  Descartats per filtres (falsos positius): " + $descartats) }

if ($cerquesOk -eq 0) {
  Registrar "=== Cap cerca ha funcionat: es tornara a provar el proper dia ==="
  exit 1
}

$avisats = 0
$nous = 0

foreach ($clau in $trobats.Keys) {
  $e = $trobats[$clau]
  $d = $e.doc

  if ($Prova) {
    Registrar ("    " + $d.data + " | " + $d.tipus + " | " + $d.expedient + " | " + $d.titol.Substring(0, [Math]::Min(150, $d.titol.Length)) + " | " + ($e.pobles -join ", "))
    if ($e.fragment) { Registrar ("        fragment: " + $e.fragment) }
    continue
  }

  if ($vistos -contains $clau) { continue }
  $nous++

  if ($primeraVegada) { $vistos += $clau; continue }

  # Canvi 03.10.2026: si només l'han trobat termes que cerquen per primera
  # vegada, es registra sense avisar (és un document que ja existia).
  if ($e.nomesNous) { $vistos += $clau; continue }

  $linies = @("🏛️ PARLAMENT DE CATALUNYA — esmenta " + ($e.pobles -join ", "), $d.titol)
  if ($e.fragment) { $linies += ("📄 «" + $e.fragment + "»") }
  if (-not $e.segur) { $linies += "⚠️ Comprova-ho: el títol no diu de quin lloc parla; pot ser una coincidència de nom." }
  if ($d.tipus) { $linies += ("Tipus: " + $d.tipus) }
  if ($d.data) { $linies += ("Data: " + ($d.data -replace "/", ".")) }
  if ($d.expedient) { $linies += ("Expedient: " + $d.expedient) }
  $linies += ("🔗 " + $d.url)

  if (EnviarTelegram ($linies -join "`n")) {
    $vistos += $clau
    $avisats++
  }
}

if (-not $Prova) {
  ConvertTo-Json -InputObject ([string[]]@($vistos | Select-Object -Unique | Select-Object -Last 2000)) | Set-Content -Path $FitxerVistos -Encoding UTF8
  ConvertTo-Json -InputObject ([string[]]@(@($termesFets) + @($termesFetsAra) | Select-Object -Unique)) | Set-Content -Path $FitxerTermes -Encoding UTF8
  $log = @(Get-Content -Path $FitxerLog -Encoding UTF8 -ErrorAction SilentlyContinue)
  if ($log.Count -gt 2000) { $log | Select-Object -Last 2000 | Set-Content -Path $FitxerLog -Encoding UTF8 }

  # Canvi 19.10.2026: hora de la revisió al panell, també sense avisos.
  if (Get-Command Marcar-RevisatAlPanell -ErrorAction SilentlyContinue) {
    Marcar-RevisatAlPanell -Fitxer "parlament.json" -Titol "Parlament de Catalunya" -SenseAvisos "Revisat: cap document nou."
  }
}

Registrar ("=== Fi: " + $trobats.Count + " documents trobats, " + $nous + " nous, " + $avisats + " avisos enviats ===")
