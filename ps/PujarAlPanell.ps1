# =============================================================================
# PUJAR AL PANELL DE LA REDACCIÓ — La TdG · 17.10.2026
# PujarAlPanell.ps1 (desa'l a D:\LaTdG, al costat de LoteriesLaTdG.ps1 i
# ParlamentLaTdG.ps1, que el carreguen sols)
#
# Afegeix cada avís al fitxer del dia del repo latdg/redaccio:
#   dades/AAAA-MM-DD/parlament.json   o   dades/AAAA-MM-DD/loteries.json
# i apunta el dia a dades/dies.json (la llista del selector "Dia" del panell).
# Els avisos nous van a dalt. Si falla, només avisa a la consola: mai atura
# l'script que el crida.
#
# El token es llegeix de D:\LaTdG\github_token_panell.txt (només el token, una línia).
# =============================================================================

$PanellRepo = "latdg/redaccio"
$PanellBranca = "main"
# CANVI 21.10.2026 (GitHub): a GitHub el fitxer del token l'indica el bucle dels bots.
$PanellFitxerToken = if ($env:LATDG_TOKEN_PANELL) { $env:LATDG_TOKEN_PANELL } else { "D:\LaTdG\github_token_panell.txt" }

# Crea o substitueix un fitxer del repo. $Transforma rep el text actual (o
# $null si no existeix) i retorna el text nou (o $null si no cal canviar res).
# Si un altre procés l'ha escrit entremig, es torna a llegir i a provar.
function Pujar-FitxerPanell {
    param(
        [Parameter(Mandatory = $true)][string]$Cami,
        [Parameter(Mandatory = $true)][scriptblock]$Transforma,
        [Parameter(Mandatory = $true)][string]$Missatge
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $token = (Get-Content -Path $PanellFitxerToken -Raw).Trim()
    $capcaleres = @{
        Authorization          = "Bearer $token"
        Accept                 = "application/vnd.github+json"
        "User-Agent"           = "LaTdG-panell"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $url = "https://api.github.com/repos/$PanellRepo/contents/$Cami"

    for ($intent = 1; $intent -le 3; $intent++) {
        $sha = $null
        $actual = $null

        try {
            $resposta = Invoke-RestMethod -Uri ($url + "?ref=" + $PanellBranca) -Headers $capcaleres -Method Get
            $sha = $resposta.sha
            $actual = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($resposta.content -replace "\s", "")))
        }
        catch {
            # 404: el fitxer encara no existeix i es crearà.
        }

        $nou = & $Transforma $actual
        if ($null -eq $nou) { return }

        $cos = @{
            message = $Missatge
            branch  = $PanellBranca
            content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nou))
        }
        if ($sha) { $cos.sha = $sha }

        try {
            Invoke-RestMethod -Uri $url -Headers $capcaleres -Method Put `
                -Body ([Text.Encoding]::UTF8.GetBytes(($cos | ConvertTo-Json))) `
                -ContentType "application/json; charset=utf-8" | Out-Null
            return
        }
        catch {
            if ($intent -eq 3) { throw }
            Start-Sleep -Seconds (2 * $intent)
        }
    }
}

function Afegir-AlPanell {
    param(
        [Parameter(Mandatory = $true)][string]$Fitxer,
        [Parameter(Mandatory = $true)][string]$Titol,
        [Parameter(Mandatory = $true)][string[]]$Textos
    )

    try {
        $dia = Get-Date -Format "yyyy-MM-dd"
        $ara = Get-Date -Format "dd.MM.yyyy HH.mm"
        $id = [IO.Path]::GetFileNameWithoutExtension($Fitxer)

        $nous = @($Textos | Where-Object { $_ -and $_.Trim() } | ForEach-Object {
            [pscustomobject]@{ data = $ara; text = $_.Trim() }
        })
        if ($nous.Count -eq 0) { return }

        # 1. El fitxer del dia, amb els avisos nous a dalt.
        # CANVI 18.10.2026: els avisos que ja hi són aquell dia (mateix text) no
        # es tornen a afegir, per si l'script es torna a executar.
        Pujar-FitxerPanell -Cami "dades/$dia/$Fitxer" -Missatge "$id $ara" -Transforma {
            param($actual)

            $anteriors = @()
            if ($actual) {
                try {
                    $dades = $actual | ConvertFrom-Json
                    if ($dades.seccions -and $dades.seccions[0].items) { $anteriors = @($dades.seccions[0].items) }
                } catch {}
            }

            $textosAnteriors = @($anteriors | ForEach-Object { [string]$_.text })
            $afegir = @($nous | Where-Object { $textosAnteriors -notcontains $_.text })
            if ($afegir.Count -eq 0) { return $null }

            $objecte = [pscustomobject]@{
                generat  = $ara
                dia      = $dia
                seccions = @([pscustomobject]@{ id = $id; titol = $Titol; items = @(@($afegir) + @($anteriors)) })
            }

            return ($objecte | ConvertTo-Json -Depth 6)
        }.GetNewClosure()

        # 2. El dia a la llista del selector (si encara no hi és).
        Pujar-FitxerPanell -Cami "dades/dies.json" -Missatge "Dia $dia" -Transforma {
            param($actual)

            $dies = @()
            if ($actual) {
                # Amb "foreach" (i no amb la canonada) perquè el PowerShell 5.1
                # no prengui la llista sencera com un sol element.
                try { foreach ($d in (ConvertFrom-Json -InputObject $actual)) { $dies += [string]$d } } catch {}
            }

            if ($dies -contains $dia) { return $null }

            $dies = @(@($dies) + @($dia) | Sort-Object -Descending)
            return (ConvertTo-Json -InputObject $dies -Compress)
        }.GetNewClosure()

        Write-Host "Panell: dades/$dia/$Fitxer revisat ($($nous.Count) avis(os) rebut(s); els repetits no s'hi afegeixen)."
    }
    catch {
        Write-Warning "Panell: no s'ha pogut actualitzar $Fitxer -> $($_.Exception.Message)"
    }
}

# CANVI 19.10.2026: desa l'hora de la darrera revisió al fitxer del dia, també
# quan no hi ha cap avís (el panell mostra «Actualitzat el…»). Els avisos que
# ja hi són es conserven; si no n'hi ha cap, hi posa la nota $SenseAvisos.
function Marcar-RevisatAlPanell {
    param(
        [Parameter(Mandatory = $true)][string]$Fitxer,
        [Parameter(Mandatory = $true)][string]$Titol,
        [string]$SenseAvisos = "Revisat: cap avís nou."
    )

    try {
        $dia = Get-Date -Format "yyyy-MM-dd"
        $ara = Get-Date -Format "dd.MM.yyyy HH.mm"
        $id = [IO.Path]::GetFileNameWithoutExtension($Fitxer)

        # 1. El fitxer del dia, amb l'hora de la revisió.
        Pujar-FitxerPanell -Cami "dades/$dia/$Fitxer" -Missatge "$id revisat $ara" -Transforma {
            param($actual)

            $anteriors = @()
            if ($actual) {
                try {
                    $dades = $actual | ConvertFrom-Json
                    if ($dades.seccions -and $dades.seccions[0].items) { $anteriors = @($dades.seccions[0].items) }
                } catch {}
            }

            $objecte = [pscustomobject]@{
                generat  = $ara
                dia      = $dia
                seccions = @([pscustomobject]@{
                    id    = $id
                    titol = $Titol
                    nota  = $(if ($anteriors.Count) { "" } else { $SenseAvisos })
                    items = @($anteriors)
                })
            }

            return ($objecte | ConvertTo-Json -Depth 6)
        }.GetNewClosure()

        # 2. El dia a la llista del selector (si encara no hi és).
        Pujar-FitxerPanell -Cami "dades/dies.json" -Missatge "Dia $dia" -Transforma {
            param($actual)

            $dies = @()
            if ($actual) {
                try { foreach ($d in (ConvertFrom-Json -InputObject $actual)) { $dies += [string]$d } } catch {}
            }

            if ($dies -contains $dia) { return $null }

            $dies = @(@($dies) + @($dia) | Sort-Object -Descending)
            return (ConvertTo-Json -InputObject $dies -Compress)
        }.GetNewClosure()

        Write-Host "Panell: dades/$dia/$Fitxer marcat com a revisat a les $ara."
    }
    catch {
        Write-Warning "Panell: no s'ha pogut marcar la revisio de $Fitxer -> $($_.Exception.Message)"
    }
}