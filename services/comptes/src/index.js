'use strict';
const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs');
const { Pool } = require('pg');

const PORT = Number(process.env.PORT || 3000);
const VERSION = process.env.APP_VERSION || 'dev';

// Convention des images officielles : <VAR>_FILE a la priorite sur <VAR>.
// C'est ainsi qu'un secret Swarm, monte en fichier, arrive dans l'appli.
const lire = (n, d) => {
  const f = process.env[`${n}_FILE`];
  return f ? fs.readFileSync(f, 'utf8').trim() : (process.env[n] ?? d);
};

const pool = new Pool({
  host: process.env.PGHOST || 'db',
  user: lire('POSTGRES_USER', 'nebula'),
  password: lire('POSTGRES_PASSWORD', 'nebula'),
  database: process.env.POSTGRES_DB || 'nebula',
  max: 5, connectionTimeoutMillis: 3000,
});
pool.on('error', (e) => console.error('[db]', e.message));

const json = (res, code, body) => {
  const p = JSON.stringify(body);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' });
  res.end(p);
};
const corps = async (req) => {
  const c = []; let n = 0;
  for await (const x of req) { n += x.length; if (n > 8192) throw new Error('corps trop gros'); c.push(x); }
  return c.length ? JSON.parse(Buffer.concat(c).toString()) : {};
};

// En systeme distribue, l'appli RETENTE : ni depends_on ni Swarm ne
// garantissent que la base accepte deja les connexions.
async function attendreDb(n = 30) {
  for (let i = 1; i <= n; i++) {
    try { await pool.query('SELECT 1'); console.log(`[db] ok (essai ${i})`); return; }
    catch (e) { console.warn(`[db] indisponible ${i}/${n}: ${e.message}`); await new Promise(r => setTimeout(r, 2000)); }
  }
  throw new Error('base injoignable');
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (req.method === 'GET' && url.pathname === '/health')
      return json(res, 200, { service: 'comptes', version: VERSION, host: os.hostname() });

    if (req.method === 'POST' && url.pathname === '/comptes') {
      const { pseudo } = await corps(req);
      if (!pseudo) return json(res, 400, { error: 'pseudo requis' });
      const { rows } = await pool.query(
        'INSERT INTO comptes (pseudo) VALUES ($1) RETURNING id, pseudo, cree_le', [pseudo]);
      return json(res, 201, rows[0]);
    }

    const m = url.pathname.match(/^\/comptes\/(\d+)$/);
    if (req.method === 'GET' && m) {
      const { rows } = await pool.query('SELECT id, pseudo, cree_le FROM comptes WHERE id=$1', [m[1]]);
      return rows[0] ? json(res, 200, rows[0]) : json(res, 404, { error: 'inconnu' });
    }
    return json(res, 404, { error: 'not found' });
  } catch (e) { console.error('[comptes]', e.message); return json(res, 500, { error: e.message }); }
});

attendreDb()
  .then(() => server.listen(PORT, '0.0.0.0', () => console.log(`[comptes] v${VERSION} :${PORT} host=${os.hostname()}`)))
  .catch((e) => { console.error(e.message); process.exit(1); });

for (const s of ['SIGTERM', 'SIGINT'])
  process.on(s, () => { server.close(() => pool.end().finally(() => process.exit(0))); setTimeout(() => process.exit(1), 8000).unref(); });
