import { readFile, writeFile } from 'node:fs/promises';
import { projectMetadata } from '../lib/project.js';

let data;
try {
  data = await projectMetadata({ token: process.env.GITHUB_TOKEN });
} catch (error) {
  try {
    data = JSON.parse(await readFile('public/project.json', 'utf8'));
    console.warn(`Using the saved app commit snapshot: ${error.message}`);
  } catch {
    throw new Error('Cannot fetch project metadata and no saved snapshot exists', { cause: error });
  }
}
const date = new Date(data.commit.date);
const formatted = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(date);
let html = await readFile('public/index.html', 'utf8');
html = html.replace(/(<time data-commit-date datetime=")[^"]*(">)[^<]*(<\/time>)/, `$1${date.toISOString()}$2${formatted}$3`);
html = html.replace(/(<a class="commit-line" data-commit-link href=")[^"]*(")/, `$1https://github.com/hidoba/Soduto/commit/${data.commit.sha}$2`);
html = html.replace(/(<span data-version>)[^<]*(<\/span>)/, `$1${data.release.tag}$2`);
if (data.release.download.startsWith('https://github.com/hidoba/Soduto/releases/download/')) {
  html = html.replaceAll(/(data-download href=")[^"]*(")/g, `$1${data.release.download}$2`);
}
await writeFile('public/index.html', html);
await writeFile('public/project.json', JSON.stringify(data, null, 2) + '\n');
console.log(`Built Soduto page: ${data.release.tag}, latest app commit ${data.commit.sha.slice(0, 7)} (${formatted}, UTC).`);
