// R2-11 · SEG-2 de punta a punta por NGINX: login con el proveedor OIDC de prueba.
import { check, EDGE, finish, microsoftLogin, refresh } from './lib.mjs';

const ok = await microsoftLogin('david.cajamarca@nexura.co', { remember: true, returnTo: '/empleado/mis-citas' });
check('cuenta registrada entra y vuelve a su ruta', ok.status === 302 && ok.location.endsWith('/empleado/mis-citas'), ok.location);
check('cookie de renovación httpOnly, Secure, SameSite=Strict, Path=/api/auth',
  /HttpOnly/i.test(ok.setCookie) && /Secure/i.test(ok.setCookie) && /SameSite=Strict/i.test(ok.setCookie) && /Path=\/api\/auth/.test(ok.setCookie));
check('callback ≤ 1 s', ok.millis <= 1000, `(${ok.millis} ms)`);
const session = await refresh(ok.refresh);
check('refresh entrega access token de 15 min', session.status === 200 && session.body.expiresIn === 900);
const me = await fetch(`${EDGE}/api/wellbeing/reservas/mias`, { headers: { Authorization: `Bearer ${session.body.accessToken}` } });
check('el access token sirve en la API', me.status === 200);

const stranger = await microsoftLogin('intruso@otra-empresa.co');
check('cuenta no registrada → /login?error=cuenta_no_registrada', stranger.location?.endsWith('/login?error=cuenta_no_registrada') && !stranger.refresh);

const external = await fetch(`${EDGE}/api/auth/microsoft`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ returnTo: 'https://evil.example' }),
});
check('ruta de regreso externa rechazada', external.status === 400);
const legacy = await fetch(`${EDGE}/api/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
check('POST /api/auth/login retirado', legacy.status >= 400 && legacy.status < 500, `(${legacy.status})`);
finish();
