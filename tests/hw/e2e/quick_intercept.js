'use strict';
const { chromium } = require('./node_modules/playwright');
const fs = require('fs'), os = require('os'), path = require('path');
function rc(p) {
  if (!p || !fs.existsSync(p)) return {};
  const v = {};
  for (const l of fs.readFileSync(p,'utf8').split('\n')) {
    const m = l.match(/^([A-Z_]+)=(.+)/);
    if (m) v[m[1]] = m[2].trim().replace(/\r$/,'');
  }
  return v;
}
const conf  = rc(path.join(os.homedir(),'.config/misterplex/misterplex.conf'));
const TOKEN = process.env.PLEX_TOKEN || conf.PLEX_TOKEN || '';
const BASE  = process.env.PLEX_BASE  || conf.PLEX_BASE  || '';
const HOST  = '192.168.1.183';

(async () => {
  const b   = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const ctx = await b.newContext({
    storageState: {
      origins: [{ origin: BASE, localStorage: [
        { name: 'myPlexAccessToken', value: TOKEN },
        { name: 'myPlexAuthToken',   value: TOKEN },
      ]}],
    },
  });
  const page = await ctx.newPage();
  const T0   = Date.now();
  const s    = () => `+${((Date.now()-T0)/1000).toFixed(2)}s`;
  const log  = [];

  // Capture ALL requests, mark failed ones and daemon-bound ones specially
  page.on('request', r => {
    const u = r.url();
    const label = u.includes(HOST+':3005') ? 'DAEMON_REQ' :
                  u.includes('192.168.') ? 'LOCAL_REQ' : 'EXT_REQ';
    log.push(`${s()} ${label.padEnd(12)} ${r.method()} ${u.replace(BASE,'<PMS>').slice(0,120)}`);
  });
  page.on('requestfailed', r => {
    const u = r.url();
    log.push(`${s()} FAIL         ${r.failure().errorText} ${u.slice(0,120)}`);
  });
  page.on('response', r => {
    if (r.url().includes(HOST+':3005')) {
      log.push(`${s()} DAEMON_RESP  ${r.status()} ${r.url().replace('http://'+HOST+':3005','<D>').slice(0,120)}`);
    }
  });

  console.log(`[0.00s] navigating Plex Web to media detail`);
  await page.goto(
    `${BASE}/web/index.html#!/server/auto/details?key=/library/metadata/3`,
    { waitUntil: 'networkidle', timeout: 30000 }
  ).catch(()=>{});
  await page.waitForTimeout(3000);
  console.log(`[${s()}] done waiting`);

  // Print only daemon and failed requests to keep output focused
  console.log('\n=== ALL_DAEMON_REQUESTS ===');
  for (const l of log.filter(x => x.includes('DAEMON'))) console.log(l);
  console.log('\n=== FAILED_REQUESTS (first 30) ===');
  for (const l of log.filter(x => x.includes('FAIL')).slice(0,30)) console.log(l);
  console.log('\n=== LOCAL_REQUESTS ===');
  for (const l of log.filter(x => x.includes('LOCAL_REQ'))) console.log(l);
  console.log(`\nTotal requests: ${log.length}`);

  await b.close();
})().catch(e => { console.error('ERR:'+e.message); process.exit(1); });
