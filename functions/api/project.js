import { projectMetadata } from '../../lib/project.js';

export async function onRequestGet(context) {
  const url = new URL('/api/project', context.request.url);
  const key = new Request(url.toString());
  const cache = caches.default;
  const cached = await cache.match(key);
  if (cached) return cached;
  let response;
  try {
    const data = await projectMetadata({ token: context.env.GITHUB_TOKEN });
    response = Response.json(data, { headers: { 'Cache-Control': 'public, max-age=300', 'X-Content-Type-Options': 'nosniff' } });
  } catch {
    // Keep the checked-in date visible if GitHub is down or rate-limited.
    const fallback = await context.env.ASSETS.fetch(new URL('/project.json', url));
    response = new Response(fallback.body, { status: fallback.status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=60', 'X-Content-Type-Options': 'nosniff' } });
  }
  if (response.ok) context.waitUntil(cache.put(key, response.clone()));
  return response;
}
