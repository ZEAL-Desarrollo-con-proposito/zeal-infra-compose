// Reto C-2: 100 empleados reservan la misma franja al mismo tiempo.
// Criterio: exactamente 1 respuesta 201 y 99 respuestas 409; la franja queda RESERVADA una sola vez.
import { bogotaAt, burst, call, token, verdict } from './lib.mjs';

const EMPLOYEES = Number(process.env.EMPLOYEES ?? 100);
const laura = token('usr-psicologo-001', 'PSICOLOGO', 'ZEAL', 'Laura Martínez');

const start = bogotaAt(20, 6, Math.floor(Math.random() * 12) * 5);
const slot = await call('POST', '/api/wellbeing/franjas', laura, {
  startsAt: start.toISOString(), endsAt: new Date(start.getTime() + 5 * 60e3).toISOString(),
});
if (slot.status !== 201) throw new Error(`No se pudo abrir la franja: ${JSON.stringify(slot.body)}`);

const { byStatus, millis } = await burst(Array.from({ length: EMPLOYEES }, (_, i) =>
  () => call('POST', '/api/wellbeing/reservas', token(`carga-c2-${Date.now()}-${i}`, 'EMPLEADO'), { slotId: slot.body.id })));

verdict(`C-2 · ${EMPLOYEES} reservas simultáneas en ${millis} ms`, [
  ['exactamente 1 reserva (201)', byStatus[201] === 1, JSON.stringify(byStatus)],
  [`${EMPLOYEES - 1} rechazos (409)`, byStatus[409] === EMPLOYEES - 1],
]);
