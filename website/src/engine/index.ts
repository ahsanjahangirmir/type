import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import Lenis from 'lenis';
gsap.registerPlugin(ScrollTrigger);
export { gsap, ScrollTrigger };
export function start(onPage: () => void | (() => void)) {
  const media = gsap.matchMedia();
  media.add({ motion: '(prefers-reduced-motion: no-preference)', reduce: '(prefers-reduced-motion: reduce)' }, context => {
    let lenis: Lenis | undefined;
    const tick = (time: number) => lenis?.raf(time * 1000);
    if (context.conditions?.motion) {
      lenis = new Lenis({ duration: 1.05, smoothWheel: true, anchors: true });
      lenis.on('scroll', ScrollTrigger.update);
      gsap.ticker.add(tick);
      gsap.ticker.lagSmoothing(0);
    }
    const cleanup = onPage();
    document.fonts.ready.then(() => ScrollTrigger.refresh());
    return () => { cleanup?.(); gsap.ticker.remove(tick); lenis?.destroy(); };
  });
  window.addEventListener('pagehide', () => media.revert(), { once: true });
  // Restore the lifecycle when the browser returns this page from its back-forward cache.
  window.addEventListener('pageshow', event => { if (event.persisted) location.reload(); });
}
