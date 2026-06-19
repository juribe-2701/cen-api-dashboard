# Quillagua · Monitor CEN

Dashboard de monitoreo energético que expone datos del **Coordinador Eléctrico Nacional (CEN)** de Chile a través de una **API REST propia** desarrollada en PowerShell (framework Pode), consumida por un dashboard HTML + Chart.js.

Muestra para el proyecto Quillagua (subestación Frontera 220 kV):
⚠️ **Alcance del proyecto: solución local.** El backend (API REST propia) está diseñado para ejecutarse en local, según lo permitido por el enunciado. El dashboard también está publicado en GitHub Pages (enlace al final del README) para poder ver la interfaz sin instalar nada, **pero esa versión publicada no mostrará datos** a menos que el backend esté corriendo en la misma máquina desde la que se abre el link — apuntando el campo "URL del backend" a `http://localhost:8080`. Para ver el dashboard con datos reales, sigue la sección "Puesta en marcha" más abajo.

- **Costo Marginal Online** (USD/MWh) — barra `FRONTERA______220`
- **Inyección de Energía Activa** (kWh) — punto `FRONTERA_220_J7-J8_QUI`
- **Retiro de Energía Activa** (kWh) — punto `FRONTERA_220_J7-J8_QUI`

---

## Estructura del repositorio

```
cen-api-dashboard/
├── api/
│   ├── Start-CenApi.ps1            # Servidor Pode — punto de entrada del backend
│   ├── .env.example                # Plantilla de variables de entorno
│   └── CenApiHelpers/
│       └── CenApiHelpers.psm1      # Modulo con las funciones propias:
│                                    #   Import-DotEnv, Get-CachedOrInvoke,
│                                    #   Get-CenCostoMarginal, Get-CenMedidas
└── dashboard/
    ├── index.html                  # Dashboard HTML + Chart.js
    ├── serve.ps1                   # Servidor HTTP estatico para el dashboard
    └── assets/
        ├── styles.css
        └── app.js
```

> **Nota de diseño:** las funciones propias del backend están empaquetadas en
> un módulo `.psm1` (no scripts sueltos con dot-source) porque Pode ejecuta
> cada ruta en su propio runspace aislado. Solo un módulo importado con
> `Import-Module`, registrado además vía `Set-PodeState`, se propaga de forma
> confiable a todos esos runspaces.

---

## Requisitos previos

| Herramienta | Versión mínima | Cómo verificar |
|---|---|---|
| PowerShell | 7.x (pwsh) | `pwsh --version` o `$PSVersionTable` |
| Módulo **Pode** | 2.x | `Get-Module -ListAvailable -Name Pode` |
| Navegador moderno | Chrome / Edge | — |

Si Pode no está instalado:

```powershell
Install-Module -Name Pode -Scope CurrentUser -Force -AllowClobber
```

> Si tu PowerShellGet es muy antiguo y `Install-Module` falla con errores de
> ruta (`DirectoryNotFoundException`), instala Pode manualmente: descarga el
> paquete desde `https://www.powershellgallery.com/api/v2/package/Pode`,
> renómbralo a `.zip`, y descomprímelo en
> `$HOME\Documents\PowerShell\Modules\Pode\<version>\`.

---

## Puesta en marcha (paso a paso)

### 1 · Configurar variables de entorno

```powershell
cd api
Copy-Item .env.example .env
```

Edita `.env` y reemplaza `OWN_API_KEY` con una clave propia generada así:

```powershell
-join ((48..57)+(65..90)+(97..122) | Get-Random -Count 40 | %{[char]$_})
```

El resto de variables (API keys del CEN, URLs, barra, punto de medida) ya
vienen completas según el enunciado del proyecto:

```env
OWN_API_KEY=pega_aqui_tu_clave_generada

CEN_COSTO_MARGINAL_API_KEY=9c7e337ac19d47ce632bf66d709b2afc
CEN_MEDIDAS_API_KEY=6ef7142eebd5105c424274173e91b07e
CEN_BARRA_COSTO_MARGINAL=FRONTERA______220
CEN_MEASURE_POINT_ID=FRONTERA_220_J7-J8_QUI
SERVER_PORT=8080
CACHE_TTL_SECONDS=60
```

> El archivo `.env` nunca debe subirse al repositorio (ya está en `.gitignore`).

### 2 · Iniciar el backend (API REST propia)

En una ventana de PowerShell 7:

```powershell
cd api
.\Start-CenApi.ps1
```

Debe quedar mostrando:

```
- HTTP : http://localhost:8080/
[..] Pode v2.13.4 (PID: ####) [En ejecución]
```

**Deja esta ventana abierta** — es el servidor backend corriendo.

### 3 · Iniciar el servidor del dashboard

En **otra** ventana de PowerShell 7 (sin cerrar la anterior):

```powershell
cd dashboard
.\serve.ps1
```

Debe quedar mostrando:

```
Dashboard Quillagua disponible en: http://localhost:3000
```

**Deja esta ventana también abierta.**

> **¿Por qué un segundo servidor solo para el HTML?** Abrir `index.html`
> directamente desde el disco (`file://...`) hace que el navegador bloquee
> el fetch hacia `http://localhost:8080` y el storage de scripts externos
> (Tracking Prevention). Sirviendo el dashboard también por HTTP, aunque sea
> local, se evita esa restricción del navegador.

### 4 · Abrir el dashboard

Abre en el navegador:

```
http://localhost:3000
```

En el formulario:
1. **Desde / Hasta:** selecciona un rango de fechas (recomendado: fechas
   recientes, ya que el CEN solo conserva datos de los últimos meses)
2. **API Key propia:** pega el mismo valor que pusiste en `OWN_API_KEY`
3. **URL del backend:** déjala en `http://localhost:8080`
4. Clic en **Cargar datos**

Deberías ver los 3 KPIs, el gráfico de Costo Marginal, el gráfico de
Inyección vs. Retiro, el balance neto y la tabla de datos, todos con
información real del CEN.

---

## Verificación rápida por línea de comandos (opcional)

Si algo no carga en el navegador, estos comandos aíslan si el problema está
en el backend o en el dashboard:

```powershell
# 1. Backend vivo (sin autenticación)
Invoke-RestMethod http://localhost:8080/health

# 2. Endpoint protegido (reemplaza TU_API_KEY)
$apiKey = "TU_API_KEY"
Invoke-RestMethod -Uri "http://localhost:8080/api/v1/resumen?startDate=2026-06-01&endDate=2026-06-05" -Headers @{ 'X-API-KEY' = $apiKey }
```

Si el paso 2 devuelve datos en `costoMarginal`, `inyeccionEnergiaActiva` y
`retiroEnergiaActiva`, el backend funciona correctamente y cualquier
problema restante está en el navegador (revisar consola con F12).

---

## Endpoints de la API propia

| Método | Ruta | Auth | Descripción |
|--------|------|------|-------------|
| GET | `/health` | No | Estado del servidor |
| GET | `/api/v1/costo-marginal` | X-API-KEY | Costo Marginal Online del CEN |
| GET | `/api/v1/medidas` | X-API-KEY | Inyección y Retiro de Energía Activa |
| GET | `/api/v1/resumen` | X-API-KEY | Ambos endpoints combinados (usado por el dashboard) |

### Parámetros comunes

| Param | Obligatorio | Formato | Ejemplo |
|-------|-------------|---------|---------|
| `startDate` | Sí | `yyyy-MM-dd` | `2026-06-01` |
| `endDate` | Sí | `yyyy-MM-dd` | `2026-06-05` |
| `barra` | No | string | `FRONTERA______220` |
| `measurePointId` | No | string | `FRONTERA_220_J7-J8_QUI` |

### Ejemplo de respuesta `/api/v1/resumen`

```json
{
  "startDate": "2026-06-01",
  "endDate": "2026-06-02",
  "costoMarginal": [
    { "fecha": "2026-06-01", "hora": "2026-06-01 00:00", "barra": "FRONTERA______220", "costoMarginalUSD": 95.05, "costoMarginalCLP": 84.87, "unidad": "USD/MWh" }
  ],
  "inyeccionEnergiaActiva": [
    { "fecha": "2026-06-01", "hora": "00:00:00", "variable": "Inyeccion_Energia_Activa", "valor": 1089.15, "unidad": "kWh" }
  ],
  "retiroEnergiaActiva": [
    { "fecha": "2026-06-01", "hora": "00:00:00", "variable": "Retiro_Energia_Activa", "valor": 3.47, "unidad": "kWh" }
  ]
}
```

---

## Decisiones técnicas

### Framework backend: Pode

Se eligió **[Pode](https://github.com/Badgerati/Pode)** como framework HTTP
para PowerShell por ser el más maduro y activo del ecosistema: soporta
múltiples hilos, middleware, logging y mecanismos de autenticación listos
para usar. Implementarlo a mano con `System.Net.HttpListener` (como sí se
hizo para el servidor estático simple del dashboard) habría requerido
reescribir routing, autenticación y manejo de errores desde cero.

### Mecanismo de seguridad: API Key propia por header

Se eligió autenticación por **API Key estática** enviada en el header
`X-API-KEY`, validada mediante `New-PodeAuthScheme -ApiKey`.

**Por qué API Key y no JWT:** JWT agrega complejidad (login, firma,
expiración) no justificada para un consumidor único y conocido (el propio
dashboard) en un contexto local/demo. Una API Key compartida entre backend y
frontend es el mecanismo más simple y directo para este escenario.

**Por qué header y no query string:** las credenciales en la URL quedan
expuestas en logs de servidor, historial del navegador y cabeceras
`Referer`. Un header HTTP no se registra por defecto en esos lugares.

**Para producción real:** se reemplazaría por OAuth 2.0 client credentials
o JWT de corta duración. API Key es la decisión correcta para este alcance.

### Funciones propias como módulo `.psm1`, no scripts sueltos

Pode ejecuta cada ruta (`Add-PodeRoute`) en un runspace aislado del script
principal. Las funciones cargadas con dot-source (`. archivo.ps1`) solo
existen en el scope del script que las cargó y **no son visibles** dentro de
esos runspaces — error detectado y corregido durante el desarrollo
(`Get-CachedOrInvoke is not recognized...`). La solución robusta fue:
empaquetar las funciones en un módulo real e importarlo con `Import-Module`,
reforzado con `Set-PodeState`/`Get-PodeState` para compartir la ruta del
módulo de forma confiable entre runspaces (las variables `$global:` tampoco
se propagan automáticamente a las rutas de Pode).

### Cache en memoria con TTL

La API del CEN actualiza el costo marginal cada 15 minutos. Se implementó
un cache en memoria (Hashtable) con TTL configurable (`CACHE_TTL_SECONDS`,
default 60 s) para evitar llamadas redundantes al CEN en recargas seguidas
del dashboard. No se usó un sistema externo (Redis) para mantener la
solución completamente local y sin dependencias adicionales.

### CORS abierto en local

El middleware CORS permite `Access-Control-Allow-Origin: *` porque el
dashboard se sirve desde un origen distinto (`localhost:3000`) al backend
(`localhost:8080`). En producción esto debería restringirse al origen
exacto del frontend desplegado.

### Servidor estático propio para el dashboard (`serve.ps1`)

Abrir `index.html` directamente desde el disco (`file://`) provoca que el
navegador bloquee el `fetch()` hacia el backend y el storage usado por
librerías externas (Tracking Prevention de Edge/Chrome) — error detectado
durante las pruebas. La solución fue agregar un segundo servidor HTTP
mínimo, también en PowerShell puro (`System.Net.HttpListener`, sin Node ni
Python), exclusivamente para servir los archivos estáticos del dashboard.

### Normalización de la respuesta del CEN

Los campos reales de la API del CEN (`cmg_usd_mwh_`, `channel1`,
`channel3`, `fecha_minuto`, etc., descubiertos contra la documentación
interactiva real, no solo la genérica) se mapean a un contrato propio
estable (`costoMarginalUSD`, `variable`, `valor`, `fecha`, `hora`). Esto
desacopla el dashboard de cambios futuros en los nombres de campo del CEN:
si el CEN los cambia, solo se ajusta el módulo `CenApiHelpers.psm1`.

### Dashboard: HTML estático + Chart.js

Se eligió HTML/CSS/JS puro con Chart.js (sin framework SPA) para que el
dashboard sea liviano y fácil de inspeccionar. Chart.js se carga con un
fallback de dos CDNs (jsdelivr → cdnjs) para mayor resiliencia ante
bloqueos de un CDN específico por el navegador.

---

## Notas sobre la API del CEN (parámetros reales verificados)

La documentación oficial está en:
- **CMg:** https://portal.api.coordinador.cl/documentacion?service=sipubv2
- **Medidas:** https://portal.api.coordinador.cl/documentacion?service=medidas

**Costo Marginal Online** (`/costo-marginal-online/v4/findByDate`):
- `startDate`, `endDate`: formato `yyyy-MM-dd`
- `bar_transf`: código exacto de la barra (ej. `FRONTERA______220`)
- `user_key`: la API key también como query param (además del header
  `Ocp-Apim-Subscription-Key`)
- `page`, `limit`: paginación; la respuesta trae `totalPages`. El cliente
  recorre automáticamente hasta 10 páginas (1000 registros)
- Campo de valor: `cmg_usd_mwh_` (USD/MWh) y `cmg_clp_kwh_` (CLP/kWh)
- Campo de fecha/hora: `fecha` + `fecha_minuto`

**Medidas** (`/medidas-v2/measurement`):
- No acepta rango de fechas: trabaja por **periodo mensual**, en formato
  `period=YYYYMMDDHHMM` (12 dígitos exactos; `YYYYMM` solo devuelve `400`)
- Requiere `channelId` (ej. `1,2,3,4`) y `measurePointId` exacto
- La respuesta incluye un array `channel[]` que describe qué representa
  cada `channelN`. Para `FRONTERA_220_J7-J8_QUI`:
  - `channel1` = Retiro_Energia_Activa (kWhD)
  - `channel2` = Retiro_Energia_Reactiva (kVarhD)
  - `channel3` = Inyección_Energia_Activa (kWhR)
  - `channel4` = Inyección_Energia_Reactiva (kVarhR)
- El cliente propio calcula los meses cubiertos por el rango pedido,
  consulta cada mes con `period=<mes>010000`, y filtra los registros
  (`measurement[].dateRange`) al rango exacto de días solicitado.

Si el CEN cambia estos nombres de campos o parámetros, ajustar las
funciones `Get-CenCostoMarginal` / `Get-CenMedidas` dentro de
`api/CenApiHelpers/CenApiHelpers.psm1`.

---

## Resolución de problemas comunes

| Síntoma | Causa | Solución |
|---|---|---|
| `Export-ModuleMember cmdlet can only be called from inside a module` | Archivo `.ps1` cargado con dot-source en vez de `.psm1` importado | Ya resuelto en esta versión (todo vive en `CenApiHelpers.psm1`) |
| `'Get-CachedOrInvoke' is not recognized` dentro de una ruta | Funciones no propagadas al runspace de la ruta | Ya resuelto con `Set-PodeState` + `Import-Module` en cada ruta |
| Dashboard dice "Sin conectar" sin error visible | Chart.js bloqueado por Tracking Prevention al abrir `file://` | Usar `serve.ps1` en vez de abrir el HTML directamente |
| `HTTP 502: Bad Gateway` en el dashboard | El backend no logró autenticarse o parsear la respuesta del CEN | Revisar la consola del servidor Pode — el error real ahora se imprime en rojo |
| `Install-Module` falla con `DirectoryNotFoundException` | PowerShellGet desactualizado (v1.0.0.1) | Instalar Pode manualmente vía descarga directa del `.nupkg` |
| Servidor corre en PowerShell 5 pero Pode no se encuentra | Pode instalado en la ruta de módulos de PS5, no de PS7 | Copiar la carpeta del módulo a `$HOME\Documents\PowerShell\Modules\Pode\<version>\` |

---

## Despliegue del dashboard (enlace público)

El dashboard está publicado vía GitHub Pages:

**https://juribe-2701.github.io/cen-api-dashboard/dashboard/**

> Esa URL sirve el HTML/CSS/JS del dashboard. Para que muestre datos reales,
> el backend (`api/Start-CenApi.ps1`) debe estar corriendo (localmente, o en
> algún servidor accesible) y el campo **URL del backend** en el dashboard
> debe apuntar a esa dirección — por defecto trae `http://localhost:8080`,
> válido solo si el backend corre en la misma máquina desde la que se abre
> el dashboard.

---

## Pasos para subir el repositorio a GitHub

```powershell
cd C:\_NB-HOMY_JC\JC\PS\cen-api-dashboard
git init
git add .
git status   # Verificar que api/.env NO aparece en la lista (debe estar ignorado)
git commit -m "Quillagua Monitor CEN - API REST + Dashboard"
git branch -M main
git remote add origin https://github.com/TU-USUARIO/cen-api-dashboard.git
git push -u origin main
```

Luego comparte la URL del repositorio (`https://github.com/TU-USUARIO/cen-api-dashboard`)
con la persona de contacto del proceso antes del plazo indicado.

---

```gitignore
# Variables de entorno (NUNCA subir al repo)
api/.env

# PowerShell
*.ps1xml

# OS
.DS_Store
Thumbs.db
```
