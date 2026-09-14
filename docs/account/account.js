const $ = selector => document.querySelector(selector);
const signin = $('#signin-panel'), signup = $('#signup-panel'), recovery = $('#recovery-panel');
const forms = [signin, signup, recovery];
const callback = new URLSearchParams(window.location.hash.slice(1));
const callbackError = callback.get('error_code') || callback.get('error');
let wantsRecovery = callback.get('type') === 'recovery';
let client, redirectTo, user = null, ready = false;
let mode = new URLSearchParams(window.location.search).get('mode') === 'signup' ? 'signup' : 'signin';
const setStatus = (message, tone = '') => {
  $('#status').hidden = !message;
  $('#status').className = 'account-status ' + tone;
  $('#status').textContent = message;
};
const render = () => {
  const recovering = mode === 'recovery' && Boolean(user);
  signin.hidden = Boolean(user) || mode !== 'signin';
  signup.hidden = Boolean(user) || mode !== 'signup';
  recovery.hidden = !recovering;
  $('#signed-in-panel').hidden = !user || recovering;
  $('.account-tabs').hidden = Boolean(user);
  for (const tab of ['signin', 'signup']) {
    $('#' + tab + '-tab').setAttribute('aria-selected', String(mode === tab));
    $('#' + tab + '-tab').classList.toggle('is-active', mode === tab);
  }
  $('#account-subtitle').textContent = recovering ? 'Choose a new, unique password.' : user ? 'Your NetVista account is ready.' : 'Sign in or create your NetVista account.';
  $('#signed-in-email').textContent = user?.email || '';
  $('#account-title').textContent = recovering ? 'A fresh start.' : user ? 'You’re all set.' : mode === 'signup' ? 'Join the studio.' : 'Welcome back.';
};
const request = async operation => {
  let timer;
  try {
    return await Promise.race([operation(), new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Connection timed out. Please try again.')), 20000);
    })]);
  } catch (error) { return { data: {}, error }; }
  finally { clearTimeout(timer); }
};
const run = async (form, message, operation, success) => {
  if (!ready || form.querySelector('fieldset').disabled) return;
  form.querySelector('fieldset').disabled = true;
  setStatus(message);
  try {
    const { data, error } = await request(operation);
    if (error) { setStatus(error.message || 'Please try again.', 'error'); return; }
    form.reset();
    success(data);
  } finally { form.querySelector('fieldset').disabled = !ready; }
};
// Cancel submission before importing remote code. HTML is disabled and inputs
// are nameless as independent defenses against native credential serialization.
forms.forEach(form => form.addEventListener('submit', event => event.preventDefault()));
$('#signin-tab').addEventListener('click', () => { mode = 'signin'; render(); setStatus(''); });
$('#signup-tab').addEventListener('click', () => { mode = 'signup'; render(); setStatus(''); });
signin.addEventListener('submit', () => {
  const email = $('#signin-email').value.trim(), password = $('#signin-password').value;
  run(signin, 'Signing you in…', () => client.auth.signInWithPassword({ email, password }), data => {
    user = data.session?.user || null; mode = 'signin'; render();
    setStatus(user ? 'Signed in. You can now get the app.' : 'Sign-in did not create a session. Please try again.', user ? 'success' : 'error');
  });
});
signup.addEventListener('submit', () => {
  const email = $('#signup-email').value.trim(), password = $('#signup-password').value;
  const name = $('#signup-name').value.trim();
  run(signup, 'Creating your account…', () => client.auth.signUp({ email, password,
    options: { emailRedirectTo: redirectTo, data: name ? { display_name: name } : undefined }
  }), data => {
    user = data.session?.user || null; mode = 'signin'; render();
    $('#signin-email').value = email;
    setStatus(user ? 'Account created. You can now get the app.' : 'Account created. Sign in to continue.', user ? 'success' : '');
  });
});
$('#forgot-password').addEventListener('click', () => {
  const email = $('#signin-email').value.trim();
  if (!email || !$('#signin-email').checkValidity()) { setStatus('Enter a valid email address first.', 'error'); return; }
  run(signin, 'Sending a password reset email…', () => client.auth.resetPasswordForEmail(email, { redirectTo }), () => {
    $('#signin-email').value = email;
    setStatus('If an account uses that email, a reset link is on its way. Open the newest link once.', 'success');
  });
});
recovery.addEventListener('submit', () => {
  if (!user) return;
  const password = $('#recovery-password').value;
  if (password.length < 8 || password !== $('#recovery-confirm').value) { setStatus('Use at least 8 characters and make both passwords match.', 'error'); return; }
  run(recovery, 'Saving your new password…', () => client.auth.updateUser({ password }), () => {
    wantsRecovery = false; mode = 'signin'; render(); setStatus('Your password has been updated.', 'success');
  });
});
$('#change-password').addEventListener('click', () => { if (ready && user) { mode = 'recovery'; render(); setStatus(''); } });
$('#cancel-recovery').addEventListener('click', () => { wantsRecovery = false; recovery.reset(); mode = 'signin'; render(); setStatus(''); });
$('#signout').addEventListener('click', async () => {
  if (!ready) return;
  const { error } = await request(() => client.auth.signOut());
  if (error) setStatus(error.message, 'error');
  else { user = null; wantsRecovery = false; mode = 'signin'; forms.forEach(form => form.reset()); render(); setStatus('You are signed out.', 'success'); }
});
$('#year').textContent = new Date().getFullYear();
render();
setStatus('Connecting securely…');
const initialized = await request(async () => {
  const auth = await import('../assets/auth-client.js');
  client = auth.supabase; redirectTo = auth.authRedirect;
  client.auth.onAuthStateChange((event, session) => {
    user = session?.user || null;
    if (event === 'PASSWORD_RECOVERY') wantsRecovery = true;
    // Preserve an explicit ?mode=signup deep link on the initial signed-out
    // callback; this is how the native app opens the create-account tab.
    if (!user) { wantsRecovery = false; if (mode !== 'signup') mode = 'signin'; }
    else if (wantsRecovery) mode = 'recovery';
    render();
  });
  const result = await client.auth.getSession();
  if (result.error) throw result.error;
  return result;
});
if (initialized.error) {
  setStatus('Secure sign-in could not load. Check your connection and reload this page. No password has been sent.', 'error');
} else {
  ready = true;
  user = initialized.data.session?.user || null;
  if (wantsRecovery && user) mode = 'recovery';
  forms.forEach(form => { form.querySelector('fieldset').disabled = false; });
  render();
  setStatus(callbackError ? (callbackError === 'otp_expired'
    ? 'This email link has expired or was already used. Try signing in; for a password reset, request a new link below.'
    : 'This email link could not be verified. Try signing in or request a new password reset.') : '', callbackError ? 'error' : '');
  // Remove callback material only after the SDK has consumed it.
  if (window.location.hash) window.history.replaceState(null, '', window.location.pathname);
}
