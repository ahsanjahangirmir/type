import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
const host = process.env.SITE_URL || (process.env.VERCEL_URL ? `https://${process.env.VERCEL_URL}` : 'http://localhost:4400');
export default defineConfig({ site: host, integrations: [sitemap()], build: { inlineStylesheets: 'auto' } });
