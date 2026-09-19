(() => {
  const repository = 'videoediterNetVistaStudio.github.io';
  const repositoryURL = 'https://github.com/user1994g/videoediterNetVistaStudio.github.io';
  // Keep download links on a published release until the next assets exist.
  const releaseTag = 'v1.4.0-beta.4';
  const releaseURL = `${repositoryURL}/releases/tag/${releaseTag}`;
  const downloads = {
    mac: `${repositoryURL}/releases/download/${releaseTag}/NetVista-Studio-macOS-1.4-Beta-4.zip`,
    windows: `${repositoryURL}/releases/download/${releaseTag}/NetVista-Studio-Windows-1.4-Beta-4.zip`,
    linux: `${repositoryURL}/releases/download/${releaseTag}/NetVista-Studio-Linux-1.4-Beta-4.zip`
  };

  document.querySelectorAll('.github-link').forEach((link) => { link.href = repositoryURL; });
  document.querySelectorAll('.download-link').forEach((link) => { link.href = '#download'; });
  document.querySelectorAll('.releases-link').forEach((link) => { link.href = releaseURL; });
  document.querySelectorAll('[data-platform]').forEach((link) => { link.href = downloads[link.dataset.platform]; });
  document.querySelectorAll('.clone-url').forEach((node) => { node.textContent = `${repositoryURL}.git`; });
  document.querySelectorAll('.repo-name').forEach((node) => { node.textContent = repository; });
  document.querySelectorAll('[data-current-year]').forEach((node) => { node.textContent = new Date().getFullYear(); });

  const reveals = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.08 });
    reveals.forEach((item) => observer.observe(item));
  } else {
    reveals.forEach((item) => item.classList.add('visible'));
  }

  const header = document.querySelector('#site-header');
  const navToggle = document.querySelector('#nav-toggle');
  const primaryNav = document.querySelector('#primary-nav');
  const closeNavigation = () => {
    header.classList.remove('nav-open');
    navToggle.setAttribute('aria-expanded', 'false');
  };
  const updateHeader = () => header.classList.toggle('is-scrolled', window.scrollY > 18);
  updateHeader();
  window.addEventListener('scroll', updateHeader, { passive: true });
  navToggle.addEventListener('click', () => {
    const open = !header.classList.contains('nav-open');
    header.classList.toggle('nav-open', open);
    navToggle.setAttribute('aria-expanded', String(open));
  });
  primaryNav.querySelectorAll('a').forEach((link) => link.addEventListener('click', closeNavigation));
  document.addEventListener('click', (event) => {
    if (!header.contains(event.target)) closeNavigation();
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') closeNavigation();
  });

  const downloadModal = document.querySelector('#download-modal');
  const downloadDialog = downloadModal.querySelector('.download-dialog');
  const accountGateModal = document.querySelector('#account-gate-modal');
  const accountGateDialog = accountGateModal.querySelector('.account-gate-dialog');
  const accountGateSigninTab = document.querySelector('#gate-signin-tab');
  const accountGateSignupTab = document.querySelector('#gate-signup-tab');
  const accountGateSigninForm = document.querySelector('#gate-signin-form');
  const accountGateSignupForm = document.querySelector('#gate-signup-form');
  const accountGateStatus = document.querySelector('#account-gate-status');
  const backgroundSurfaces = [...document.querySelectorAll('header, main, footer')];
  const downloadButtons = document.querySelectorAll('.download-link');
  let downloadReturnFocus = null;
  let accountGateReturnFocus = null;
  let gateAttempt = 0;
  let authRedirect;
  let authReady = null;
  const authRequest = async (operation) => {
    let timer;
    try {
      return await Promise.race([operation(), new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Connection timed out. Please try again.')), 20000);
      })]);
    } catch (error) {
      return { data: {}, error };
    } finally { clearTimeout(timer); }
  };
  // Keep ordinary site visits light: the Supabase SDK is loaded only when
  // someone opens the account/download flow that needs it.
  const loadAuthClient = () => {
    if (authReady) return authReady;
    authReady = authRequest(async () => {
      const { supabase, authRedirect: publicRedirect } = await import('./auth-client.js');
      authRedirect = publicRedirect;
      // A remembered session must never unlock a new download request.
      return { data: supabase };
    }).then(({ data, error }) => {
      if (error) return null;
      [accountGateSigninForm, accountGateSignupForm].forEach(form => { form.querySelector('fieldset').disabled = false; });
      return data;
    });
    return authReady;
  };
  const preferredPlatform = /Win/i.test(navigator.platform + navigator.userAgent) ? 'windows'
    : /Linux/i.test(navigator.platform + navigator.userAgent) && !/Android/i.test(navigator.userAgent) ? 'linux' : 'mac';
  const preferredCard = downloadModal.querySelector(`[data-platform="${preferredPlatform}"]`);
  preferredCard?.classList.add('recommended');
  preferredCard?.insertAdjacentHTML('afterbegin', '<em class="recommended-label">Recommended</em>');
  const closeDownload = () => {
    if (downloadModal.hidden) return;
    downloadModal.hidden = true;
    document.body.classList.remove('overlay-open');
    backgroundSurfaces.forEach((element) => { element.inert = false; });
    downloadReturnFocus?.focus();
  };
  const openDownloadChooser = () => {
    downloadModal.hidden = false;
    document.body.classList.add('overlay-open');
    backgroundSurfaces.forEach((element) => { element.inert = true; });
    downloadDialog.querySelector(`[data-platform="${preferredPlatform}"]`)?.focus();
  };
  const setGateStatus = (message, tone = '') => {
    accountGateStatus.hidden = !message;
    accountGateStatus.className = `account-gate-status ${tone}`.trim();
    accountGateStatus.textContent = message;
  };
  const setGateMode = (mode) => {
    const signup = mode === 'signup';
    accountGateSigninTab.classList.toggle('is-active', !signup);
    accountGateSignupTab.classList.toggle('is-active', signup);
    accountGateSigninTab.setAttribute('aria-selected', String(!signup));
    accountGateSignupTab.setAttribute('aria-selected', String(signup));
    accountGateSigninForm.hidden = signup;
    accountGateSignupForm.hidden = !signup;
    document.querySelector('#account-gate-title').textContent = signup ? 'Join the studio.' : 'Welcome back.';
    document.querySelector('#account-gate-description').textContent = signup ? 'Create a free account and start making.' : 'Sign in for this download. We ask each time you get the app.';
    setGateStatus('');
  };
  const setGateBusy = (form, busy) => {
    form.querySelector('fieldset').disabled = busy;
  };
  const closeAccountGate = () => {
    if (accountGateModal.hidden) return;
    gateAttempt += 1;
    accountGateSigninForm.reset();
    accountGateSignupForm.reset();
    accountGateModal.hidden = true;
    document.body.classList.remove('overlay-open');
    backgroundSurfaces.forEach((element) => { element.inert = false; });
    accountGateReturnFocus?.focus();
  };
  const openAccountGate = (event) => {
    event.preventDefault();
    const attempt = ++gateAttempt;
    accountGateReturnFocus = event.currentTarget;
    accountGateModal.hidden = false;
    document.body.classList.add('overlay-open');
    backgroundSurfaces.forEach((element) => { element.inert = true; });
    setGateMode('signin');
    setGateStatus('Loading sign-in…');
    loadAuthClient().then((client) => {
      if (accountGateModal.hidden || attempt !== gateAttempt) return;
      if (!client) {
        setGateStatus('Account sign-in is temporarily unavailable. Please try again shortly.', 'error');
      } else {
        setGateStatus('');
        const activeForm = accountGateSignupForm.hidden ? accountGateSigninForm : accountGateSignupForm;
        activeForm.querySelector('input')?.focus();
      }
    });
  };
  const handleDownloadRequest = (event) => {
    downloadReturnFocus = event.currentTarget;
    openAccountGate(event);
  };
  downloadButtons.forEach((button) => button.addEventListener('click', handleDownloadRequest));
  downloadModal.querySelectorAll('[data-close-download]').forEach((button) => button.addEventListener('click', closeDownload));
  downloadModal.querySelectorAll('[data-platform]').forEach((link) => link.addEventListener('click', closeDownload));
  window.addEventListener('pageshow', (event) => {
    if (event.persisted) { closeDownload(); closeAccountGate(); }
  });
  downloadModal.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { event.preventDefault(); closeDownload(); }
    if (event.key === 'Tab') {
      const controls = [...downloadDialog.querySelectorAll('a[href], button:not([disabled])')];
      const first = controls[0], last = controls[controls.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }
  });
  accountGateSigninTab.addEventListener('click', () => setGateMode('signin'));
  accountGateSignupTab.addEventListener('click', () => setGateMode('signup'));
  accountGateModal.querySelectorAll('[data-close-account-gate]').forEach((button) => button.addEventListener('click', closeAccountGate));
  accountGateModal.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { event.preventDefault(); closeAccountGate(); return; }
    if (event.key === 'Tab') {
      const controls = [...accountGateDialog.querySelectorAll('a[href], button:not(:disabled), input:not(:disabled)')].filter(control => !control.closest('[hidden]'));
      const first = controls[0], last = controls[controls.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }
  });
  accountGateSigninForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const attempt = gateAttempt;
    const client = await loadAuthClient();
    if (accountGateModal.hidden || attempt !== gateAttempt) return;
    if (!client) { setGateStatus('Account sign-in is temporarily unavailable. Please try again shortly.', 'error'); return; }
    const email = document.querySelector('#gate-signin-email').value.trim();
    const password = document.querySelector('#gate-signin-password').value;
    setGateBusy(accountGateSigninForm, true); setGateStatus('Signing you in…');
    const { data, error } = await authRequest(() => client.auth.signInWithPassword({ email, password }));
    setGateBusy(accountGateSigninForm, false);
    if (accountGateModal.hidden || attempt !== gateAttempt) return;
    if (error) { setGateStatus(error.message || 'We could not sign you in. Check your email and password.', 'error'); return; }
    accountGateSigninForm.reset();
    if (!data.session) { setGateStatus('Please sign in again to continue.', 'error'); return; }
    closeAccountGate();
    openDownloadChooser();
  });
  accountGateSignupForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const attempt = gateAttempt;
    const client = await loadAuthClient();
    if (accountGateModal.hidden || attempt !== gateAttempt) return;
    if (!client) { setGateStatus('Account sign-in is temporarily unavailable. Please try again shortly.', 'error'); return; }
    const email = document.querySelector('#gate-signup-email').value.trim();
    const password = document.querySelector('#gate-signup-password').value;
    const displayName = document.querySelector('#gate-signup-name').value.trim();
    setGateBusy(accountGateSignupForm, true); setGateStatus('Creating your account…');
    const { data, error } = await authRequest(() => client.auth.signUp({
      email, password,
      options: { emailRedirectTo: authRedirect, data: displayName ? { display_name: displayName } : undefined }
    }));
    setGateBusy(accountGateSignupForm, false);
    if (accountGateModal.hidden || attempt !== gateAttempt) return;
    if (error) { setGateStatus(error.message || 'We could not create that account. Please try again.', 'error'); return; }
    if (data.session) {
      accountGateSignupForm.reset();
      if (accountGateModal.hidden) return;
      closeAccountGate();
      openDownloadChooser();
    } else {
      setGateMode('signin');
      document.querySelector('#gate-signin-email').value = email;
      accountGateSignupForm.reset();
      setGateStatus('Account created. Sign in to continue.', 'success');
    }
  });
  document.querySelector('#gate-forgot-password').addEventListener('click', async () => {
    const client = await loadAuthClient();
    const email = document.querySelector('#gate-signin-email').value.trim();
    if (!email) { setGateStatus('Enter your email address first, then press “Forgot your password?”.', 'error'); document.querySelector('#gate-signin-email').focus(); return; }
    if (!client) { setGateStatus('Account sign-in is temporarily unavailable. Please try again shortly.', 'error'); return; }
    setGateStatus('Sending a password reset email…');
    const { error } = await authRequest(() => client.auth.resetPasswordForEmail(email, { redirectTo: authRedirect }));
    if (error) setGateStatus(error.message || 'We could not send the reset email.', 'error');
    else setGateStatus('If an account uses that email, a password reset link is on its way.', 'success');
  });
  const copyButton = document.querySelector('.copy-button');
  copyButton.addEventListener('click', async () => {
    const command = `git clone ${repositoryURL}.git\ncd ${repository}\n# macOS: sh build_app.sh\n# Windows/Linux: see cross_platform/README.md`;
    try {
      await navigator.clipboard.writeText(command);
      copyButton.textContent = 'Copied';
      setTimeout(() => { copyButton.textContent = 'Copy'; }, 1800);
    } catch {
      copyButton.textContent = 'Select text';
    }
  });
})();
