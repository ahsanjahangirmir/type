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

## Deployment

Live website: https://type-product-page.vercel.app

The user approved the dedicated project's initial Production deployment after Vercel CLI refused Preview as the first deployment. The deployed source is commit `3746fb5` on `feat/type-product-site`. Only `website/` is uploaded; native app source and personal writing are excluded. `main` remains unchanged. Git deployments are disabled and the GitHub repository is not connected to this Vercel project.

The approved production command, from `website/` on `feat/type-product-site`:

```sh
vercel deploy --yes --prod --build-env SITE_URL=https://type-product-page.vercel.app --meta githubCommitRef=feat/type-product-site --meta githubCommitSha=3746fb5c57fd440c49b4ef86f985901464a086df
```

Subsequent review deployments can use `--environment preview` without `--prod`. Set the commit metadata to the source being deployed. `SITE_URL` controls canonical, Open Graph, and sitemap URLs. Search indexing remains disabled by the existing robots policy and response header; approval covered deployment, not an indexing-policy change.

## Design and content

The brief, concept scoring, art direction, motion rules, and capture safeguards are recorded in `../DESIGN.md`. Structured theme and feature content lives in `src/data/site.ts`; page-specific copy lives in `src/pages/index.astro`. Styles are in `src/styles/site.css`; the hero focus driver is in `src/motion/type.ts`.

Actual sample-only app media is in `public/media/`, with capture provenance in `PROVENANCE.md`. Fonts are self-hosted, with their source and license references in `public/fonts/README.md`. No user writing, invented testimonials, fake usage metrics, or paid plans are included. This page does not add a license to the app repository.

