import { Client } from '@stomp/stompjs';
import SockJS from 'sockjs-client';

// Verificación de punta a punta de RT-1, RT-2 y RT-3 con el mismo cliente STOMP/SockJS del frontend.
const WB = process.env.WELLBEING_URL ?? 'http://localhost:8081';
const MP = process.env.MARKETPLACE_URL ?? 'http://localhost:8082';
const RT = process.env.REALTIME_URL ?? 'http://localhost:8083';
const results = [];
const check = (name, ok, extra = '') => { results.push(ok); console.log(`${ok ? 'OK  ' : 'FAIL'} ${name} ${extra}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function http(method, url, token, body) {
  const res = await fetch(url, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}
const login = async (email) => (await http('POST', `${WB}/api/auth/login`, null, { email, password: 'Zeal2026*' })).body;

function connect(token) {
  return new Promise((resolve, reject) => {
    const inbox = [];
    const client = new Client({ webSocketFactory: () => new SockJS(`${RT}/ws`), connectHeaders: { Authorization: `Bearer ${token}` }, reconnectDelay: 0 });
    client.onConnect = () => resolve({ client, inbox, sub: (d) => client.subscribe(d, (m) => inbox.push({ d, at: Date.now(), body: JSON.parse(m.body) })) });
    client.onStompError = (f) => reject(new Error(f.headers.message));
    client.activate();
  });
}
const waitFor = async (inbox, pred, ms = 4000) => { const end = Date.now() + ms; while (Date.now() < end) { const hit = inbox.find(pred); if (hit) return hit; await sleep(20); } return null; };

const david = await login('david.cajamarca@nexura.co'), laura = await login('laura.martinez@zeal.co');
const mariana = await login('mariana.torres@nexura.co'), admin = await login('talento.humano@nexura.co');
const D = await connect(david.accessToken), L = await connect(laura.accessToken), M = await connect(mariana.accessToken), A = await connect(admin.accessToken);
for (const q of ['notificaciones', 'salas', 'chats', 'postulaciones']) D.sub(`/user/queue/${q}`);
for (const q of ['salas', 'chats']) { L.sub(`/user/queue/${q}`); M.sub(`/user/queue/${q}`); }
L.sub('/topic/franjas'); M.sub('/topic/presencia/usr-psicologo-001'); A.sub('/user/queue/proyectos');
D.sub('/topic/organizaciones/Nexura%20S.A.S./proyectos');
await sleep(400);

// RT-2: reserva → notificación privada + broadcast de franjas
const today = new Date().toISOString().slice(0, 10), later = new Date(Date.now() + 9 * 864e5).toISOString().slice(0, 10);
const slots = (await http('GET', `${WB}/api/wellbeing/psicologos/usr-psicologo-002/franjas?desde=${today}&hasta=${later}`, david.accessToken)).body;
const free = slots.find((s) => s.status === 'DISPONIBLE');
const booked = await http('POST', `${WB}/api/wellbeing/reservas`, david.accessToken, { slotId: free.id });
check('reserva 201', booked.status === 201);
check('RT-2 notificación privada a David', !!(await waitFor(D.inbox, (m) => m.d.endsWith('notificaciones') && m.body.type === 'NUEVA')));
check('RT-2 /topic/franjas ACTUALIZADA', !!(await waitFor(L.inbox, (m) => m.d === '/topic/franjas' && m.body.slot?.id === free.id && m.body.slot.status === 'RESERVADA')));

// RT-3: sala activa → señal solo al otro participante
const appts = (await http('GET', `${WB}/api/wellbeing/reservas/mias`, david.accessToken)).body;
const live = appts.find((a) => Date.parse(a.startsAt) - Date.now() < 10 * 60e3 && Date.parse(a.endsAt) > Date.now());
const activated = await http('POST', `${WB}/api/wellbeing/reservas/${live.id}/sala/activar`, laura.accessToken);
check('sala ACTIVA', activated.body?.status === 'ACTIVA', activated.body?.message ?? '');
await sleep(200);
D.client.publish({ destination: `/app/salas/${live.id}/senales`, body: JSON.stringify({ type: 'OFERTA', id: 'o-1', sdp: 'v=0' }) });
check('RT-3 señal llega a Laura', !!(await waitFor(L.inbox, (m) => m.body.type === 'SENAL' && m.body.signal.sdp === 'v=0')));
await sleep(300);
check('RT-3 Mariana no recibe la señal', !M.inbox.some((m) => m.body.type === 'SENAL'));

// RT-1: chat < 500 ms y "escribiendo"
const cid = 'usr-empleado-001:usr-psicologo-001';
const sentAt = Date.now();
D.client.publish({ destination: `/app/chats/${encodeURIComponent(cid)}/mensajes`, body: JSON.stringify({ text: `E2E-${sentAt}` }) });
const got = await waitFor(L.inbox, (m) => m.body.type === 'NUEVO' && m.body.message.text === `E2E-${sentAt}`);
check('RT-1 chat entregado a Laura', !!got, got ? `(${got.at - sentAt} ms)` : '');
check('RT-1 latencia < 500 ms', !!got && got.at - sentAt < 500);
check('RT-1 eco a David', !!(await waitFor(D.inbox, (m) => m.body.type === 'NUEVO')));
L.client.publish({ destination: `/app/chats/${encodeURIComponent(cid)}/escribiendo`, body: JSON.stringify({ typing: true }) });
check('escribiendo → David', !!(await waitFor(D.inbox, (m) => m.body.type === 'ESCRIBIENDO' && m.body.userId === 'usr-psicologo-001')));
const history = await http('GET', `${WB}/api/chats/${encodeURIComponent(cid)}/mensajes`, laura.accessToken);
check('historial persistido', history.body.some((m) => m.text === `E2E-${sentAt}`));

// Presencia
check('presencia de Laura online', (await http('GET', `${RT}/api/presencia/usr-psicologo-001`, mariana.accessToken)).body.status === 'online');
L.client.deactivate();
check('presencia offline al desconectar', !!(await waitFor(M.inbox, (m) => m.d.startsWith('/topic/presencia') && m.body.status === 'offline')));

// Notificaciones REST
const notes = await http('GET', `${RT}/api/notificaciones`, david.accessToken);
check('GET /api/notificaciones', notes.status === 200 && notes.body.length > 0);
const readAll = await http('POST', `${RT}/api/notificaciones/leidas`, david.accessToken);
check('marcar todas leídas 204 + LEIDAS', readAll.status === 204 && !!(await waitFor(D.inbox, (m) => m.body.type === 'LEIDAS')));

// Marketplace: publicación y cupos en vivo
const project = await http('POST', `${MP}/api/admin/proyectos`, admin.accessToken, { title: `Convocatoria E2E ${Date.now()}`, area: 'Datos', cohort: 'Demo', summary: 'Prueba de punta a punta.', description: ['Descripción suficientemente larga para validar.'], requirements: [], skills: [], capacity: 2, closesAt: new Date(Date.now() + 864e5).toISOString() });
check('publicar proyecto 201', project.status === 201);
check('admin recibe PUBLICADO', !!(await waitFor(A.inbox, (m) => m.body.type === 'PUBLICADO' && m.body.project.id === project.body.id)));
check('catálogo de la empresa recibe PUBLICADO', !!(await waitFor(D.inbox, (m) => m.d.includes('organizaciones') && m.body.project.id === project.body.id)));
D.sub(`/topic/proyectos/${encodeURIComponent(project.body.id)}/cupos`); await sleep(200);
const app = await http('POST', `${MP}/api/proyectos/${project.body.id}/postulaciones`, david.accessToken);
check('postulación ACEPTADA', app.status === 201 && app.body.status === 'ACEPTADA');
check('cupos en vivo', !!(await waitFor(D.inbox, (m) => m.body.type === 'CUPOS' && m.body.occupied === 1)));
check('resultado en cola privada', !!(await waitFor(D.inbox, (m) => m.body.type === 'POSTULACION')));

// Privacidad
try { await connect('token-falso'); check('CONNECT con token falso rechazado', false); } catch { check('CONNECT con token falso rechazado', true); }

console.log(`\n${results.filter(Boolean).length}/${results.length} verificaciones OK`);
[D, M, A].forEach((c) => c.client.deactivate());
setTimeout(() => process.exit(results.every(Boolean) ? 0 : 1), 300);
