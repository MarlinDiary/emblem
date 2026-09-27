// Local preview through the exact generated Worker, so headers and CSP match production.
import http from 'node:http';
import { stat } from 'node:fs/promises';
const port = Number(process.env.PORT || 8788);
let loaded = { mtime: 0, worker: null };
async function worker() {
  const { mtimeMs } = await stat(new URL('./worker.mjs', import.meta.url));
  if (mtimeMs !== loaded.mtime) loaded = { mtime: mtimeMs, worker: (await import(`./worker.mjs?v=${mtimeMs}`)).default };
  return loaded.worker;
}
http.createServer(async (req, res) => {
  const response = await (await worker()).fetch(new Request(`https://emblem.protoyard.com${req.url}`, { method: req.method }));
  const headers = Object.fromEntries(response.headers);
  delete headers['strict-transport-security'];
  headers['cache-control'] = 'no-store'; // always serve the latest local build
  res.writeHead(response.status, headers);
  res.end(Buffer.from(await response.arrayBuffer()));
}).listen(port, '127.0.0.1', () => console.log(`Emblem site preview: http://localhost:${port}/`));
