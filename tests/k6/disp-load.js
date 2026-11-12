// Carga habitual para DISP-1 / DISP-2 (HU-BE-19): lecturas de los tres servicios y escrituras
// confirmadas (postulaciones) a través del balanceador. Cada postulación aceptada por el servidor
// (201) se cuenta en `confirmed_writes`; el script de shell compara ese número con la base de datos
// para medir "operaciones confirmadas perdidas".
//
//   RATE=40 DURATION=120s k6 run disp-load.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import { BASE, createProject, headers, token } from './lib/zeal.js';

const confirmedWrites = new Counter('confirmed_writes');
const visibleErrors = new Counter('visible_errors');
const byService = {
  wellbeing: new Trend('latency_wellbeing', true),
  marketplace: new Trend('latency_marketplace', true),
  realtime: new Trend('latency_realtime', true),
};

export const options = {
  scenarios: {
    habitual: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 40), timeUnit: '1s', duration: __ENV.DURATION || '120s',
      preAllocatedVUs: 50, maxVUs: 400,
    },
    ...(__ENV.DOUBLE_AT ? {
      doble: {   // DISP-2: la demanda se duplica a partir de DOUBLE_AT
        executor: 'constant-arrival-rate', startTime: __ENV.DOUBLE_AT,
        rate: Number(__ENV.RATE || 40), timeUnit: '1s', duration: __ENV.DOUBLE_FOR || '90s',
        preAllocatedVUs: 50, maxVUs: 400,
      },
    } : {}),
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  const project = createProject(token('usr-admin-001', 'ADMIN'), 100, `DISP ${new Date().toISOString()}`);
  return { projectId: project.id };
}

const employee = token('usr-empleado-001', 'EMPLEADO');
const psychologist = token('usr-psicologo-001', 'PSICOLOGO', 'ZEAL');

export default function ({ projectId }) {
  const pick = Math.random();
  let res;
  let service;
  if (pick < 0.3) {
    service = 'wellbeing';
    res = http.get(`${BASE}/api/wellbeing/psicologos`, headers(employee));
  } else if (pick < 0.6) {
    service = 'marketplace';
    res = http.get(`${BASE}/api/talleres`, headers(employee));
  } else if (pick < 0.8) {
    service = 'realtime';
    res = http.get(`${BASE}/api/notificaciones`, headers(psychologist));
  } else {
    service = 'marketplace';
    const applicant = token(`disp-${__VU}-${__ITER}-${Date.now()}`, 'EMPLEADO');
    res = http.post(`${BASE}/api/proyectos/${projectId}/postulaciones`, null, headers(applicant));
    if (res.status === 201) confirmedWrites.add(1);
  }
  byService[service].add(res.timings.duration);
  const ok = check(res, { 'respuesta 2xx': (r) => r.status >= 200 && r.status < 300 });
  if (!ok) visibleErrors.add(1, { service, status: String(res.status) });
}

export function handleSummary(data) {
  const out = __ENV.SUMMARY_FILE || '/tmp/disp-summary.json';
  return { [out]: JSON.stringify(data, null, 2), stdout: '' };
}
