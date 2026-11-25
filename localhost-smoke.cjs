
const dns = require('node:dns').promises;
let step = 'start';
const timer = setTimeout(() => {
  console.error('ci-router: localhost resolver smoke timed out at ' + step);
  process.exit(1);
}, 10000);
(async () => {
  for (const name of ['localhost', 'app.localhost', 'nested.app.localhost']) {
    for (const family of [4, 6]) {
      step = 'lookup ' + name + ' IPv' + family;
      const result = await dns.lookup(name, { family });
      if (result.address !== (family === 4 ? '127.0.0.1' : '::1')) throw new Error('got ' + result.address);
    }
  }
  if (process.argv.includes('--connect')) {
    const net = require('node:net');
    step = 'hosts override';
    if ((await dns.lookup('ci-router-override.localhost', { family: 4 })).address !== '127.0.0.2')
      throw new Error('hosts override lost');
    for (const family of [4, 6, 0]) {
      step = 'connect ' + (family ? 'IPv' + family : 'default');
      const server = net.createServer((socket) => socket.end('loopback'));
      try {
        const host = family === 4 ? '127.0.0.1' : family === 6 ? '::1' : undefined;
        await new Promise((resolve, reject) => server.once('error', reject).listen({ port: 0, ...(host ? { host } : {}) }, resolve));
      } catch (error) {
        if (family === 6 && ['EAFNOSUPPORT', 'EADDRNOTAVAIL'].includes(error.code)) {
          console.log('ci-router: IPv6 socket unavailable; IPv6 lookup passed');
          continue;
        }
        throw error;
      }
      try {
        await new Promise((resolve, reject) => {
          const socket = net.connect({ host: 'app.localhost', port: server.address().port, ...(family ? { family } : {}) });
          socket.setTimeout(2000, () => socket.destroy(new Error('connection timeout')));
          let body = '';
          socket.on('data', (chunk) => body += chunk);
          socket.on('error', reject);
          socket.on('end', () => { if (body === 'loopback') resolve(); else reject(new Error('invalid response')); });
        });
      } finally {
        await new Promise((resolve) => server.close(resolve));
      }
      console.log(family ? 'ci-router: IPv' + family + ' explicit connection passed' : 'ci-router: default connection passed');
    }
  }
})().then(() => {
  clearTimeout(timer);
  console.log('ci-router: localhost resolver smoke passed');
}, (error) => {
  clearTimeout(timer);
  const reason = String((error && (error.code || error.message)) || 'error').slice(0, 120);
  let ipv6 = 'no';
  try {
    if (require('node:fs').readFileSync('/proc/net/if_inet6', 'utf8').trim()) ipv6 = 'yes';
  } catch {}
  console.error('ci-router: localhost resolver smoke failed at ' + step + ': ' + reason + ' (kernel IPv6: ' + ipv6 + ')');
  process.exitCode = 1;
});
