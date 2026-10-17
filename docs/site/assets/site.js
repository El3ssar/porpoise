// The newest release's version, next to the download button (the button always downloads the newest release).
if (document.getElementById('version')) fetch('https://api.github.com/repos/El3ssar/porpoise/releases/latest')
  .then((r) => (r.ok ? r.json() : null))
  .then((r) => { if (r && r.tag_name && document.getElementById('version')) document.getElementById('version').textContent = ' · Version ' + r.tag_name.replace(/^v/, ''); })
  .catch(() => {});

// Reveal sections as they scroll into view.
const io = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
}, { threshold: 0.12 });
document.querySelectorAll('.reveal').forEach((el) => io.observe(el));

const appearance = document.getElementById('appearance');
appearance.addEventListener('change', () => {
  if (appearance.value === 'system') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = appearance.value;
});
