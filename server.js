// Demo app for Kube-DC tutorials: a page that shows whether a managed PostgreSQL is attached.
const http = require('http');
const { Client } = require('pg');
const port = process.env.PORT || 8080;
async function dbLine() {
  const url = process.env.DATABASE_URL || process.env.DB_URI;
  const cfg = url ? { connectionString: url.replace(/[?&]sslmode=[^&]*/g, '').replace(/[?&]sslrootcert=[^&]*/g, '') } : (process.env.PGHOST || process.env.host) ? {
    host: process.env.PGHOST || process.env.host, port: +(process.env.PGPORT || process.env.port || 5432),
    user: process.env.PGUSER || process.env.username || process.env.user, password: process.env.PGPASSWORD || process.env.password,
    database: process.env.PGDATABASE || process.env.dbname || process.env.database || 'app' } : null;
  if (!cfg) return 'No database attached yet.';
  cfg.ssl = { rejectUnauthorized: false };
  const c = new Client(cfg);
  try { await c.connect(); const r = await c.query('select version()'); return 'Connected: ' + r.rows[0].version.split(' on ')[0]; }
  catch (e) { return 'Database error: ' + e.message; } finally { c.end().catch(() => {}); }
}
http.createServer(async (req, res) => {
  if (req.url === '/healthz') { res.end('ok'); return; }
  const db = await dbLine();
  res.setHeader('content-type', 'text/html; charset=utf-8');
  res.end(`<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>Kube-DC demo app</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#010408;color:#eaeff5;font:600 30px/1.35 system-ui,sans-serif;text-align:center}b{color:#0081f1}small{display:block;margin-top:18px;font-size:18px;opacity:.75}</style>
<main><p>Hello from <b>Kube-DC.cloud</b></p><small>version ${process.env.APP_VERSION || '2.0'}</small><small>${db}</small></main>`);
}).listen(port, () => console.log('listening on :' + port));
