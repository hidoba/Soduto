export const REPOSITORY = 'hidoba/Soduto';
export const APP_BRANCH = 'codex/reliability-diagnostics';
export const API_ROOT = `https://api.github.com/repos/${REPOSITORY}`;

export async function projectMetadata({ token, fetcher = fetch } = {}) {
  const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'Soduto-landing-page', 'X-GitHub-Api-Version': '2022-11-28' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const read = async path => {
    const response = await fetcher(`${API_ROOT}/${path}`, { headers, signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error(`GitHub metadata HTTP ${response.status}`);
    return response.json();
  };
  const [commit, release] = await Promise.all([
    read(`commits/${encodeURIComponent(APP_BRANCH)}`),
    read('releases/latest'),
  ]);
  const date = commit.commit?.committer?.date;
  if (!/^[a-f0-9]{40}$/.test(commit.sha) || !date || Number.isNaN(Date.parse(date))) throw new Error('Invalid app commit metadata');
  if (release.draft || release.prerelease || !/^v\d+\.\d+\.\d+(?:[.-][\w.-]+)?$/.test(release.tag_name)) throw new Error('Invalid release metadata');
  const zip = release.assets?.find(asset => /^Soduto-[\w.-]+-macos-universal\.zip$/.test(asset.name));
  const canonicalPrefix = `https://github.com/${REPOSITORY}/releases/download/${release.tag_name}/`;
  const canonicalZip = !!zip && zip.browser_download_url === `${canonicalPrefix}${zip.name}`;
  const download = canonicalZip ? zip.browser_download_url : `https://github.com/${REPOSITORY}/releases/latest`;
  const build = typeof release.body === 'string' ? release.body.match(/https:\/\/github\.com\/hidoba\/Soduto\/actions\/runs\/(\d+)(?=[)\s]|$)/) : null;
  const attestation = release.assets?.some(asset => asset.name === 'release-attestation.sigstore.json' && asset.browser_download_url === `${canonicalPrefix}release-attestation.sigstore.json`);
  return {
    repository: REPOSITORY,
    branch: APP_BRANCH,
    commit: { sha: commit.sha, date },
    release: { tag: release.tag_name, download,
      buildUrl: build ? `https://github.com/${REPOSITORY}/actions/runs/${build[1]}` : null,
      publishedByActions: release.author?.login === 'github-actions[bot]' && canonicalZip && !!attestation && !!build },
  };
}
