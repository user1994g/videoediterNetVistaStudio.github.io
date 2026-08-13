(() => {
  const repository = 'videoediterNetVistaStudio.github.io';
  const repositoryURL = 'https://github.com/user1994g/videoediterNetVistaStudio.github.io';
  const releaseTag = 'v1.1.0-beta.1';
  const downloadURL = `${repositoryURL}/releases/download/${releaseTag}/NetVista-Studio-1.1-Beta.zip`;

  document.querySelectorAll('.github-link').forEach((link) => { link.href = repositoryURL; });
  document.querySelectorAll('.download-link').forEach((link) => { link.href = downloadURL; });
  document.querySelectorAll('.releases-link').forEach((link) => { link.href = `${repositoryURL}/releases/tag/${releaseTag}`; });
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

  const copyButton = document.querySelector('.copy-button');
  copyButton.addEventListener('click', async () => {
    const command = `git clone ${repositoryURL}.git\ncd ${repository}\nsh build_app.sh`;
    try {
      await navigator.clipboard.writeText(command);
      copyButton.textContent = 'Copied';
      setTimeout(() => { copyButton.textContent = 'Copy'; }, 1800);
    } catch {
      copyButton.textContent = 'Select text';
    }
  });
})();
