(() => {
  const repository = 'videoediterNetVistaStudio.github.io';
  const repositoryURL = 'https://github.com/user1994g/videoediterNetVistaStudio.github.io';

  document.querySelectorAll('.github-link').forEach((link) => { link.href = repositoryURL; });
  document.querySelectorAll('.clone-url').forEach((node) => { node.textContent = `${repositoryURL}.git`; });
  document.querySelectorAll('.repo-name').forEach((node) => { node.textContent = repository; });
  document.querySelector('#year').textContent = new Date().getFullYear();

  const menuButton = document.querySelector('.menu-button');
  const links = document.querySelector('#nav-links');
  menuButton.addEventListener('click', () => {
    const open = links.classList.toggle('open');
    menuButton.setAttribute('aria-expanded', String(open));
  });
  links.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => {
    links.classList.remove('open');
    menuButton.setAttribute('aria-expanded', 'false');
  }));

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
