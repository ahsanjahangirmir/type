# Type product page

Single-page product website for the native Mac writing application. Built with Astro, TypeScript, GSAP and Lenis. The primary action opens https://github.com/ahsanjahangirmir/type.

## Local development

```sh
cd website
npm ci
npm run dev -- --background
```

Manage the development process with `npx astro dev status`, `npx astro dev logs`, and `npx astro dev stop`.

## Validation

```sh
npm run check
npm run build
npm run preview -- --host 127.0.0.1 --port 4400
node scripts/verify.mjs http://127.0.0.1:4400
```

The functional check writes its report and activated focus/theme captures to `.shots-pass2/`. Comprehensive screenshot and audit passes use the globally installed awwwards skill tools; results are summarized in QA.md. Evidence directories are intentionally gitignored.

## Branch Preview deployment

Run from `website/` on `feat/type-product-site` only:

```sh
vercel link --yes --project type-product-page
vercel deploy --yes --environment preview --meta githubCommitRef=feat/type-product-site
```

Never use `--prod` for this work. Git deployments are disabled in `vercel.json`, and the GitHub repository is not connected to this Vercel project. The CLI uploads only this subdirectory. Vercel Preview URL drives canonical, Open Graph and sitemap URLs at build time. Previews have noindex headers/meta and disallow crawling. A public production release requires a deliberate metadata and indexing change.

## Design and content

The brief, concept scoring, art direction, motion rules, and capture safeguards are recorded in `../DESIGN.md`. Structured theme and feature content lives in `src/data/site.ts`; page-specific copy lives in `src/pages/index.astro`. Styles are in `src/styles/site.css`; the hero focus driver is in `src/motion/type.ts`.

Actual sample-only app media is in `public/media/`, with capture provenance in `PROVENANCE.md`. Fonts are self-hosted, with their source and license references in `public/fonts/README.md`. No user writing, invented testimonials, fake usage metrics, or paid plans are included. This page does not add a license to the app repository.

### Initial-project limitation

Vercel CLI 65.14.0 refuses Preview as the first deployment in a new project (`first_deployment_production`). This project's initial deployment is pending approval because delivery was planned as Preview-only. Do not retry with `--prod` without authorization. The website and its GitHub destination are ready; no deployment has been created yet.
