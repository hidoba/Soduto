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
