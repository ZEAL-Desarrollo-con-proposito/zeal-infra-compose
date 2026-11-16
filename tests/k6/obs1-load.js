import http from 'k6/http';
import { BASE, token, headers } from './lib/zeal.js';
export const options = { scenarios: { c: { executor: 'constant-arrival-rate', rate: 6, timeUnit: '1s', duration: __ENV.DURATION || '300s', preAllocatedVUs: 20, maxVUs: 60 } } };
export default function () { http.get(`${BASE}/api/proyectos`, headers(token('usr-empleado-001', 'EMPLEADO'))); }
