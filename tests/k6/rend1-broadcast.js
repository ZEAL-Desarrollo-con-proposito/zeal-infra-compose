// REND-1 (HU-BE-24, R2-25) · 500 empleados conectados por WebSocket/STOMP, repartidos entre las réplicas
// del gateway por NGINX. Una administradora publica convocatorias y se mide, en CADA cliente, cuánto tarda
// en llegarle (desde que la administradora envía el POST hasta que el mensaje llega por STOMP).
// Criterios: p95 ≤ 500 ms, 0 eventos perdidos, 0 errores.
//
//   docker run --rm --network host -v "$PWD":/scripts grafana/k6:1.4.2 run /scripts/rend1-broadcast.js
//   CLIENTS=500 PUBLICATIONS=3 (variables de entorno)
import ws from 'k6/ws';
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { BASE, headers, token } from './lib/zeal.js';

const CLIENTS = Number(__ENV.CLIENTS || 500);
const PUBLICATIONS = Number(__ENV.PUBLICATIONS || 3);
const WS_BASE = BASE.replace(/^http/, 'ws');
const TOPIC = '/topic/organizaciones/Nexura%20S.A.S./proyectos';

const latency = new Trend('rend1_latencia', true);
const delivered = new Counter('rend1_entregados');
const lost = new Counter('rend1_perdidos');
const connected = new Rate('rend1_conexion_ok');

export const options = {
  scenarios: {
    empleados: { executor: 'per-vu-iterations', exec: 'employee', vus: CLIENTS, iterations: 1, maxDuration: '3m' },
    administradora: { executor: 'per-vu-iterations', exec: 'admin', vus: 1, iterations: 1, startTime: '25s', maxDuration: '2m' },
  },
  thresholds: {
    rend1_latencia: ['p(95)<500'],
    rend1_perdidos: ['count==0'],
    rend1_conexion_ok: ['rate==1'],
    'http_req_failed{scenario:administradora}': ['rate==0'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

const frame = (command, headersMap, body = '') =>
  `${command}\n${Object.entries(headersMap).map(([k, v]) => `${k}:${v}`).join('\n')}\n\n${body}\u0000`;

export function employee() {
  const bearer = token(`rend1-${__VU}`, 'EMPLEADO', 'Nexura S.A.S.');
  const seen = new Set();
  const res = ws.connect(`${WS_BASE}/ws/websocket`, {}, (socket) => {
    socket.on('open', () => {
      socket.send(frame('CONNECT', { 'accept-version': '1.2', 'heart-beat': '10000,10000', Authorization: `Bearer ${bearer}` }));
      socket.setInterval(() => socket.send('\n'), 10000); // latido STOMP (renueva la presencia)
    });
    socket.on('message', (data) => {
      for (const raw of data.split('\u0000')) {
        const message = raw.replace(/^\n+/, '');
        if (message.startsWith('CONNECTED')) {
          connected.add(true);
          socket.send(frame('SUBSCRIBE', { id: 'sub-0', destination: TOPIC }));
        } else if (message.startsWith('MESSAGE')) {
          const body = JSON.parse(message.slice(message.indexOf('\n\n') + 2));
          const sentAt = Number((body.project?.title || '').split('·')[1]);
          if (body.type === 'PUBLICADO' && sentAt && !seen.has(sentAt)) {
            seen.add(sentAt);
            latency.add(Date.now() - sentAt);
            delivered.add(1);
          }
        } else if (message.startsWith('ERROR')) {
          connected.add(false);
        }
      }
    });
    socket.setTimeout(() => socket.close(), 25000 + PUBLICATIONS * 5000 + 15000);
  });
  check(res, { 'handshake 101': (r) => r && r.status === 101 }) || connected.add(false);
  lost.add(Math.max(0, PUBLICATIONS - seen.size));
}

export function admin() {
  const bearer = token('usr-admin-001', 'ADMIN', 'Nexura S.A.S.');
  for (let i = 0; i < PUBLICATIONS; i++) {
    const sentAt = Date.now();
    const res = http.post(`${BASE}/api/admin/proyectos`, JSON.stringify({
      title: `REND-1 ${i}·${sentAt}`, area: 'Plataforma', cohort: 'Carga', summary: 'Publicación medida por k6.',
      description: ['REND-1: latencia de difusión a 500 empleados.'], requirements: [], skills: [], capacity: 5,
      closesAt: new Date(Date.now() + 864e5).toISOString(),
    }), headers(bearer));
    check(res, { 'publicada 201': (r) => r.status === 201 });
    sleep(5);
  }
}
