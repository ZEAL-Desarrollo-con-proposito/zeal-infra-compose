// R2-16 · SEG-4: robo de sesión con DOS réplicas por servicio. Se reutiliza un refresh token ya usado y se
// verifica que el acceso cae en TODAS las réplicas (REST de los tres servicios y STOMP del gateway) en
// < 1 s y que la auditoría lo registra. Uso: ./seg4-session-theft.sh (resuelve las IPs de las réplicas).
import { Client } from '@stomp/stompjs';
import SockJS from 'sockjs-client';
import { check, finish, microsoftLogin, refresh, sleep } from './lib.mjs';

const replicas = JSON.parse(process.env.REPLICAS ?? '{}'); // { wellbeing: [ip, ip], marketplace: [...], realtime: [...] }
const probes = [
  ...replicas.wellbeing.map((ip) => ({ name: `wellbeing ${ip}`, url: `http://${ip}:8081/api/wellbeing/reservas/mias` })),
  ...replicas.marketplace.map((ip) => ({ name: `marketplace ${ip}`, url: `http://${ip}:8082/api/postulaciones/mias` })),
  ...replicas.realtime.map((ip) => ({ name: `realtime ${ip}`, url: `http://${ip}:8083/api/notificaciones` })),
];
const statusOf = async (url, token) => (await fetch(url, { headers: { Authorization: `Bearer ${token}` } })).status;

function connect(ip, token) {
  return new Promise((resolve, reject) => {
    const client = new Client({ webSocketFactory: () => new SockJS(`http://${ip}:8083/ws`), connectHeaders: { Authorization: `Bearer ${token}` },
      reconnectDelay: 0, heartbeatIncoming: 10000, heartbeatOutgoing: 10000 });
    const state = { client, closedAt: null };
    client.onConnect = () => resolve(state);
    client.onWebSocketClose = () => { state.closedAt ??= Date.now(); };
    client.onStompError = (f) => reject(new Error(f.headers.message));
    client.activate();
    setTimeout(() => reject(new Error(`sin conexión a ${ip}`)), 8000);
  });
}

// 1. La víctima inicia sesión y renueva una vez (su cookie rota); el atacante se quedó con la anterior.
const login = await microsoftLogin('david.cajamarca@nexura.co');
const victim = await refresh(login.refresh);
check('la víctima renueva su sesión', victim.status === 200);
const access = victim.body.accessToken;
const sockets = await Promise.all(replicas.realtime.map((ip) => connect(ip, access)));
check(`STOMP conectado en ${sockets.length} réplicas del gateway`, sockets.length >= 2);
const before = await Promise.all(probes.map((p) => statusOf(p.url, access)));
check('el access token funciona en todas las réplicas antes del robo', before.every((s) => s === 200), JSON.stringify(before));

// 2. El atacante reutiliza la cookie ya usada.
const reusedAt = Date.now();
const attacker = await refresh(login.refresh);
check('reutilizar el refresh token se rechaza (401)', attacker.status === 401);

// 3. En < 1 s el acceso cae en todas las réplicas (REST y STOMP).
let restDownAt = null;
while (Date.now() - reusedAt < 3000) {
  const statuses = await Promise.all(probes.map((p) => statusOf(p.url, access)));
  if (statuses.every((s) => s === 401)) { restDownAt = Date.now(); break; }
  await sleep(25);
}
await sleep(300);
check('REST: 401 en las 6 réplicas', restDownAt !== null, restDownAt ? `(${restDownAt - reusedAt} ms)` : '');
check('REST: en < 1 s', restDownAt !== null && restDownAt - reusedAt < 1000);
const stompClosed = sockets.map((s) => s.closedAt);
check('STOMP: conexiones cerradas en todas las réplicas', stompClosed.every((t) => t !== null),
  `(${stompClosed.map((t) => (t ? t - reusedAt : '—')).join(' / ')} ms)`);
check('STOMP: en < 1 s', stompClosed.every((t) => t !== null && t - reusedAt < 1000));
const legit = await refresh(victim.refresh);
check('la sesión completa quedó revocada (la cookie legítima tampoco sirve)', legit.status === 401);
sockets.forEach((s) => s.client.deactivate());

// 4. Auditoría.
console.log(`AUDIT_SINCE=${new Date(reusedAt - 2000).toISOString()}`);
finish();
