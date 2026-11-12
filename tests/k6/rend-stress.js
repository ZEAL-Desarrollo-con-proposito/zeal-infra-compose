// R2-28 · Carga nominal y estrés hasta el punto de quiebre (mezcla habitual de lecturas y postulaciones
// por NGINX). La tasa sube por escalones; k6 corta la prueba cuando el p95 supera 1 s o los errores el
// 1 % (abortOnFail): el último escalón sano es la capacidad del despliegue y el siguiente, el quiebre.
//
//   START=50 STEP=50 STEPS=8 STEP_DURATION=60s k6 run rend-stress.js      (oficial: generador en otra máquina)
import http from 'k6/http';
import { check } from 'k6';
import { BASE, createProject, headers, token } from './lib/zeal.js';

const START = Number(__ENV.START || 50);
const STEP = Number(__ENV.STEP || 50);
const STEPS = Number(__ENV.STEPS || 8);
const STEP_DURATION = __ENV.STEP_DURATION || '60s';

export const options = {
  scenarios: {
    escalones: {
      executor: 'ramping-arrival-rate', startRate: START, timeUnit: '1s', preAllocatedVUs: 200, maxVUs: 3000,
      stages: Array.from({ length: STEPS }, (_, i) => [
        { target: START + STEP * i, duration: '10s' },
        { target: START + STEP * i, duration: STEP_DURATION },
      ]).flat(),
    },
  },
  thresholds: {
    http_req_duration: [{ threshold: 'p(95)<1000', abortOnFail: true, delayAbortEval: '20s' }],
    http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true, delayAbortEval: '20s' }],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  return { projectId: createProject(token('usr-admin-001', 'ADMIN'), 100, `Estrés ${Date.now()}`).id };
}

const employee = token('usr-empleado-001', 'EMPLEADO');

export default function ({ projectId }) {
  const pick = Math.random();
  let res;
  if (pick < 0.35) res = http.get(`${BASE}/api/wellbeing/psicologos`, { ...headers(employee), tags: { name: 'directorio' } });
  else if (pick < 0.7) res = http.get(`${BASE}/api/talleres`, { ...headers(employee), tags: { name: 'talleres' } });
  else if (pick < 0.9) res = http.get(`${BASE}/api/proyectos`, { ...headers(employee), tags: { name: 'convocatorias' } });
  else res = http.post(`${BASE}/api/proyectos/${projectId}/postulaciones`, null,
    { ...headers(token(`estres-${__VU}-${__ITER}`, 'EMPLEADO')), tags: { name: 'postular' } });
  check(res, { '2xx': (r) => r.status >= 200 && r.status < 300 });
}
