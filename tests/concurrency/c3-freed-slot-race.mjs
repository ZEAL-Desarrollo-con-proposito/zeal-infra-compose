// Reto C-3: se cancela una cita y 50 personas con cita posterior ese día compiten por el cupo.
// Criterio: las 50 reciben la oferta; exactamente 1 toma el cupo (200) y 49 reciben 409.
import { bogotaAt, burst, call, token, verdict } from './lib.mjs';

const CANDIDATES = Number(process.env.CANDIDATES ?? 50);
const run = Date.now();
const laura = token('usr-psicologo-001', 'PSICOLOGO', 'ZEAL', 'Laura Martínez');
const days = 21 + Math.floor(Math.random() * 30);

async function bookedSlot(startsAt, minutes, employeeToken) {
  const slot = await call('POST', '/api/wellbeing/franjas', laura, {
    startsAt: startsAt.toISOString(), endsAt: new Date(startsAt.getTime() + minutes * 60e3).toISOString(),
  });
  if (slot.status !== 201) throw new Error(`No se pudo abrir la franja: ${JSON.stringify(slot.body)}`);
  const booking = await call('POST', '/api/wellbeing/reservas', employeeToken, { slotId: slot.body.id });
  if (booking.status !== 201) throw new Error(`No se pudo reservar: ${JSON.stringify(booking.body)}`);
  return booking.body;
}

const releaser = token(`carga-c3-${run}-libera`, 'EMPLEADO');
const freed = await bookedSlot(bogotaAt(days, 6), 50, releaser);
const candidates = Array.from({ length: CANDIDATES }, (_, i) => token(`carga-c3-${run}-${i}`, 'EMPLEADO'));
const later = bogotaAt(days, 12).getTime();
for (const [i, candidate] of candidates.entries()) {
  await bookedSlot(new Date(later + i * 5 * 60e3), 5, candidate);
}

const cancelled = await call('POST', `/api/wellbeing/reservas/${freed.id}/cancelar`, releaser);
const offers = await Promise.all(candidates.map((candidate) => call('GET', '/api/wellbeing/cupos', candidate)));
const offerIds = new Set(offers.flatMap((o) => o.body.filter((offer) => offer.startsAt === freed.startsAt).map((offer) => offer.id)));
const [offerId] = offerIds;

const { byStatus, millis } = await burst(candidates.map((candidate) =>
  () => call('POST', `/api/wellbeing/cupos/${offerId}/tomar`, candidate)));

verdict(`C-3 · ${CANDIDATES} candidatos compiten en ${millis} ms`, [
  ['cancelación aceptada', cancelled.body?.status === 'CANCELADA'],
  [`los ${CANDIDATES} candidatos recibieron la misma oferta`, offerIds.size === 1 && offers.every((o) => o.body.some((x) => x.id === offerId))],
  ['exactamente 1 toma el cupo (200)', byStatus[200] === 1, JSON.stringify(byStatus)],
  [`${CANDIDATES - 1} rechazos (409)`, byStatus[409] === CANDIDATES - 1],
]);
