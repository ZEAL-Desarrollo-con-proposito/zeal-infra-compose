// DT-4 (HU-DT-01): dos réplicas del Real-Time Gateway detrás de NGINX.
// David se conecta FORZADO a la réplica A y Laura a la réplica B (directo a la IP de cada
// contenedor); la administradora entra por NGINX. Se verifica que se ven en línea, chatean y
// reciben los avisos de franjas, cupos y notificaciones exactamente una vez.
// Uso: ./two-replicas.sh   (resuelve las IPs de las réplicas y ejecuta este script)
import { Client } from '@stomp/stompjs';
import SockJS from 'sockjs-client';
import { bogotaAt, call, token } from '../concurrency/lib.mjs';

const REPLICA_A = process.env.REPLICA_A_URL;
const REPLICA_B = process.env.REPLICA_B_URL;
const EDGE = process.env.ZEAL_API ?? 'http://localhost:8080';
if (!REPLICA_A || !REPLICA_B) throw new Error('Define REPLICA_A_URL y REPLICA_B_URL (usa two-replicas.sh)');

const results = [];
const check = (name, ok, extra = '') => { results.push({ name, ok, extra }); console.log(`${ok ? 'OK  ' : 'FAIL'} ${name} ${extra}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const waitFor = async (inbox, pred, ms = 5000) => { const end = Date.now() + ms; while (Date.now() < end) { const hit = inbox.find(pred); if (hit) return hit; await sleep(20); } return null; };
const count = (inbox, pred) => inbox.filter(pred).length;

function connect(base, bearer, transports) {
  return new Promise((resolve, reject) => {
    const inbox = [];
    const client = new Client({
      webSocketFactory: () => new SockJS(`${base}/ws`, null, transports ? { transports } : {}), connectHeaders: { Authorization: `Bearer ${bearer}` },
      reconnectDelay: 0, heartbeatIncoming: 10000, heartbeatOutgoing: 10000,
    });
    client.onConnect = () => resolve({ client, inbox, sub: (d) => client.subscribe(d, (m) => inbox.push({ d, at: Date.now(), body: JSON.parse(m.body) })) });
    client.onStompError = (f) => reject(new Error(f.headers.message));
    client.onWebSocketError = () => reject(new Error(`No se pudo conectar a ${base}`));
    client.activate();
    setTimeout(() => reject(new Error(`Tiempo agotado conectando a ${base}`)), 10000);
  });
}

const davidToken = token('usr-empleado-001', 'EMPLEADO', 'Nexura S.A.S.', 'David Cajamarca');
const lauraToken = token('usr-psicologo-001', 'PSICOLOGO', 'ZEAL', 'Laura Martínez');
const adminToken = token('usr-admin-001', 'ADMIN', 'Nexura S.A.S.', 'Talento Humano');

console.log(`Réplica A: ${REPLICA_A} · Réplica B: ${REPLICA_B} · Borde: ${EDGE}\n`);

// 1. Presencia entre réplicas
const L = await connect(REPLICA_B, lauraToken);
L.sub('/topic/presencia/usr-empleado-001');
for (const q of ['chats', 'salas']) L.sub(`/user/queue/${q}`);
L.sub('/topic/franjas');
await sleep(400);
const D = await connect(REPLICA_A, davidToken);
for (const q of ['chats', 'notificaciones']) D.sub(`/user/queue/${q}`);
D.sub('/topic/organizaciones/Nexura%20S.A.S./proyectos');
const A = await connect(EDGE, adminToken);
A.sub('/user/queue/proyectos');
check('David (réplica A) aparece en línea para Laura (réplica B)',
  !!(await waitFor(L.inbox, (m) => m.d.startsWith('/topic/presencia') && m.body.status === 'online')));
const presence = await call('GET', '/api/presencia/usr-empleado-001', lauraToken);
check('GET /api/presencia por NGINX lo reporta online', presence.body?.status === 'online', JSON.stringify(presence.body));

// 2. Chat entre réplicas (RT-1)
const cid = 'usr-empleado-001:usr-psicologo-001';
const text = `DT-4-${Date.now()}`;
const sentAt = Date.now();
D.client.publish({ destination: `/app/chats/${encodeURIComponent(cid)}/mensajes`, body: JSON.stringify({ text }) });
const got = await waitFor(L.inbox, (m) => m.body.type === 'NUEVO' && m.body.message?.text === text);
check('chat de David (A) llega a Laura (B)', !!got, got ? `(${got.at - sentAt} ms)` : '');
check('eco del chat en la pestaña de David (A)', !!(await waitFor(D.inbox, (m) => m.body.type === 'NUEVO' && m.body.message?.text === text)));
L.client.publish({ destination: `/app/chats/${encodeURIComponent(cid)}/escribiendo`, body: JSON.stringify({ typing: true }) });
check('"escribiendo" de Laura (B) llega a David (A)', !!(await waitFor(D.inbox, (m) => m.body.type === 'ESCRIBIENDO')));

// 3. Franjas y notificación privada: Laura abre una franja y David la reserva, ambos por NGINX
// Hora fuera de las franjas sembradas (07:00-17:00) y día lejano, con reintento si choca con otra franja de Laura.
let slot;
for (let attempt = 0; attempt < 8; attempt += 1) {
  const start = bogotaAt(40 + Math.floor(Math.random() * 300), 19 + Math.floor(Math.random() * 3), Math.floor(Math.random() * 12) * 5);
  slot = await call('POST', '/api/wellbeing/franjas', lauraToken,
    { startsAt: start.toISOString(), endsAt: new Date(start.getTime() + 50 * 60e3).toISOString() });
  if (slot.status === 201) break;
}
check('franja creada por NGINX', slot.status === 201, `(${slot.status})`);
if (slot.status === 201) {
  const booked = await call('POST', '/api/wellbeing/reservas', davidToken, { slotId: slot.body.id });
  check('reserva por NGINX 201', booked.status === 201, `(${booked.status})`);
  check('Laura (B) recibe /topic/franjas', !!(await waitFor(L.inbox, (m) => m.d === '/topic/franjas' && m.body.slot?.id === slot.body.id && m.body.slot.status === 'RESERVADA')));
  check('David (A) recibe su notificación privada', !!(await waitFor(D.inbox, (m) => m.d.endsWith('notificaciones') && m.body.type === 'NUEVA')));
}

// 4. Cupos: la administradora (por NGINX) publica y alguien se postula. Mariana entra por NGINX con
// xhr-polling (transporte de respaldo de SockJS: muchas peticiones HTTP por sesión). Sin afinidad,
// NGINX las repartiría entre réplicas y la sesión se rompería.
const M = await connect(EDGE, token('usr-empleado-002', 'EMPLEADO', 'Nexura S.A.S.', 'Mariana Torres'), ['xhr-polling']);
M.sub('/topic/organizaciones/Nexura%20S.A.S./proyectos');
await sleep(600);
const project = await call('POST', '/api/admin/proyectos', adminToken, {
  title: `DT-4 ${Date.now()}`, area: 'Plataforma', cohort: 'Réplicas', summary: 'Prueba de dos réplicas.',
  description: ['Creada por tests/realtime/two-replicas.mjs.'], requirements: [], skills: [], capacity: 3,
  closesAt: new Date(Date.now() + 864e5).toISOString(),
});
check('convocatoria creada por NGINX', project.status === 201, `(${project.status})`);
check('David (A) ve la convocatoria nueva de su empresa', !!(await waitFor(D.inbox, (m) => m.d.includes('/organizaciones/') && m.body.type === 'PUBLICADO')));
check('la administradora recibe su panel', !!(await waitFor(A.inbox, (m) => m.body.type === 'PUBLICADO')));
check('Mariana (xhr-polling por NGINX, con afinidad) recibe la convocatoria', !!(await waitFor(M.inbox, (m) => m.body.type === 'PUBLICADO')));
const spotsTopic = `/topic/proyectos/${encodeURIComponent(project.body.id)}/cupos`;
D.sub(spotsTopic); L.sub(spotsTopic);
await sleep(400);
const applied = await call('POST', `/api/proyectos/${project.body.id}/postulaciones`, token(`dt4-${Date.now()}`, 'EMPLEADO'));
check('postulación 201', applied.status === 201, `(${applied.status})`);
check('cupos en vivo en la réplica A', !!(await waitFor(D.inbox, (m) => m.d === spotsTopic && m.body.type === 'CUPOS')));
check('cupos en vivo en la réplica B', !!(await waitFor(L.inbox, (m) => m.d === spotsTopic && m.body.type === 'CUPOS')));

// 5. Sin duplicados: cada evento lo procesa una sola réplica
await sleep(1500);
check('sin duplicados en tópicos (A)', count(D.inbox, (m) => m.d === spotsTopic) === 1 && count(D.inbox, (m) => m.body.type === 'PUBLICADO') === 1);
check('sin duplicados en tópicos (B)', count(L.inbox, (m) => m.d === spotsTopic) === 1);
check('sin duplicados en colas privadas', count(L.inbox, (m) => m.body.message?.text === text) === 1 && count(A.inbox, (m) => m.body.type === 'PUBLICADO') === 1);

// 5b. REND-1 / OBS: todo mensaje STOMP trae emittedAt (ISO-8601 UTC) reciente, para medir la latencia en el front
const everything = [...D.inbox, ...L.inbox, ...A.inbox, ...M.inbox].filter((m) => m.body.type !== 'PRESENCIA' || true);
const stamped = everything.filter((m) => typeof m.body.emittedAt === 'string' && /Z$/.test(m.body.emittedAt)
  && Math.abs(Date.now() - Date.parse(m.body.emittedAt)) < 120000);
check(`todos los mensajes STOMP traen emittedAt (${stamped.length}/${everything.length})`, everything.length > 0 && stamped.length === everything.length);

// 6. Desconexión
D.client.deactivate();
check('David desconectado → Laura (B) lo ve offline', !!(await waitFor(L.inbox, (m) => m.d.startsWith('/topic/presencia') && m.body.status === 'offline')));

L.client.deactivate(); A.client.deactivate(); M.client.deactivate();
const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} verificaciones · ${failed ? 'RESULTADO: FALLIDO' : 'RESULTADO: APROBADO'}`);
process.exit(failed ? 1 : 0);
