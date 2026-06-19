<#
.SYNOPSIS
    API REST propia que expone datos del Coordinador Electrico Nacional (CEN)
    para el proyecto Quillagua: Inyeccion/Retiro de Energia Activa y
    Costo Marginal Online.

.DESCRIPTION
    Servidor construido con el framework Pode. Actua como "backend for
    frontend": consulta la API publica del CEN (que requiere sus propias
    API Keys) y la re-expone bajo un contrato propio, simple y estable,
    protegido con autenticacion por API Key propia (header X-API-KEY).

    Ver README.md -> seccion "Decisiones tecnicas" para la justificacion
    del mecanismo de seguridad elegido.

.NOTES
    Ejecutar con:  pwsh ./Start-CenApi.ps1
#>

# --- Resolver rutas del proyecto, independiente del directorio actual ---
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Importar dependencias del modulo Pode ---
if (-not (Get-Module -ListAvailable -Name Pode)) {
    Write-Host "El modulo 'Pode' no esta instalado. Instalando para el usuario actual..." -ForegroundColor Yellow
    Install-Module -Name Pode -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    if (-not (Get-Module -ListAvailable -Name Pode)) {
        Write-Error "No se pudo instalar Pode. Ejecuta manualmente: Install-Module -Name Pode -Scope CurrentUser -Force"
        exit 1
    }
}
Import-Module Pode -ErrorAction Stop

# --- Cargar funciones propias como modulo (no dot-source) para que esten
#     disponibles dentro de los scriptblocks de las rutas de Pode, que
#     corren en runspaces distintos al script principal. ---
$HelpersModulePath = "$ScriptRoot/CenApiHelpers/CenApiHelpers.psm1"
Import-Module $HelpersModulePath -Force -Global -ErrorAction Stop

# --- Cargar variables de entorno (.env) ---
$envFile = Join-Path $ScriptRoot '.env'
Import-DotEnv -Path $envFile -Verbose:$false

$port = if ($env:SERVER_PORT) { [int]$env:SERVER_PORT } else { 8080 }
$protocol = if ($env:SERVER_PROTOCOL) { $env:SERVER_PROTOCOL } else { 'Http' }

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " CEN API Proxy iniciando en: ${protocol}://localhost:${port}" -ForegroundColor Cyan
Write-Host " Healthcheck (sin auth):     GET /health" -ForegroundColor Cyan
Write-Host " Endpoints protegidos (X-API-KEY):" -ForegroundColor Cyan
Write-Host "   GET /api/v1/costo-marginal?startDate=YYYY-MM-DD&endDate=YYYY-MM-DD" -ForegroundColor Cyan
Write-Host "   GET /api/v1/medidas?startDate=YYYY-MM-DD&endDate=YYYY-MM-DD" -ForegroundColor Cyan
Write-Host "   GET /api/v1/resumen?startDate=YYYY-MM-DD&endDate=YYYY-MM-DD" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

Start-PodeServer -Threads 2 {

    # Pode State: mecanismo soportado oficialmente por Pode para compartir
    # datos entre el script principal y los runspaces de cada ruta (las
    # variables normales, incluso $global:, no se propagan automaticamente).
    Set-PodeState -Name 'HelpersModulePath' -Value $HelpersModulePath | Out-Null

    Add-PodeEndpoint -Address localhost -Port 8080 -Protocol Http

    # Logging basico a consola, util para depurar en local
    New-PodeLoggingMethod -Terminal | Enable-PodeRequestLogging
    New-PodeLoggingMethod -Terminal | Enable-PodeErrorLogging

    # =========================================================================
    # SEGURIDAD: Autenticacion por API Key propia
    # El cliente (dashboard) debe enviar el header "X-API-KEY" con el valor
    # configurado en la variable de entorno OWN_API_KEY.
    # Justificacion completa en README.md.
    # =========================================================================
    New-PodeAuthScheme -ApiKey -Location Header -LocationName 'X-API-KEY' |
        Add-PodeAuth -Name 'ApiKeyAuth' -Sessionless -ScriptBlock {
            param($key)

            $expectedKey = $env:OWN_API_KEY

            if ([string]::IsNullOrWhiteSpace($expectedKey)) {
                # Si el servidor no tiene configurada su propia key, es un
                # error de configuracion del servidor, no del cliente.
                return $null
            }

            if ($key -eq $expectedKey) {
                return @{ User = @{ Name = 'dashboard-client' } }
            }

            return $null
        }

    # Middleware CORS minimo: permite que el dashboard HTML (servido desde
    # otro origen, p.ej. file:// o un servidor estatico distinto) pueda
    # llamar a esta API desde el navegador.
    Add-PodeMiddleware -Name 'CORS' -ScriptBlock {
        Add-PodeHeader -Name 'Access-Control-Allow-Origin' -Value '*'
        Add-PodeHeader -Name 'Access-Control-Allow-Methods' -Value 'GET, OPTIONS'
        Add-PodeHeader -Name 'Access-Control-Allow-Headers' -Value 'Content-Type, X-API-KEY'
        return $true
    }
    Add-PodeRoute -Method Options -Path * -ScriptBlock {
        Set-PodeResponseStatus -Code 204
    }

    # =========================================================================
    # RUTA: GET /health
    # Healthcheck publico (sin autenticacion) para verificar que el servidor
    # esta arriba. No expone datos del CEN.
    # =========================================================================
    Add-PodeRoute -Method Get -Path '/health' -ScriptBlock {
        Write-PodeJsonResponse -Value @{
            status = 'ok'
            timestamp = (Get-Date).ToString('o')
        }
    }

    # =========================================================================
    # RUTA: GET /api/v1/costo-marginal
    # Query params: startDate, endDate (yyyy-MM-dd). Opcional: barra.
    # =========================================================================
    Add-PodeRoute -Method Get -Path '/api/v1/costo-marginal' -Authentication 'ApiKeyAuth' -ScriptBlock {
        try {
            Import-Module (Get-PodeState -Name 'HelpersModulePath') -Force -ErrorAction Stop
            $startDate = $WebEvent.Query['startDate']
            $endDate   = $WebEvent.Query['endDate']
            $barra     = $WebEvent.Query['barra']

            if ([string]::IsNullOrWhiteSpace($startDate) -or [string]::IsNullOrWhiteSpace($endDate)) {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{
                    error = "Debes especificar 'startDate' y 'endDate' (formato yyyy-MM-dd)."
                }
                return
            }

            $cacheKey = "cmg:" + $startDate + ":" + $endDate + ":" + $barra

            $data = Get-CachedOrInvoke -Key $cacheKey -ScriptBlock {
                if ($barra) {
                    Get-CenCostoMarginal -StartDate $startDate -EndDate $endDate -Barra $barra
                }
                else {
                    Get-CenCostoMarginal -StartDate $startDate -EndDate $endDate
                }
            }

            Write-PodeJsonResponse -Value @{
                fuente    = 'CEN - Costo Marginal Online'
                barra     = if ($barra) { $barra } else { $env:CEN_BARRA_COSTO_MARGINAL }
                startDate = $startDate
                endDate   = $endDate
                total     = $data.Count
                data      = $data
            }
        }
        catch {
            Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "$($_.ScriptStackTrace)" -ForegroundColor DarkRed
            Set-PodeResponseStatus -Code 502
            Write-PodeJsonResponse -Value @{
                error   = 'Error al obtener datos del CEN'
                detalle = $_.Exception.Message
            }
        }
    }

    # =========================================================================
    # RUTA: GET /api/v1/medidas
    # Devuelve Inyeccion_Energia_Activa y Retiro_Energia_Activa.
    # Query params: startDate, endDate (yyyy-MM-dd). Opcional: measurePointId.
    # =========================================================================
    Add-PodeRoute -Method Get -Path '/api/v1/medidas' -Authentication 'ApiKeyAuth' -ScriptBlock {
        try {
            Import-Module (Get-PodeState -Name 'HelpersModulePath') -Force -ErrorAction Stop
            $startDate = $WebEvent.Query['startDate']
            $endDate   = $WebEvent.Query['endDate']
            $mpid      = $WebEvent.Query['measurePointId']

            if ([string]::IsNullOrWhiteSpace($startDate) -or [string]::IsNullOrWhiteSpace($endDate)) {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{
                    error = "Debes especificar 'startDate' y 'endDate' (formato yyyy-MM-dd)."
                }
                return
            }

            $cacheKey = "medidas:" + $startDate + ":" + $endDate + ":" + $mpid

            $data = Get-CachedOrInvoke -Key $cacheKey -ScriptBlock {
                if ($mpid) {
                    Get-CenMedidas -StartDate $startDate -EndDate $endDate -MeasurePointId $mpid
                }
                else {
                    Get-CenMedidas -StartDate $startDate -EndDate $endDate
                }
            }

            # Separar en las dos series que pide el enunciado, ademas de la
            # lista cruda completa.
            $inyeccion = @($data | Where-Object { $_.variable -match 'Inyeccion' })
            $retiro    = @($data | Where-Object { $_.variable -match 'Retiro' })

            Write-PodeJsonResponse -Value @{
                fuente         = 'CEN - Medidas (Generacion)'
                measurePointId = if ($mpid) { $mpid } else { $env:CEN_MEASURE_POINT_ID }
                startDate      = $startDate
                endDate        = $endDate
                inyeccionEnergiaActiva = $inyeccion
                retiroEnergiaActiva    = $retiro
                dataCompleta   = $data
            }
        }
        catch {
            Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "$($_.ScriptStackTrace)" -ForegroundColor DarkRed
            Set-PodeResponseStatus -Code 502
            Write-PodeJsonResponse -Value @{
                error   = 'Error al obtener datos del CEN'
                detalle = $_.Exception.Message
            }
        }
    }

    # =========================================================================
    # RUTA: GET /api/v1/resumen
    # Combina ambos endpoints en una sola respuesta, pensado para alimentar
    # el dashboard con una sola llamada HTTP.
    # =========================================================================
    Add-PodeRoute -Method Get -Path '/api/v1/resumen' -Authentication 'ApiKeyAuth' -ScriptBlock {
        try {
            Import-Module (Get-PodeState -Name 'HelpersModulePath') -Force -ErrorAction Stop
            $startDate = $WebEvent.Query['startDate']
            $endDate   = $WebEvent.Query['endDate']

            if ([string]::IsNullOrWhiteSpace($startDate) -or [string]::IsNullOrWhiteSpace($endDate)) {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{
                    error = "Debes especificar 'startDate' y 'endDate' (formato yyyy-MM-dd)."
                }
                return
            }

            $cmgData = Get-CachedOrInvoke -Key ("cmg:" + $startDate + ":" + $endDate + ":") -ScriptBlock {
                Get-CenCostoMarginal -StartDate $startDate -EndDate $endDate
            }

            $medidasData = Get-CachedOrInvoke -Key ("medidas:" + $startDate + ":" + $endDate + ":") -ScriptBlock {
                Get-CenMedidas -StartDate $startDate -EndDate $endDate
            }

            $inyeccion = @($medidasData | Where-Object { $_.variable -match 'Inyeccion' })
            $retiro    = @($medidasData | Where-Object { $_.variable -match 'Retiro' })

            Write-PodeJsonResponse -Value @{
                startDate = $startDate
                endDate   = $endDate
                costoMarginal          = $cmgData
                inyeccionEnergiaActiva = $inyeccion
                retiroEnergiaActiva    = $retiro
            }
        }
        catch {
            Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "$($_.ScriptStackTrace)" -ForegroundColor DarkRed
            Set-PodeResponseStatus -Code 502
            Write-PodeJsonResponse -Value @{
                error   = 'Error al obtener datos del CEN'
                detalle = $_.Exception.Message
            }
        }
    }

}
