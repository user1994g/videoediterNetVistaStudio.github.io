// Offline behavior tests; no real accounts or network requests.
// node --experimental-vm-modules Tests/web_download_gate.cjs
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const tick = () => new Promise(resolve => setImmediate(resolve));

async function page({ fail = false } = {}) {
  const nodes = new Map(), calls = [], windowHandlers = {};
  function node(id) {
    if (nodes.has(id)) return nodes.get(id);
    const handlers = {};
    const n = {
      hidden: id.endsWith('-modal'), value: '', dataset: { platform: 'mac' },
      classList: { add() {}, remove() {}, toggle() {} },
      setAttribute() {}, focus() {}, insertAdjacentHTML() {}, contains() { return false; },
      querySelector(selector) { return node(id + ' ' + selector); },
      querySelectorAll(selector) { return selector.includes('data-platform') ? [node('#platform')] : []; },
      reset() { calls.push(['reset', id]); },
      addEventListener(type, fn) { (handlers[type] ||= []).push(fn); },
      async fire(type = 'click') {
        const event = { currentTarget: n, preventDefault() {} };
        for (const fn of handlers[type] || []) await fn(event);
        await tick(); await tick();
      }
    };
    nodes.set(id, n); return n;
  }
  const savedSession = { user: { email: 'remembered@example.invalid' } };
  const auth = {
    async getSession() { return { data: { session: savedSession } }; },
    onAuthStateChange(fn) { fn('SIGNED_IN', savedSession); },
    async signInWithPassword() { calls.push(['signin']); return { data: { session: savedSession } }; },
    async signUp() { calls.push(['signup']); return { data: { session: savedSession } }; }
  };
  const context = vm.createContext({
    document: {
      body: node('body'), querySelector: node, addEventListener() {},
      querySelectorAll(selector) { return selector === '.download-link' ? [node('#get-app')] : []; }
    },
    window: { scrollY: 0, addEventListener(type, fn) { (windowHandlers[type] ||= []).push(fn); } },
    navigator: { platform: 'Mac', userAgent: '' }, setTimeout, clearTimeout
  });
  const dep = new vm.SyntheticModule(['supabase', 'authRedirect'], function () {
    this.setExport('supabase', { auth });
    this.setExport('authRedirect', 'https://video.netvistastudio.com/account/');
  }, { context });
  const source = new vm.SourceTextModule(fs.readFileSync('docs/assets/site.js', 'utf8'), {
    context, importModuleDynamically: async () => {
      if (fail) throw Error('SDK unavailable');
      await dep.link(() => {}); await dep.evaluate(); return dep;
    }
  });
  await source.link(() => {}); await source.evaluate(); await tick(); await tick();
  return { node, auth, calls, restore() { windowHandlers.pageshow.forEach(fn => fn({ persisted: true })); } };
}

(async () => {
  const p = await page();
  const gate = p.node('#account-gate-modal'), chooser = p.node('#download-modal');
  await p.node('#get-app').fire();
  assert(!gate.hidden && chooser.hidden, 'Saved session must still show login');
  await p.node('#gate-signin-form').fire('submit');
  assert(gate.hidden && !chooser.hidden, 'Fresh login opens platform choices');
  await p.node('#platform').fire();
  assert(chooser.hidden, 'Choosing a platform consumes this download flow');
  await p.node('#get-app').fire();
  assert(!gate.hidden && chooser.hidden, 'Second download requires login again');
  p.auth.signInWithPassword = async () => ({ data: {}, error: Error('Wrong password') });
  await p.node('#gate-signin-form').fire('submit');
  assert(!gate.hidden && chooser.hidden, 'Old session cannot bypass a failed login');
  await p.node('#gate-signup-form').fire('submit');
  assert(!chooser.hidden, 'Fresh signup also opens downloads');
  p.restore();
  assert(chooser.hidden, 'Browser back cannot restore an unlocked chooser');
  await p.node('#get-app').fire();
  let finish;
  p.auth.signInWithPassword = () => new Promise(resolve => { finish = resolve; });
  const pending = p.node('#gate-signin-form').fire('submit');
  await tick();
  p.restore();
  await p.node('#get-app').fire();
  finish({ data: { session: { user: {} } } });
  await pending;
  assert(!gate.hidden && chooser.hidden, 'Cancelled login cannot unlock a later request');
  const broken = await page({ fail: true });
  await broken.node('#get-app').fire();
  assert(broken.node('#download-modal').hidden, 'SDK failure keeps downloads closed');
  console.log('PASS: remembered session, repeat download, failed login, signup, browser back, cancelled request, SDK failure.');
})().catch(error => { console.error(error); process.exitCode = 1; });
