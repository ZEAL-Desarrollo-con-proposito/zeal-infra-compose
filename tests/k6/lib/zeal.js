// Utilidades compartidas de las pruebas k6 de ZEAL.
//
// Autenticación de carga (R2-25): k6 firma access tokens de ZEAL con el secreto HS256 del entorno
// (JWT_SECRET). Solo funciona donde ese secreto es el de DESARROLLO/PRUEBAS: es el "mecanismo de token
// de prueba" del perfil de carga, no una puerta trasera (en producción el secreto es otro y nadie fuera
// del servidor lo conoce). Así se simulan cientos de personas sin pasar por Microsoft.
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';
import http from 'k6/http';

export const BASE = __ENV.ZEAL_API || 'http://localhost:8080';
const SECRET = __ENV.JWT_SECRET || 'ZealMVP2026ArchitectureSoftwareSecretKeyMinimum256Bits!!';

const b64 = (value) => encoding.b64encode(JSON.stringify(value), 'rawurl');

export function token(sub, role, organization = 'Nexura S.A.S.', ttlSeconds = 3600) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'HS256', typ: 'JWT' });
  const body = b64({
    iss: 'zeal', sub, role, fullName: `Carga ${sub}`, email: `${sub}@carga.zeal.co`, organization,
    iat: now, exp: now + ttlSeconds, jti: `k6-${sub}-${now}-${Math.random().toString(36).slice(2)}`,
  });
  const signature = crypto.hmac('sha256', SECRET, `${head}.${body}`, 'base64rawurl');
  return `${head}.${body}.${signature}`;
}

export function headers(bearer, extra = {}) {
  return { headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json', Accept: 'application/json', ...extra } };
}

export function createProject(adminToken, capacity, title) {
  const res = http.post(`${BASE}/api/admin/proyectos`, JSON.stringify({
    title, area: 'Plataforma', cohort: 'Carga', summary: 'Convocatoria creada por una prueba k6.',
    description: ['Prueba automatizada.'], requirements: [], skills: [], capacity,
    closesAt: new Date(Date.now() + 864e5).toISOString(),
  }), headers(adminToken));
  if (res.status !== 201) throw new Error(`No se pudo crear la convocatoria: ${res.status} ${res.body}`);
  return res.json();
}
