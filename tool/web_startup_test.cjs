'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync('web/index.html', 'utf8');
const shellSource = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const bootstrap = fs.readFileSync('web/flutter_bootstrap.js', 'utf8')
  .replace('{{flutter_js}}', '').replace('{{flutter_build_config}}', '');
function shell() {
  const spinner = {hidden:false};
  const message = {textContent:'Loading the game…'};
  const retry = {hidden:true, addEventListener: (_, fn) => retry.click = fn};
  const overlay = {removed:false, busy:true, remove() {this.removed=true;},
    setAttribute(_, v) {this.busy=v;}, querySelector: () => spinner};
  let slow, cleared = false, reloads = 0;
  const window = {location:{reload:() => reloads++}};
  const ctx = {window, document:{getElementById: id => ({startup:overlay,
    'startup-message':message,'startup-retry':retry})[id]},
    setTimeout:fn => {slow=fn; return 1;}, clearTimeout:() => cleared=true};
  vm.runInNewContext(shellSource, ctx);
  return {ctx, window, overlay, message, retry, spinner,
    slow:() => slow(), cleared:() => cleared, reloads:() => reloads};
}
const flush = () => new Promise(resolve => setImmediate(resolve));
test('bootstrap download failure gives a visible retry; completed shell stays removed', () => {
  const s = shell();
  s.window.doomLoader.fail();
  assert.equal(s.retry.hidden, false);
  assert.equal(s.overlay.busy, 'false');
  assert.equal(s.spinner.hidden, true);
  s.retry.click(); assert.equal(s.reloads(), 1);
  assert.match(html, /onerror="window.doomLoader.fail\(\)"/);
  s.window.doomLoader.complete(); s.window.doomLoader.fail();
  assert.equal(s.overlay.removed, true);
  assert.equal(s.cleared(), true);
});
test('slow startup is recoverable without preventing eventual success', () => {
  const s = shell(); s.slow();
  assert.match(s.message.textContent, /longer than usual/);
  assert.equal(s.retry.hidden, false);
  s.window.doomLoader.complete();
  assert.equal(s.overlay.removed, true);
});
for (const phase of ['load-throws','load-rejects','engine','runApp']) {
  test(`failure at ${phase} reaches the startup shell`, async () => {
    const s = shell();
    const fail = () => {throw new Error(phase);};
    s.ctx.console = {error:() => {}};
    s.ctx._flutter = {loader:{load(options) {
      if (phase === 'load-throws') fail();
      if (phase === 'load-rejects') return Promise.reject(new Error(phase));
      return options.onEntrypointLoaded({initializeEngine: phase === 'engine' ? fail :
        async () => ({runApp:fail})});
    }}};
    vm.runInNewContext(bootstrap, s.ctx); await flush();
    assert.equal(s.retry.hidden, false);
    assert.equal(s.overlay.removed, false);
  });
}
test('successful bootstrap waits for runApp before removing the shell', async () => {
  const s = shell(); let finish;
  s.ctx._flutter = {loader:{load: options => options.onEntrypointLoaded({
    initializeEngine: async () => ({runApp: () => new Promise(resolve => finish=resolve)})
  })}};
  s.ctx.console = console;
  vm.runInNewContext(bootstrap, s.ctx); await flush();
  assert.equal(s.overlay.removed, false);
  finish(); await flush(); assert.equal(s.overlay.removed, true);
});
