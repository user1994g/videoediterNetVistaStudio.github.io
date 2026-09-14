// Run with: node --experimental-vm-modules Tests/web_auth_regression.cjs
// Offline unit tests: synthetic DOM and Auth service, no real accounts/passwords.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const redirect = 'https://video.netvistastudio.com/account/';
const tick = () => new Promise(resolve => setImmediate(resolve));

for (const file of ['docs/index.html', 'docs/account/index.html']) {
  const html = read(file);
  for (const form of html.matchAll(/<form\b[^>]*>[\s\S]*?<\/form>/g)) {
    assert.match(form[0], /method="post"/);
    assert.match(form[0], /<fieldset disabled/);
    for (const input of form[0].matchAll(/<input\b[^>]*>/g)) {
      assert(!/\bname=/.test(input[0]), 'Native submission must not serialize input values');
    }
  }
}
assert(read('docs/assets/auth-client.js').includes("export const authRedirect = '" + redirect + "'"));
assert(!read('docs/assets/site.js').includes('window.location.origin'));

async function account({ fail = false, session = null, hash = '', pending = false } = {}) {
  const nodes = new Map(), calls = [];
  function node(id) {
    if (nodes.has(id)) return nodes.get(id);
    const e = { value: '', hidden: false, disabled: id.endsWith(':fieldset'), textContent: '',
      classList: { toggle() {} }, setAttribute() {}, checkValidity() { return this.value.includes('@'); },
      handlers: {}, addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); },
      querySelector() { return node(id + ':fieldset'); }, reset() {},
      async fire(type = 'click') {
        const event = { prevented: false, preventDefault() { this.prevented = true; } };
        for (const fn of this.handlers[type] || []) await fn(event);
        await tick(); await tick(); return event;
      }
    };
    nodes.set(id, e); return e;
  }
  let onChange, release;
  const auth = {
    onAuthStateChange(fn) { onChange = fn; },
    async getSession() { return { data: { session } }; },
    async signInWithPassword(args) { calls.push(['signin', args]); return { data: { session: { user: { email: args.email } } } }; },
    async signUp(args) { calls.push(['signup', args]); return { data: { session: { user: { email: args.email } } } }; },
    async resetPasswordForEmail(...args) { calls.push(['reset', ...args]); return { data: {} }; },
    async updateUser(args) { calls.push(['update', args]); return { data: {} }; },
    async signOut() { return { data: {} }; }
  };
  const window = { location: { hash, pathname: '/account/' }, history: { replaceState(...args) { calls.push(['history', ...args]); } } };
  const context = vm.createContext({ document: { querySelector: node }, window, URLSearchParams, setTimeout, clearTimeout });
  const dependency = new vm.SyntheticModule(['supabase', 'authRedirect'], function() {
    this.setExport('supabase', { auth }); this.setExport('authRedirect', redirect);
  }, { context });
  const source = new vm.SourceTextModule(read('docs/account/account.js'), { context,
    importModuleDynamically: async () => {
      if (pending) await new Promise(resolve => { release = resolve; });
      if (fail) throw new Error('offline');
      await dependency.link(() => {}); await dependency.evaluate(); return dependency;
    }
  });
  await source.link(() => {});
  const evaluating = source.evaluate(); await tick();
  if (!pending) await evaluating;
  return { node, calls, auth, evaluating, release: () => release(), event: (event, s) => onChange(event, s) };
}
(async () => {
  const failed = await account({ fail: true });
  assert(failed.node('#signin-panel:fieldset').disabled);
  assert((await failed.node('#signin-panel').fire('submit')).prevented);
  assert.equal(failed.calls.length, 0);
  assert.match(failed.node('#status').textContent, /could not load/);
  const delayed = await account({ pending: true });
  assert(delayed.node('#signin-panel:fieldset').disabled);
  assert((await delayed.node('#signin-panel').fire('submit')).prevented);
  assert.equal(delayed.calls.length, 0);
  delayed.release(); await delayed.evaluating;
  assert(!delayed.node('#signin-panel:fieldset').disabled);
  const normal = await account();
  normal.node('#signin-email').value = ' test@example.invalid ';
  normal.node('#signin-password').value = 'synthetic-only';
  assert((await normal.node('#signin-panel').fire('submit')).prevented);
  assert.equal(normal.calls[0][1].email, 'test@example.invalid');
  assert.equal(normal.calls[0][1].password, 'synthetic-only');
  assert(!normal.node('#signed-in-panel').hidden);
  const signup = await account();
  signup.node('#signup-email').value = 'test@example.invalid';
  signup.node('#signup-password').value = 'synthetic-only';
  signup.node('#signup-name').value = '<b>Test</b>';
  assert((await signup.node('#signup-panel').fire('submit')).prevented);
  assert.equal(signup.calls[0][1].options.emailRedirectTo, redirect);
  assert.equal(signup.calls[0][1].options.data.display_name, '<b>Test</b>');
  const recovery = await account({ session: { user: { email: 'test@example.invalid' } }, hash: '#type=recovery&access_token=synthetic' });
  assert(!recovery.node('#recovery-panel').hidden);
  recovery.node('#recovery-password').value = 'synthetic-new';
  recovery.node('#recovery-confirm').value = 'mismatch';
  await recovery.node('#recovery-panel').fire('submit');
  assert(!recovery.calls.some(c => c[0] === 'update'));
  recovery.node('#recovery-confirm').value = 'synthetic-new';
  await recovery.node('#recovery-panel').fire('submit');
  assert(recovery.calls.some(c => c[0] === 'update' && c[1].password === 'synthetic-new'));
  const expired = await account({ hash: '#error_code=otp_expired&error_description=%3Cscript%3E' });
  assert.match(expired.node('#status').textContent, /already used/);
  assert(!expired.node('#status').textContent.includes('<script>'));
  expired.node('#signin-email').value = 'test@example.invalid';
  await expired.node('#forgot-password').fire();
  assert(expired.calls.some(c => c[0] === 'reset' && c[2].redirectTo === redirect));
  const thrown = await account();
  thrown.auth.signInWithPassword = async () => { throw Error('Network failure'); };
  await thrown.node('#signin-panel').fire('submit');
  assert(!thrown.node('#signin-panel:fieldset').disabled);
  assert.equal(thrown.node('#status').textContent, 'Network failure');
  console.log('PASS: HTML fail-closed forms; blocked/delayed SDK; login; signup; recovery; expired callback; network failure; public redirects.');
})().catch(error => { console.error(error); process.exitCode = 1; });
