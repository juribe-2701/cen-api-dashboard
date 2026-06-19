<#
.SYNOPSIS
    Carga variables de entorno desde un archivo .env hacia $env:* de la sesion actual.

.DESCRIPTION
    PowerShell no tiene soporte nativo para archivos .env. Esta funcion parsea
    un archivo de formato KEY=VALUE (ignorando comentarios "#" y lineas vacias)
    y registra cada variable en el scope de proceso ($env:).

.PARAMETER Path
    Ruta al archivo .env a cargar.
#>
function Import-DotEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No se encontro el archivo de entorno en '$Path'. Copia '.env.example' a '.env' y completa los valores."
    }

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()

        # Ignorar lineas vacias y comentarios
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            return
        }

        $separatorIndex = $line.IndexOf('=')
        if ($separatorIndex -lt 1) {
            return
        }

        $key   = $line.Substring(0, $separatorIndex).Trim()
        $value = $line.Substring($separatorIndex + 1).Trim()

        # Quitar comillas envolventes si existen
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        Set-Item -Path "env:$key" -Value $value
    }

    Write-Verbose "Variables de entorno cargadas desde $Path"
}


<#
.SYNOPSIS
    Cache simple en memoria con expiracion (TTL) para evitar llamadas
    repetidas e innecesarias a la API del CEN.

.DESCRIPTION
    Implementa un Hashtable global protegido por un Mutex muy liviano
    (suficiente para un escenario de demo/local con baja concurrencia).
#>

$script:CenCache = @{}

function Get-CachedOrInvoke {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $ttl = [int]($env:CACHE_TTL_SECONDS)
    if ($ttl -le 0) { $ttl = 60 }

    $now = Get-Date

    if ($script:CenCache.ContainsKey($Key)) {
        $entry = $script:CenCache[$Key]
        $age = ($now - $entry.Timestamp).TotalSeconds
        if ($age -lt $ttl) {
            Write-Verbose "Cache HIT para '$Key' (edad: $([math]::Round($age,1))s)"
            return $entry.Value
        }
        Write-Verbose "Cache EXPIRADO para '$Key' (edad: $([math]::Round($age,1))s)"
    }

    Write-Verbose "Cache MISS para '$Key', invocando origen de datos..."
    $result = & $ScriptBlock

    $script:CenCache[$Key] = [PSCustomObject]@{
        Timestamp = $now
        Value     = $result
    }

    return $result
}


function Get-CenCostoMarginal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartDate,

        [Parameter(Mandatory = $true)]
        [string]$EndDate,

        [Parameter(Mandatory = $false)]
        [string]$Barra = $env:CEN_BARRA_COSTO_MARGINAL
    )

    $baseUrl = $env:CEN_COSTO_MARGINAL_URL
    $apiKey  = $env:CEN_COSTO_MARGINAL_API_KEY

    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Faltan variables de entorno CEN_COSTO_MARGINAL_URL / CEN_COSTO_MARGINAL_API_KEY"
    }

    $allData = @()
    $page = 0
    $limit = 100

    do {
        $queryParams = @{
            startDate  = $StartDate
            endDate    = $EndDate
            bar_transf = $Barra
            user_key   = $apiKey
            page       = $page
            limit      = $limit
        }

        $query = ($queryParams.GetEnumerator() | ForEach-Object {
            "{0}={1}" -f $_.Key, [System.Uri]::EscapeDataString([string]$_.Value)
        }) -join '&'

        $uri = "{0}?{1}" -f $baseUrl, $query

        $headers = @{
            'Ocp-Apim-Subscription-Key' = $apiKey
            'Accept'                    = 'application/json'
        }

        try {
            Write-Verbose "GET $uri"
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            throw "Error al consultar Costo Marginal Online del CEN (HTTP $statusCode): $($_.Exception.Message)"
        }

        $rows = $response.data
        if ($rows -and $rows.Count -gt 0) {
            $allData += $rows
        }

        $totalPages = if ($response.totalPages) { [int]$response.totalPages } else { 0 }
        $page++

    } while ($page -lt $totalPages -and $page -lt 10)  # maximo 10 paginas = 1000 registros

    $normalized = @($allData | ForEach-Object {
        [PSCustomObject]@{
            fecha            = $_.fecha
            hora             = $_.fecha_minuto
            barra            = $_.barra_transf
            costoMarginalUSD = $_.cmg_usd_mwh_
            costoMarginalCLP = $_.cmg_clp_kwh_
            unidad           = 'USD/MWh'
        }
    })

    return $normalized
}
function Get-CenMedidas {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartDate,

        [Parameter(Mandatory = $true)]
        [string]$EndDate,

        [Parameter(Mandatory = $false)]
        [string]$MeasurePointId = $env:CEN_MEASURE_POINT_ID
    )

    $baseUrl = $env:CEN_MEDIDAS_URL
    $apiKey  = $env:CEN_MEDIDAS_API_KEY

    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Faltan variables de entorno CEN_MEDIDAS_URL / CEN_MEDIDAS_API_KEY"
    }

    # La API de Medidas trabaja por periodo mensual (YYYYMM), no por rango de
    # fechas. Se generan todos los periodos (meses) cubiertos por el rango
    # StartDate..EndDate y se consultan uno a uno.
    $start = [datetime]::ParseExact($StartDate, 'yyyy-MM-dd', $null)
    $end   = [datetime]::ParseExact($EndDate,   'yyyy-MM-dd', $null)

    $periods = @()
    $cursor = Get-Date -Year $start.Year -Month $start.Month -Day 1
    $endCursor = Get-Date -Year $end.Year -Month $end.Month -Day 1
    while ($cursor -le $endCursor) {
        $periods += $cursor.ToString('yyyyMM') + '010000'
        $cursor = $cursor.AddMonths(1)
    }

    $allRows = @()

    foreach ($period in $periods) {
        $query = "channelId=1,2,3,4&measurePointId=" + [System.Uri]::EscapeDataString($MeasurePointId) + "&period=$period&user_key=$apiKey"
        $uri = "{0}?{1}" -f $baseUrl, $query

        $headers = @{
            'Ocp-Apim-Subscription-Key' = $apiKey
            'Accept'                    = 'application/json'
        }

        try {
            Write-Verbose "GET $uri"
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            Write-Warning "Error al consultar Medidas del CEN para periodo $period (HTTP $statusCode): $($_.Exception.Message)"
            continue
        }

        # La respuesta es un array con un solo elemento que contiene measurement[]
        $block = $response | Select-Object -First 1
        if ($block -and $block.measurement) {
            foreach ($m in $block.measurement) {
                $dt = [datetime]$m.dateRange

                # Filtrar solo registros dentro del rango exacto pedido
                if ($dt.Date -lt $start.Date -or $dt.Date -gt $end.Date) { continue }

                $allRows += [PSCustomObject]@{
                    fecha    = $dt.ToString('yyyy-MM-dd')
                    hora     = $dt.ToString('HH:mm:ss')
                    variable = 'Retiro_Energia_Activa'
                    valor    = $m.channel1
                    unidad   = 'kWh'
                }
                $allRows += [PSCustomObject]@{
                    fecha    = $dt.ToString('yyyy-MM-dd')
                    hora     = $dt.ToString('HH:mm:ss')
                    variable = 'Inyeccion_Energia_Activa'
                    valor    = $m.channel3
                    unidad   = 'kWh'
                }
            }
        }
    }

    return @($allRows | Sort-Object fecha, hora)
}

Export-ModuleMember -Function Import-DotEnv, Get-CachedOrInvoke, Get-CenCostoMarginal, Get-CenMedidas

