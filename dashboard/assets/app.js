/* =====================================================================
   QUILLAGUA · Monitor CEN — app.js
   Consume la API REST propia (PowerShell / Pode) y renderiza los datos
   del CEN en los graficos Chart.js y la tabla.
   ===================================================================== */

'use strict';

// ── Verificacion de que Chart.js cargo correctamente ───────────────────
if (typeof Chart === 'undefined') {
  document.addEventListener('DOMContentLoaded', () => {
    const banner = document.getElementById('error-banner');
    if (banner) {
      banner.hidden = false;
      banner.textContent = 'No se pudo cargar la librería Chart.js (bloqueada por el navegador o sin conexión a internet). Descárgala manualmente y referénciala desde assets/. Ver README.';
    }
  });
}

// ── Referencias al DOM ─────────────────────────────────────────────────
const btnLoad        = document.getElementById('btn-load');
const startDateInput = document.getElementById('start-date');
const endDateInput   = document.getElementById('end-date');
const apiKeyInput    = document.getElementById('api-key');
const apiBaseInput   = document.getElementById('api-base-url');
const errorBanner    = document.getElementById('error-banner');
const statusDot      = document.getElementById('status-dot');
const statusLabel    = document.getElementById('status-label');
const kpiCmg         = document.getElementById('kpi-cmg');
const kpiIny         = document.getElementById('kpi-iny');
const kpiRet         = document.getElementById('kpi-ret');
const tableBody      = document.querySelector('#data-table tbody');

// ── Estado de los gráficos (para destruirlos antes de redibujar) ───────
let chartCmg     = null;
let chartMedidas = null;
let chartBalance = null;

// ── Defaults de fecha (últimos 3 días) ────────────────────────────────
(function setDefaultDates() {
  const today = new Date();
  const prior = new Date(today);
  prior.setDate(today.getDate() - 3);
  endDateInput.value   = today.toISOString().slice(0, 10);
  startDateInput.value = prior.toISOString().slice(0, 10);
})();

// ── Tema Chart.js compartido ───────────────────────────────────────────
const CSS = getComputedStyle(document.documentElement);
const C = {
  amber:   '#E8A33D',
  cyan:    '#3DDC97',
  coral:   '#E85D4C',
  dim:     '#7C8B9C',
  border:  '#232B36',
  surface: '#11161D',
  text:    '#E9EDF1',
};

if (typeof Chart !== 'undefined') {
  Chart.defaults.color          = C.dim;
  Chart.defaults.borderColor    = C.border;
  Chart.defaults.font.family    = "'JetBrains Mono', monospace";
  Chart.defaults.font.size      = 11;
}

function baseOptions(extraOptions = {}) {
  return {
    responsive: true,
    maintainAspectRatio: false,
    animation: { duration: 500 },
    plugins: {
      legend: {
        labels: { color: C.dim, boxWidth: 12, padding: 16 },
      },
      tooltip: {
        backgroundColor: '#0D1218',
        borderColor: C.border,
        borderWidth: 1,
        titleColor: C.text,
        bodyColor: C.dim,
        padding: 10,
      },
    },
    scales: {
      x: {
        ticks: { color: C.dim, maxRotation: 40, autoSkip: true, maxTicksLimit: 10 },
        grid:  { color: C.border },
      },
      y: {
        ticks: { color: C.dim },
        grid:  { color: C.border },
      },
    },
    ...extraOptions,
  };
}

// ── Helpers UI ─────────────────────────────────────────────────────────
function setStatus(state, text) {
  statusDot.className = 'status-dot' + (state ? ` is-${state}` : '');
  statusLabel.textContent = text;
}

function showError(msg) {
  errorBanner.textContent = msg;
  errorBanner.hidden = false;
}

function clearError() {
  errorBanner.hidden = true;
  errorBanner.textContent = '';
}

function fmt(val, decimals = 1) {
  if (val === null || val === undefined || isNaN(val)) return '—';
  return Number(val).toLocaleString('es-CL', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

// ── Llamada a la API propia ────────────────────────────────────────────
async function fetchApi(endpoint, params) {
  const base   = (apiBaseInput.value || 'http://localhost:8080').replace(/\/$/, '');
  const apiKey = apiKeyInput.value.trim();

  if (!apiKey) throw new Error("Ingresa la API Key propia (campo 'X-API-KEY').");

  const qs  = new URLSearchParams(params).toString();
  const url = `${base}${endpoint}?${qs}`;

  const res = await fetch(url, {
    headers: { 'X-API-KEY': apiKey },
  });

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(`HTTP ${res.status}: ${body.error || res.statusText}`);
  }

  return res.json();
}

// ── Destruir gráfico existente de forma segura ─────────────────────────
function destroyChart(ref) {
  if (ref) { try { ref.destroy(); } catch (_) {} }
  return null;
}

// ── Renderizado de gráficos ────────────────────────────────────────────
function renderCmg(data) {
  chartCmg = destroyChart(chartCmg);

  const labels = data.map(d => `${d.fecha ?? ''} ${(d.hora ?? '').slice(0, 5)}`);
  const values = data.map(d => Number(d.costoMarginalUSD));

  chartCmg = new Chart(document.getElementById('chart-cmg'), {
    type: 'line',
    data: {
      labels,
      datasets: [{
        label: 'CMg (USD/MWh)',
        data: values,
        borderColor: C.amber,
        backgroundColor: C.amber + '22',
        pointRadius: 2,
        pointHoverRadius: 5,
        borderWidth: 2,
        fill: true,
        tension: 0.3,
      }],
    },
    options: baseOptions(),
  });

  // KPI: último valor
  const last = values.filter(v => !isNaN(v)).at(-1);
  kpiCmg.textContent = last !== undefined ? fmt(last) : '—';
}

function renderMedidas(inyeccion, retiro) {
  chartMedidas = destroyChart(chartMedidas);
  chartBalance = destroyChart(chartBalance);

  // Usar las fechas de la serie más larga como eje X
  const baseArr = inyeccion.length >= retiro.length ? inyeccion : retiro;
  const labels  = baseArr.map(d => `${d.fecha ?? ''} ${(d.hora ?? '').slice(0, 5)}`);

  const valIny = inyeccion.map(d => Number(d.valor));
  const valRet = retiro.map(d => Number(d.valor));

  // Gráfico comparativo
  chartMedidas = new Chart(document.getElementById('chart-medidas'), {
    type: 'line',
    data: {
      labels,
      datasets: [
        {
          label: 'Inyección Energía Activa (kWh)',
          data: valIny,
          borderColor: C.cyan,
          backgroundColor: C.cyan + '22',
          pointRadius: 2,
          pointHoverRadius: 5,
          borderWidth: 2,
          fill: true,
          tension: 0.3,
        },
        {
          label: 'Retiro Energía Activa (kWh)',
          data: valRet,
          borderColor: C.coral,
          backgroundColor: C.coral + '22',
          pointRadius: 2,
          pointHoverRadius: 5,
          borderWidth: 2,
          fill: true,
          tension: 0.3,
        },
      ],
    },
    options: baseOptions(),
  });

  // Gráfico de balance (inyección − retiro)
  const minLen = Math.min(valIny.length, valRet.length);
  const balance = Array.from({ length: minLen }, (_, i) => valIny[i] - valRet[i]);
  const balanceLabels = labels.slice(0, minLen);

  chartBalance = new Chart(document.getElementById('chart-balance'), {
    type: 'bar',
    data: {
      labels: balanceLabels,
      datasets: [{
        label: 'Balance neto (kWh)',
        data: balance,
        backgroundColor: balance.map(v => v >= 0 ? C.cyan + 'BB' : C.coral + 'BB'),
        borderColor:      balance.map(v => v >= 0 ? C.cyan      : C.coral),
        borderWidth: 1,
        borderRadius: 3,
      }],
    },
    options: baseOptions({
      plugins: { legend: { display: false } },
    }),
  });

  // KPIs
  const lastIny = valIny.filter(v => !isNaN(v)).at(-1);
  const lastRet = valRet.filter(v => !isNaN(v)).at(-1);
  kpiIny.textContent = lastIny !== undefined ? fmt(lastIny) : '—';
  kpiRet.textContent = lastRet !== undefined ? fmt(lastRet) : '—';
}

function renderTable(data) {
  tableBody.innerHTML = '';
  const rows = [...data].reverse().slice(0, 10);
  rows.forEach(d => {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${d.fecha ?? '—'}</td>
      <td>${(d.hora ?? '—').slice(0, 8)}</td>
      <td style="color:var(--amber);text-align:right">${fmt(d.costoMarginalUSD)}</td>
    `;
    tableBody.appendChild(tr);
  });
  if (!rows.length) {
    tableBody.innerHTML = '<tr><td colspan="3" style="text-align:center;color:var(--text-dim)">Sin datos</td></tr>';
  }
}

// ── Carga principal ────────────────────────────────────────────────────
async function loadData() {
  clearError();
  setStatus(null, 'Cargando...');
  btnLoad.disabled = true;
  btnLoad.querySelector('span').textContent = 'Cargando…';

  const params = {
    startDate: startDateInput.value,
    endDate:   endDateInput.value,
  };

  if (!params.startDate || !params.endDate) {
    showError('Debes seleccionar un rango de fechas.');
    setStatus('error', 'Error');
    btnLoad.disabled = false;
    btnLoad.querySelector('span').textContent = 'Cargar datos';
    return;
  }

  try {
    // Llamamos al endpoint /resumen que agrupa ambas fuentes en una sola request
    const data = await fetchApi('/api/v1/resumen', params);

    const cmgData  = data.costoMarginal          ?? [];
    const inyData  = data.inyeccionEnergiaActiva  ?? [];
    const retData  = data.retiroEnergiaActiva     ?? [];

    if (!cmgData.length && !inyData.length && !retData.length) {
      showError('La API respondió correctamente pero no devolvió datos para el rango seleccionado. Prueba con otro rango de fechas.');
      setStatus('error', 'Sin datos');
    } else {
      if (cmgData.length)          renderCmg(cmgData);
      if (inyData.length || retData.length) renderMedidas(inyData, retData);
      if (cmgData.length)          renderTable(cmgData);
      setStatus('online', `Datos actualizados · ${new Date().toLocaleTimeString('es-CL')}`);
    }

  } catch (err) {
    showError(`Error al conectar con el backend: ${err.message}`);
    setStatus('error', 'Error de conexión');
    console.error(err);
  } finally {
    btnLoad.disabled = false;
    btnLoad.querySelector('span').textContent = 'Cargar datos';
  }
}

btnLoad.addEventListener('click', loadData);

// Permitir enviar con Enter desde los campos de fecha / key
[startDateInput, endDateInput, apiKeyInput, apiBaseInput].forEach(el => {
  el.addEventListener('keydown', e => { if (e.key === 'Enter') loadData(); });
});
