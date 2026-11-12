import type { APIRoute } from 'astro';
export const GET: APIRoute = ({ site }) => new Response(`User-agent: *\nDisallow: /\nSitemap: ${new URL('/sitemap-index.xml', site)}\n`,{headers:{'Content-Type':'text/plain'}});
