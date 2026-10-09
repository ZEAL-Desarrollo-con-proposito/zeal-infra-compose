// Utilidades de las pruebas de carga (Node 20+, sin dependencias).
import { createHmac } from 'node:crypto';

export const BASE = process.env.ZEAL_API ?? 'http://localhost:8080';
const SECRET = process.env.JWT_SECRET ?? 'ZealMVP2026ArchitectureSoftwareSecretKeyMinimum256Bits!!';

const b64url = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');

/**
 * Firma un JWT igual al del login (solo con el secreto de DESARROLLO). Permite simular cientos de
 * personas distintas: con los 4 usuarios semilla una prueba de 500 postulaciones sería idempotente.
 */
export function token(sub, role, organization = 'Nexura S.A.S.', fullName = `Persona ${sub}`) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url({ alg: 'HS256', typ: 'JWT' });
  const body = b64url({ iss: 'zeal', sub, role, fullName, email: `${sub}@carga.zeal.co`, organization, iat: now, exp: now + 3600 });
  const signature = createHmac('sha256', SECRET).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${signature}`;
}

export async function call(method, path, bearer, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { Accept: 'application/json', Authorization: `Bearer ${bearer}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

/** Dispara todas las peticiones a la vez y cuenta respuestas por código HTTP. */
export async function burst(requests) {
  const started = Date.now();
  const responses = await Promise.all(requests.map((send) => send().catch((error) => ({ status: 'ERR', error }))));
  const byStatus = {};
  for (const { status } of responses) byStatus[status] = (byStatus[status] ?? 0) + 1;
  return { responses, byStatus, millis: Date.now() - started };
}

export function verdict(name, checks) {
  console.log(`\n== ${name}`);
  let ok = true;
  for (const [label, passed, detail = ''] of checks) {
    console.log(`${passed ? 'OK  ' : 'FAIL'} ${label} ${detail}`);
    ok &&= passed;
  }
  console.log(ok ? 'RESULTADO: APROBADO' : 'RESULTADO: FALLIDO');
  process.exitCode = ok ? 0 : 1;
}

/** Instante a las `hour`:00 (hora de Bogotá, UTC-5) dentro de `days` días. */
export function bogotaAt(days, hour, minute = 0) {
  const date = new Date(Date.now() + days * 864e5);
  const day = new Date(date.getTime() - 5 * 3600e3).toISOString().slice(0, 10);
  return new Date(`${day}T${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}:00-05:00`);
}
