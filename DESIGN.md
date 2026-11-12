# Type product page

## Brief and agreed scope
A free, open source, native macOS writing application for everyone who opens a MacBook to write and keep their thoughts organized. The visitor must remember that fluid writing should not be a paid luxury. Primary action: open the actual GitHub repository. One product page only, plus a useful 404; no documentation site, waitlist, invented testimonials, download claims, or additional marketing pages.

Reference: https://grail-app.com/. Borrow scale, depth, and choreographed continuity, not its assets or layouts. User selected the disappearing interface and strongly experimental motion. Capture real Type under several themes. Existing app data and working changes must be preserved.

## Three concepts (originality / fit / feasibility / portability; 1–5, lower portability is better)
1. The disappearing interface (process): the website makes room for a thought as the surrounding tools recede. Anchor: Type's auto-hiding toolbar, paragraph focus and hideable sidebar. Signature: a spatial scatter of actual interface fragments converges into a real writing window, then recedes during a focus demonstration. Emotion: space opening up. Screenshot: enormous literary typography above a tilted real Mac window. Scores: 4 / 5 / 5 / 2. Selected: demonstrates the actual promise through the behavior of the page.
2. The living manuscript (material): the website is a draft that becomes readable as Markdown resolves. Anchor: live Markdown and hidden syntax. Signature: annotated draft to finished text. Emotion: discovery. Screenshot: half-marked-up, half-resolved manuscript. Scores: 4 / 4 / 4 / 3. Rejected: puts Markdown literacy ahead of universal writing.
3. The writing instrument (identity): Type is a tactile everyday tool, with typography and sound functioning as its material. Anchor: native editor and six synthesized sound profiles. Signature: visitor-controlled keyboard sound study. Emotion: tactile delight. Screenshot: macro app detail beside large typographic specimen. Scores: 3 / 4 / 4 / 3. Rejected as primary: risks making writing feel like a specialist hobby.

## Concept card
Idea: A little less interface. A lot more room to write.
Metaphor: A desk cleared for a thought.
Signature: One scroll-driven spatial scene: real interface pieces move outward while a writing window becomes level and central. A second, short focus study dims the surrounding prose.
Emotion: Relief, curiosity, possibility.
Motion verb: Recede.
Screenshot: “Room to write.” in large high-contrast serif, a lilac caret, and a real Type window suspended over a graphite ground.

## Stack
Astro, TypeScript, plain CSS, GSAP and Lenis. Static single-page product storytelling benefits from HTML-first delivery and a small motion bundle. No WebGL: CSS 3D transforms provide depth without a rendering context or canvas accessibility/performance cost.

## System
Palette: ground #171817 (graphite), ink #f0f0e9 (writing paper), muted #b7b9af (pencil), line #3c3e39, accent #d9c8ed (soft selection), curtain #171817. Light sections invert ground and ink locally as designed blocks; no global half-transition contrast states.
Type: Boska 400/500 (Fontshare, literary display) and Switzer 400/500/600 (Fontshare, native-feeling UI). Font files self-hosted with source/license retained. Display tracking -0.045em, leading .87–.98. Body 16–18px/1.55. Labels 12–14px with AA contrast. No ornamental uppercase labels per section.
Grid: 12 columns, 32–56px outer gutter, major lines at columns 1/5/9. At 390px: four columns, 20px gutter, independently composed hero and shortened spatial travel. Alternating dense scene / open statement / asymmetric product study / index / full-width finale.
Shape: media radius 12px, control radius 999px. Actual app window retains authentic native corners.
Motion: one GSAP clock drives Lenis and spatial scene. power3/expo family. Micro 250–400ms, large 1–1.2s, scrub .7. A small shared idle offset moves the hero scene, paused offscreen and absent under reduced motion. No theatrical loader, native cursor visible. Under reduced motion every screenshot and word is visible, no pinning/scrubbing/smooth scroll. Every action has hover, focus, press behavior.

## Composition
Hero / spatial poster:
[Type]                   [The app] [The details] [GitHub ↗]
[Free and open source macOS writing app]
[             Room to                                 ]
[                    write.                            ]
[small promise]       [real window, fragments] [free seal]
[Explore Type ↓]                                      [macOS 26+]

Focus / sticky short narrative:
[The app gets out of your way.] [Real focused screenshot]
[short explanation + toggle]   [unfocused/focused visual states]

Themes / asymmetric gallery:
[Feels like your kind of place.]
[Paper / Sepia / Slate selector] [large actual theme capture]
[theme-specific note]           [caption]

Organization / offset paired study:
[real sidebar crop]       [A home for every thought.]
                         [folders, Markdown, auto-save facts]

Details / compact indexed feature list:
[Small things. Thought through.] [Markdown / Sound / Outline / Export]

Open source / finale:
[Writing is for everyone.]
[No subscription. No locked door.]
[Open Type on GitHub ↗]          [Free to use. Open source. Yours.]
[large Type wordmark]            [macOS 26+ / source / back to top]

## Genericness test
Rejected a centered headline over a gradient, equal feature cards, simulated screenshot HTML, artificial paid-tier comparisons, and gratuitous WebGL. The motion derives from actual auto-hiding chrome. Theme controls change actual captured media, not a painted fake editor. The free/open-source statement is the narrative conclusion and is visible from the first screen.

## Capture safety
Build a copy of the current source in /tmp/type-website-capture. Override bundle identifier to com.ajm.type.websitecapture. Use an explicitly supplied /tmp library populated only with original sample prose. Launch preference overrides are volatile and the app source already prevents their persistence. Deterministic page selection is patched only in the temporary source copy. Never launch the installed Type, touch the user's library, modify the user's defaults, or terminate their app. Track hashes of preexisting repository files before work and compare afterward. App source changes already present belong to the user and are excluded from website commits.

## Delivery
Branch: feat/type-product-site. Website in website/. Vercel CLI Preview deployment only; never --prod. Original user instruction authorizes this deployment. No GitHub integration or push required for CLI deployment. Preview pages should be noindex; sitemap/OG/canonical derive from VERCEL_URL. Two production QA passes, fresh independent screenshot critic each pass. Ratings are independent estimates, not an Awwwards award.

## Implementation refinement
The hero now pins briefly while its one focus variable recedes the headline and interface fragments, levels the actual window, and brings the writing surface forward. Phone treatment uses a shorter travel and pin distance. Reduced motion has no pin. This makes the selected signature an experienced transition rather than only a decorative tilted screenshot.

Capture correction: an initial native app-name resolution observed an earlier temporary build's restored real-library view. No UI edits or published captures were made from that view. The disposable source was hardened to override libraryPath unconditionally and given a distinct display name before capture continued. All published media was inspected to contain only sample writing. No user app code was changed.
