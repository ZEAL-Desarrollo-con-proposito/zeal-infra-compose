// Reto C-1: 500 postulaciones simultáneas a una convocatoria de 10 cupos.
// Criterio: exactamente 10 ACEPTADA, 490 EN_ESPERA (puestos 1..490 sin repetir) y occupied = 10 en BD.
import { burst, call, token, verdict } from './lib.mjs';

const APPLICANTS = Number(process.env.APPLICANTS ?? 500);
const CAPACITY = 10;
const admin = token('usr-admin-001', 'ADMIN');

const project = await call('POST', '/api/admin/proyectos', admin, {
  title: `Carga C-1 ${Date.now()}`, area: 'Plataforma', cohort: 'Sustentación',
  summary: 'Diez cupos para quinientas personas.', description: ['Convocatoria creada por la prueba de carga C-1.'],
  requirements: [], skills: [], capacity: CAPACITY, closesAt: new Date(Date.now() + 864e5).toISOString(),
});
if (project.status !== 201) throw new Error(`No se pudo crear la convocatoria: ${JSON.stringify(project.body)}`);

const { responses, byStatus, millis } = await burst(Array.from({ length: APPLICANTS }, (_, i) =>
  () => call('POST', `/api/proyectos/${project.body.id}/postulaciones`, token(`carga-c1-${Date.now()}-${i}`, 'EMPLEADO'))));

const accepted = responses.filter((r) => r.body?.status === 'ACEPTADA').length;
const positions = responses.filter((r) => r.body?.status === 'EN_ESPERA').map((r) => r.body.waitlistPosition);
const detail = await call('GET', `/api/proyectos/${project.body.id}`, token('usr-empleado-001', 'EMPLEADO'));

verdict(`C-1 · ${APPLICANTS} postulaciones simultáneas en ${millis} ms`, [
  ['todas respondieron 201', byStatus[201] === APPLICANTS, JSON.stringify(byStatus)],
  [`exactamente ${CAPACITY} ACEPTADA`, accepted === CAPACITY, `(${accepted})`],
  ['lista de espera sin puestos repetidos', new Set(positions).size === APPLICANTS - CAPACITY && Math.max(...positions) === APPLICANTS - CAPACITY],
  [`occupied en BD = ${CAPACITY}`, detail.body.occupied === CAPACITY, `(occupied=${detail.body.occupied})`],
]);
