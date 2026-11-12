// REND-2 (HU-BE-24, R2-25) · 500 postulaciones simultáneas a una convocatoria de 10 cupos, a través del
// balanceador (las réplicas de marketplace compiten por la misma fila). Criterios: 100 % responde con una
// decisión definitiva (ACEPTADA o EN_ESPERA), p95 ≤ 1 s, exactamente 10 aceptadas, 0 sobreasignaciones.
//
//   docker run --rm --network host -v "$PWD":/scripts grafana/k6:1.4.2 run /scripts/rend2-applications.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { BASE, createProject, headers, token } from './lib/zeal.js';

const APPLICANTS = Number(__ENV.APPLICANTS || 500);
const CAPACITY = 10;
const accepted = new Counter('rend2_aceptadas');
const waitlisted = new Counter('rend2_en_espera');
const undecided = new Counter('rend2_sin_decision');

export const options = {
  scenarios: {
    postulaciones: { executor: 'shared-iterations', vus: APPLICANTS, iterations: APPLICANTS, maxDuration: '2m' },
  },
  thresholds: {
    'http_req_duration{name:postular}': ['p(95)<1000'],
    'http_req_failed{name:postular}': ['rate==0'],
    rend2_aceptadas: [`count==${CAPACITY}`],
    rend2_sin_decision: ['count==0'],
    checks: ['rate==1'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  return { projectId: createProject(token('usr-admin-001', 'ADMIN'), CAPACITY, `REND-2 ${Date.now()}`).id };
}

export default function ({ projectId }) {
  const applicant = token(`rend2-${__VU}-${Date.now()}`, 'EMPLEADO');
  const res = http.post(`${BASE}/api/proyectos/${projectId}/postulaciones`, null,
    { ...headers(applicant), tags: { name: 'postular' } });
  const status = res.status === 201 ? res.json('status') : null;
  if (status === 'ACEPTADA') accepted.add(1);
  else if (status === 'EN_ESPERA') waitlisted.add(1);
  else undecided.add(1);
  check(res, { 'decisión definitiva (201)': () => status === 'ACEPTADA' || status === 'EN_ESPERA' });
}

export function teardown({ projectId }) {
  const detail = http.get(`${BASE}/api/proyectos/${projectId}`, headers(token('usr-empleado-001', 'EMPLEADO')));
  check(detail, { 'occupied en la base = 10 (sin sobreasignación)': (r) => r.json('occupied') === CAPACITY });
}
