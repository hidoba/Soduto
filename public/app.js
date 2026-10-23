const formats = {
  text: {label:'Text copied', transfer:'Text clipboard', html:'<div class="clipboard-text">See you at 6.</div>'},
  image: {label:'Image copied', transfer:'Image clipboard', html:'<div class="clipboard-photo"><span class="photo-sun"></span></div><span class="content-filename">weekend.png<b>PNG image</b></span>'},
  file: {label:'File copied', transfer:'File clipboard', html:'<div class="clipboard-file"><b>PDF</b></div><span class="content-filename">ideas.pdf<b>Single file</b></span>'}
};
function showFormat(key) {
  const format = formats[key];
  if (!format) return;
  document.querySelector('.sync-demo').dataset.format = key;
  document.querySelectorAll('[data-format-button]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.formatButton === key)));
  document.querySelectorAll('[data-clipboard-content]').forEach(content => { content.innerHTML = format.html; });
  document.querySelector('[data-copy-label]').textContent = format.label;
  document.querySelector('[data-transfer-label]').textContent = format.transfer;
}
for (const button of document.querySelectorAll('[data-format-button]')) button.addEventListener('click', () => showFormat(button.dataset.formatButton));
showFormat('image');
const compactDiagram = matchMedia('(max-width: 520px)');
function positionArrows() {
  const paths = compactDiagram.matches ? [
    'M570 265C570 165 190 250 190 170', 'M660 265C660 160 860 245 860 170',
    'M400 330C300 330 220 310 220 395', 'M780 330C880 330 890 310 890 405'
  ] : [
    'M399 260C326 260 359 131 299 131', 'M399 320C316 320 367 413 308 413',
    'M780 260C848 260 813 150 868 150', 'M780 330C865 330 879 433 953 433'
  ];
  document.querySelectorAll('.connections .flow').forEach((path, index) => path.setAttribute('d', paths[index]));
}
positionArrows();
compactDiagram.addEventListener('change', positionArrows);

function updateProject(data) {
  // Only use canonical URLs assembled from validated GitHub metadata.
  const date = new Date(data.commit?.date);
  if (/^[a-f0-9]{40}$/.test(data.commit?.sha) && !Number.isNaN(date.getTime())) {
    const time = document.querySelector('[data-commit-date]');
    time.dateTime = date.toISOString();
    time.textContent = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(date);
    const link = document.querySelector('[data-commit-link]');
    link.href = `https://github.com/hidoba/Soduto/commit/${data.commit.sha}`;
    link.title = `Latest app commit: ${data.commit.sha.slice(0, 7)} (UTC)`;
  }
  if (typeof data.release?.tag === 'string' && /^v\d+\.\d+\.\d+(?:[.-][\w.-]+)?$/.test(data.release.tag)) {
    document.querySelector('[data-version]').textContent = data.release.tag;
    const url = data.release.download;
    if (typeof url === 'string' && url.startsWith('https://github.com/hidoba/Soduto/releases/download/') && url.endsWith('.zip')) {
      document.querySelectorAll('[data-download]').forEach(link => { link.href = url; });
    }
  }
}
// A build-time snapshot keeps the date and links available without JavaScript or GitHub.
// The edge endpoint refreshes app-branch metadata independently of website deploys.
(async () => {
  try {
    const response = await fetch('/api/project', { signal: AbortSignal.timeout(7000) });
    if (!response.ok) throw new Error('Project metadata unavailable');
    updateProject(await response.json());
  } catch {
    try {
      const response = await fetch('/project.json', { signal: AbortSignal.timeout(3000) });
      if (response.ok) updateProject(await response.json());
    } catch { /* The server-rendered date and release link remain usable. */ }
  }
})();
