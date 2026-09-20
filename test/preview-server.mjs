// Local integration fixture only; not used by the package at runtime.
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
const [port, delay = '0', mode = 'normal'] = process.argv.slice(2);
const server = createServer((request, response) => {
  if (mode === 'hang') return;
  let overrides = {};
  try { overrides = JSON.parse(readFileSync('status.json', 'utf8')); } catch {}
  if (request.url === '/status') {
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ root: process.cwd().replaceAll('\\', '/'), backend: 'test',
      token: process.env.STATIC_SITE_PREVIEW_TOKEN, ready: true, revision: 1, ...overrides }));
  } else {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    response.end('<html><body><h1>Preview fixture</h1></body></html>');
  }
});
setTimeout(() => server.listen(Number(port), '127.0.0.1'), Number(delay));
