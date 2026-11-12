// Utilidades de las pruebas de seguridad de punta a punta (Node 20+). Usan el login REAL de ZEAL con el
// proveedor OIDC de prueba de docker-compose.yml (mock-oauth2-server en http://localhost:8090).
export const EDGE = process.env.ZEAL_API ?? 'http://localhost:8080';

const setCookies = (res) => res.headers.getSetCookie?.() ?? [];
export const cookieValue = (res, name) => {
  const raw = setCookies(res).find((c) => c.startsWith(`${name}=`));
  return raw ? raw.split(';')[0].slice(name.length + 1) : null;
};

/** Login completo: POST /api/auth/microsoft → página del proveedor → callback. Devuelve la cookie de renovación. */
export async function microsoftLogin(email, { remember = false, returnTo = '/' } = {}) {
  const start = await fetch(`${EDGE}/api/auth/microsoft`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ remember, returnTo }),
  });
  if (start.status !== 200) throw new Error(`POST /api/auth/microsoft → ${start.status}`);
  const flow = cookieValue(start, 'zeal_oidc');
  const { authorizationUrl } = await start.json();
  // El "navegador" inicia sesión en el proveedor de prueba con el correo de la cuenta.
  const provider = await fetch(authorizationUrl, {
    method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ username: email, claims: JSON.stringify({ email }) }),
  });
  const callback = provider.headers.get('location');
  const started = Date.now();
  const back = await fetch(callback, { redirect: 'manual', headers: { Cookie: `zeal_oidc=${flow}` } });
  return { status: back.status, location: back.headers.get('location'), refresh: cookieValue(back, 'zeal_refresh'),
    millis: Date.now() - started, setCookie: setCookies(back).find((c) => c.startsWith('zeal_refresh=')) };
}

export async function refresh(refreshToken) {
  const res = await fetch(`${EDGE}/api/auth/refresh`, { method: 'POST', headers: { Cookie: `zeal_refresh=${refreshToken}` } });
  return { status: res.status, body: res.status === 200 ? await res.json() : null, refresh: cookieValue(res, 'zeal_refresh') };
}

export const results = [];
export const check = (name, ok, extra = '') => { results.push(ok); console.log(`${ok ? 'OK  ' : 'FAIL'} ${name} ${extra}`); };
export const finish = () => {
  const failed = results.filter((ok) => !ok).length;
  console.log(`\n${results.length - failed}/${results.length} verificaciones · ${failed ? 'RESULTADO: FALLIDO' : 'RESULTADO: APROBADO'}`);
  process.exit(failed ? 1 : 0);
};
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
