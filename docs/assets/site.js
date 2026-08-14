(() => {
  const repository = 'videoediterNetVistaStudio.github.io';
  const repositoryURL = 'https://github.com/user1994g/videoediterNetVistaStudio.github.io';
  const releaseTag = 'v1.3.0-beta.1';
  const releaseURL = `${repositoryURL}/releases/tag/${releaseTag}`;
  const downloads = {
    mac: `${repositoryURL}/releases/download/${releaseTag}/NetVista-Studio-macOS-1.3-Beta-1.zip`,
    windows: `${repositoryURL}/releases/download/${releaseTag}/NetVista-Studio-Windows-1.3-Beta-1.zip`,
    linux: `${repositoryURL}/releases/download/${releaseTag}/NetVista-Studio-Linux-1.3-Beta-1.zip`
  };

  document.querySelectorAll('.github-link').forEach((link) => { link.href = repositoryURL; });
  document.querySelectorAll('.download-link').forEach((link) => { link.href = releaseURL; });
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

  const editorHero = document.querySelector('.editor-hero');
  const editorWindow = editorHero?.querySelector('.editor-window');
  const fitEditorPreview = () => {
    if (!editorHero || !editorWindow) return;
    const naturalWidth = 1040;
    const naturalHeight = 650;
    const scale = Math.min(1, Math.max(0.1, editorHero.clientWidth / naturalWidth));
    editorWindow.style.transform = `scale(${scale})`;
    editorHero.style.height = `${Math.ceil(naturalHeight * scale + 28)}px`;
  };
  fitEditorPreview();
  if ('ResizeObserver' in window) {
    new ResizeObserver(fitEditorPreview).observe(editorHero);
  } else {
    window.addEventListener('resize', fitEditorPreview, { passive: true });
  }

  const downloadModal = document.querySelector('#download-modal');
  const downloadDialog = downloadModal.querySelector('.download-dialog');
  const downloadButtons = document.querySelectorAll('.download-link');
  let downloadReturnFocus = null;
  const preferredPlatform = /Win/i.test(navigator.platform + navigator.userAgent) ? 'windows'
    : /Linux/i.test(navigator.platform + navigator.userAgent) && !/Android/i.test(navigator.userAgent) ? 'linux' : 'mac';
  const preferredCard = downloadModal.querySelector(`[data-platform="${preferredPlatform}"]`);
  preferredCard?.classList.add('recommended');
  preferredCard?.insertAdjacentHTML('afterbegin', '<em class="recommended-label">Recommended</em>');
  const closeDownload = () => {
    if (downloadModal.hidden) return;
    downloadModal.hidden = true;
    document.body.classList.remove('overlay-open');
    downloadReturnFocus?.focus();
  };
  const openDownload = (event) => {
    event.preventDefault();
    downloadReturnFocus = event.currentTarget;
    downloadModal.hidden = false;
    document.body.classList.add('overlay-open');
    downloadDialog.querySelector(`[data-platform="${preferredPlatform}"]`)?.focus();
  };
  downloadButtons.forEach((button) => button.addEventListener('click', openDownload));
  downloadModal.querySelectorAll('[data-close-download]').forEach((button) => button.addEventListener('click', closeDownload));
  downloadModal.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') closeDownload();
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
