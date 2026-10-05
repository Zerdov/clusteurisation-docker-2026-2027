'use strict';
const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs');
const { Pool } = require('pg');
const { createClient } = require('redis');
const amqp = require('amqplib');

const PORT = Number(process.env.PORT || 3000);
const VERSION = process.env.APP_VERSION || 'dev';
const COMPTES = process.env.COMPTES_URL || 'http://comptes:3000';
const FILE_EVT = 'publications';

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

let cache = null, canal = null;

const json = (res, code, body) => {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
};
const corps = async (req) => {
  const c = []; for await (const x of req) c.push(x);
  return c.length ? JSON.parse(Buffer.concat(c).toString()) : {};
};
const reessayer = async (nom, fn, n = 30) => {
  for (let i = 1; i <= n; i++) {
    try { const r = await fn(); console.log(`[${nom}] ok (essai ${i})`); return r; }
    catch (e) { console.warn(`[${nom}] indisponible ${i}/${n}: ${e.message}`); await new Promise(r => setTimeout(r, 2000)); }
  }
  throw new Error(`${nom} injoignable`);
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (req.method === 'GET' && url.pathname === '/health')
      return json(res, 200, { service: 'publications', version: VERSION, host: os.hostname() });

    if (req.method === 'GET' && url.pathname === '/fil') {
      // Cache de lecture : c'est ce qui justifie la brique Redis.
      const cle = 'fil:20';
      const vu = await cache.get(cle).catch(() => null);
      if (vu) return json(res, 200, { source: 'cache', items: JSON.parse(vu) });
      const { rows } = await pool.query(
        'SELECT id, auteur_id, titre, cree_le FROM publications ORDER BY id DESC LIMIT 20');
      await cache.setEx(cle, 30, JSON.stringify(rows)).catch(() => {});
      return json(res, 200, { source: 'db', items: rows });
    }

    if (req.method === 'POST' && url.pathname === '/publications') {
      const { auteur_id, titre } = await corps(req);
      if (!auteur_id || !titre) return json(res, 400, { error: 'auteur_id et titre requis' });

      // Flux inter-services : on verifie l'auteur aupres de comptes.
      const r = await fetch(`${COMPTES}/comptes/${auteur_id}`).catch(() => null);
      if (!r || !r.ok) return json(res, 400, { error: 'auteur inconnu' });

      const { rows } = await pool.query(
        'INSERT INTO publications (auteur_id, titre) VALUES ($1,$2) RETURNING id, auteur_id, titre, cree_le',
        [auteur_id, titre]);

      // Traitement asynchrone : on publie un evenement et on repond tout de
      // suite. Le worker fera le travail long de son cote.
      canal.sendToQueue(FILE_EVT, Buffer.from(JSON.stringify({
        publication_id: rows[0].id, auteur_id, horodatage: new Date().toISOString(),
      })), { persistent: true });

      await cache.del('fil:20').catch(() => {});
      return json(res, 201, rows[0]);
    }
    return json(res, 404, { error: 'not found' });
  } catch (e) { console.error('[publications]', e.message); return json(res, 500, { error: e.message }); }
});

(async () => {
  await reessayer('db', () => pool.query('SELECT 1'));
  cache = createClient({ url: process.env.REDIS_URL || 'redis://cache:6379' });
  cache.on('error', (e) => console.error('[cache]', e.message));
  await reessayer('cache', () => cache.connect());
  const conn = await reessayer('bus', () => amqp.connect(process.env.AMQP_URL || 'amqp://bus:5672'));
  canal = await conn.createChannel();
  await canal.assertQueue(FILE_EVT, { durable: true });
  server.listen(PORT, '0.0.0.0', () => console.log(`[publications] v${VERSION} :${PORT} host=${os.hostname()}`));
})().catch((e) => { console.error(e.message); process.exit(1); });

for (const s of ['SIGTERM', 'SIGINT'])
  process.on(s, () => { server.close(() => process.exit(0)); setTimeout(() => process.exit(1), 8000).unref(); });
