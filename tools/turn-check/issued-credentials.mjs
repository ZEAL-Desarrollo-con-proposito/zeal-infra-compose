// Obtiene las credenciales TURN que wellbeing emite de verdad para una cita (DT-6): Laura abre una
// franja que ya empezó, David la reserva... no se puede reservar en el pasado, así que se usa una
// franja futura: la vista de la sala ya incluye los iceServers con credenciales temporales.
// Imprime "usuario credencial" para turn-check.sh. Solo con el secreto JWT de DESARROLLO.
import { bogotaAt, call, token } from '../../tests/concurrency/lib.mjs';

const laura = token('usr-psicologo-001', 'PSICOLOGO', 'ZEAL', 'Laura Martínez');
const david = token('usr-empleado-001', 'EMPLEADO', 'Nexura S.A.S.', 'David Cajamarca');
const start = bogotaAt(30 + Math.floor(Math.random() * 30), 7 + Math.floor(Math.random() * 10), Math.floor(Math.random() * 12) * 5);
const slot = await call('POST', '/api/wellbeing/franjas', laura,
  { startsAt: start.toISOString(), endsAt: new Date(start.getTime() + 50 * 60e3).toISOString() });
if (slot.status !== 201) throw new Error(`No se pudo abrir la franja: ${slot.status} ${JSON.stringify(slot.body)}`);
const booked = await call('POST', '/api/wellbeing/reservas', david, { slotId: slot.body.id });
if (booked.status !== 201) throw new Error(`No se pudo reservar: ${booked.status}`);
const room = await call('GET', `/api/wellbeing/reservas/${booked.body.id}/sala`, david);
const turn = (room.body.iceServers ?? []).find((s) => s.urls.startsWith('turn:'));
await call('PATCH', `/api/wellbeing/reservas/${booked.body.id}/cancelar`, david).catch(() => {});
if (!turn) throw new Error('La sala no trae servidor TURN: revisa TURN_URLS y TURN_SECRET en wellbeing');
console.log(`${turn.username} ${turn.credential}`);
