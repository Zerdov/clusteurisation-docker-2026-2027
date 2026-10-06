'use strict';
// Huitieme service, ajoute pendant la soutenance. Volontairement minimal :
// aucune dependance, aucune base. Il montre qu'un service nouveau se branche sur le cluster
// sans toucher ni a l'edge ni a la stack Nebula.
const http = require('node:http');
const os = require('node:os');

const PORT = Number(process.env.PORT || 3000);
const VERSION = process.env.APP_VERSION || 'dev';
const demarrage = Date.now();

const json = (res, code, body) => {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (req.method === 'GET' && url.pathname === '/health')
    return json(res, 200, { service: 'statut', version: VERSION, host: os.hostname() });
  if (req.method === 'GET' && url.pathname === '/statut')
    return json(res, 200, {
      service: 'statut', version: VERSION, host: os.hostname(),
      uptime_s: Math.round((Date.now() - demarrage) / 1000),
    });
  return json(res, 404, { error: 'not found' });
});

server.listen(PORT, '0.0.0.0', () => console.log(`[statut] v${VERSION} :${PORT} host=${os.hostname()}`));
for (const s of ['SIGTERM', 'SIGINT'])
  process.on(s, () => server.close(() => process.exit(0)));
