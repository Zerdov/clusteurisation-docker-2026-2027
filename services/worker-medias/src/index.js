'use strict';
const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs/promises');
const path = require('node:path');
const amqp = require('amqplib');

const PORT = Number(process.env.PORT || 3000);
const VERSION = process.env.APP_VERSION || 'dev';
const FILE_EVT = 'publications';
const SORTIE = process.env.SORTIE_DIR || '/data';

const reessayer = async (nom, fn, n = 30) => {
  for (let i = 1; i <= n; i++) {
    try { const r = await fn(); console.log(`[${nom}] ok (essai ${i})`); return r; }
    catch (e) {
      console.warn(`[${nom}] indisponible ${i}/${n}: ${e.message}`);
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  throw new Error(`${nom} injoignable`);
};

let traites = 0;

// Un worker n'a pas de route metier, mais il lui faut une sonde : sans elle,
// Swarm ne sait pas distinguer « demarre » de « pret ».
http.createServer((req, res) => {
  res.writeHead(req.url === '/health' ? 200 : 404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ service: 'worker-medias', version: VERSION, host: os.hostname(), traites }));
}).listen(PORT, '0.0.0.0');

(async () => {
  await fs.mkdir(SORTIE, { recursive: true });

  const conn = await reessayer('bus', () => amqp.connect(process.env.AMQP_URL || 'amqp://bus:5672'));
  const canal = await conn.createChannel();
  await canal.assertQueue(FILE_EVT, { durable: true });

  // prefetch(1) : une tache a la fois. Sans cela, un seul worker avale toute
  // la file et augmenter le nombre de replicas ne sert plus a rien.
  canal.prefetch(1);

  console.log(`[worker] v${VERSION} en ecoute sur ${FILE_EVT}, sortie ${SORTIE}, host=${os.hostname()}`);

  canal.consume(FILE_EVT, async (msg) => {
    if (!msg) return;
    try {
      const evt = JSON.parse(msg.content.toString());
      // Traitement volontairement lent : c'est ce qui rend l'asynchrone
      // visible, et ce qui justifie de pouvoir augmenter les replicas.
      await new Promise(r => setTimeout(r, 1500));
      const fichier = path.join(SORTIE, `publication-${evt.publication_id}.json`);
      await fs.writeFile(fichier, JSON.stringify({ ...evt, traite_par: os.hostname() }, null, 2));
      traites++;
      console.log(`[worker] ${fichier} ecrit (${traites} au total)`);
      canal.ack(msg);
    } catch (e) {
      console.error('[worker]', e.message);
      // requeue: false : le message part en erreur plutot que de boucler.
      canal.nack(msg, false, false);
    }
  });
})().catch((e) => { console.error(e.message); process.exit(1); });

for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => process.exit(0));
