<#
.SYNOPSIS
    Servidor HTTP estatico minimo para servir el dashboard (carpeta /dashboard)
    en un puerto distinto al backend, evitando las restricciones de seguridad
    que los navegadores aplican a paginas abiertas directamente como file://.

.DESCRIPTION
    Los navegadores modernos bloquean ciertas llamadas fetch() y el storage
    de scripts externos cuando una pagina se abre directamente desde el
    disco (file://). Servir el dashboard via HTTP (aunque sea local) evita
    estos problemas. Este script no requiere Node ni Python: usa
    System.Net.HttpListener, disponible nativamente en PowerShell.

.NOTES
    Ejecutar con:  pwsh ./serve.ps1
    Por defecto sirve en http://localhost:3000
#>

param(
    [int]$Port = 3000
)

$root = $PSScriptRoot

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")

try {
    $listener.Start()
}
catch {
    Write-Error "No se pudo iniciar el servidor en el puerto $Port. ¿Ya hay algo escuchando ahi? Detalle: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " Dashboard Quillagua disponible en: http://localhost:$Port" -ForegroundColor Cyan
Write-Host " Sirviendo archivos desde: $root" -ForegroundColor Cyan
Write-Host " Presiona Ctrl+C para detener" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

$mimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $path = $request.Url.LocalPath
        if ($path -eq '/') { $path = '/index.html' }

        $filePath = Join-Path $root $path.TrimStart('/')

        if (Test-Path -LiteralPath $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $response.ContentType = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { 'application/octet-stream' }

            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        else {
            $response.StatusCode = 404
            $notFoundBytes = [System.Text.Encoding]::UTF8.GetBytes("404 - Archivo no encontrado: $path")
            $response.OutputStream.Write($notFoundBytes, 0, $notFoundBytes.Length)
        }

        $response.Close()
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
