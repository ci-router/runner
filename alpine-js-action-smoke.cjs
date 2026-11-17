const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { existsSync, readFileSync, writeFileSync } = require('node:fs');

const [runtime, expectedMajor] = process.argv.slice(2);
assert.match(runtime, /^node\d+_alpine$/);
assert.equal(process.execPath, `/__e/${runtime}/bin/node`);
assert.equal(process.env.GITHUB_ACTIONS, 'true');
assert.equal(process.platform, 'linux');
assert.equal(process.arch, 'x64');
assert.equal(existsSync('/etc/alpine-release'), true);
assert.equal(process.report.getReport().header.glibcVersionRuntime, undefined);
assert.equal(Number(process.versions.node.split('.')[0]), Number(expectedMajor));
assert.equal(execFileSync('sh', ['-c', 'printf action-ok'], { encoding: 'utf8' }), 'action-ok');

const output = `runtime=${runtime}\nnode=${process.versions.node}\n`;
writeFileSync(process.env.GITHUB_OUTPUT, output);
assert.equal(readFileSync(process.env.GITHUB_OUTPUT, 'utf8'), output);
console.log(`JavaScript action runtime ${runtime} passed on Alpine/musl`);
