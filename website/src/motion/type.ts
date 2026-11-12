import { gsap } from '../engine';
import { site } from '../data/site';
export function setupPage() {
  const disposers: (() => void)[] = [];
  const listen = (element: Element, name: string, handler: EventListener) => {
    element.addEventListener(name, handler);
    disposers.push(() => element.removeEventListener(name, handler));
  };
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const focusButton = document.querySelector<HTMLButtonElement>('.focus-switch');
  if (focusButton) listen(focusButton, 'click', () => {
    const on = focusButton.getAttribute('aria-pressed') !== 'true';
    focusButton.setAttribute('aria-pressed', String(on));
    focusButton.querySelector('[data-focus-label]')!.textContent = on ? 'Focus mode is on' : 'Try focus mode';
    document.querySelector('.focus-figure')?.classList.toggle('focus-on', on);
    document.querySelector('#focus-image > img')?.setAttribute('alt', on ? 'Type’s focus mode dims the surrounding paragraphs and keeps the current paragraph clear.' : 'Type editor showing the original sample manuscript with all paragraphs visible.');
  });
  document.querySelectorAll<HTMLButtonElement>('[data-theme-choice]').forEach(button => {
    listen(button, 'click', () => {
      const id = button.dataset.themeChoice;
      document.querySelectorAll('[data-theme-choice]').forEach(el => el.setAttribute('aria-pressed', String(el === button)));
      document.querySelectorAll<HTMLElement>('[data-theme-image]').forEach(el => {
        const active = el.dataset.themeImage === id;
        el.classList.toggle('is-active', active);
        if (active) el.removeAttribute('aria-hidden'); else el.setAttribute('aria-hidden', 'true');
      });
      const gallery = document.querySelector<HTMLElement>('.theme-gallery');
      if (gallery) gallery.dataset.activeTheme = id;
      document.querySelector('[data-theme-note]')!.textContent = site.themes.find(theme => theme.id === id)!.note;
    });
  });
  if (!reduced) {
    const phone = matchMedia('(max-width:600px)').matches;
    gsap.from('.hero h1', { y: 30, opacity: .1, duration: 1.2, ease: 'expo.out' });
    gsap.from('.hero-topline, .hero-bottom', { opacity: 0, duration: 1, delay: .15 });
    // Focus is the single driver. Scroll removes the surrounding interface, and idle motion
    // is multiplied by the same state so the scene becomes still as it clears.
    const state = { focus: 0 };
    const windowEl = document.querySelector('.hero-window');
    const toolbar = document.querySelector('.fragment-toolbar');
    const sidebar = document.querySelector('.fragment-sidebar');
    const stamp = document.querySelector('.free-stamp');
    const scene = document.querySelector('.scene-plane');
    gsap.set(windowEl, {rotation:-7,rotationY:-15,rotationX:12});
    gsap.set(toolbar, {rotation:9,rotationY:-20});
    gsap.set(sidebar, {rotation:11,rotationY:20});
    const setWindow = gsap.quickSetter(windowEl, 'y', 'px');
    const render = (time: number) => {
      if (!sceneVisible) return;
      const p = state.focus;
      setWindow(-p * (phone ? 100 : 210) + Math.sin(time * .7) * 5 * (1-p));
      gsap.set(windowEl, { rotation: -7 + p*7, rotationY: -15*(1-p), rotationX:12*(1-p), scale:1+p*(phone ? .08 : .3), x:-p*(phone ? 30 : 100), clipPath:`inset(0 0 0 ${p*22.4}% round 11px)` });
      gsap.set(toolbar, { x: p*(phone ? 80 : 210), y:p*95, opacity:1-p });
      gsap.set(sidebar, { x:-p*(phone ? 70 : 150), y:p*45, opacity:1-p });
      gsap.set(stamp, { rotation:13+Math.sin(time*.5)*4, opacity:1-p });
      gsap.set('.hero h1', { y:-p*(phone ? 50 : 140), opacity:1-p });
    };
    let sceneVisible = true;
    const observer = new IntersectionObserver(entries => { sceneVisible = entries[0].isIntersecting; }, { rootMargin: '100px' });
    if (scene) observer.observe(scene);
    gsap.ticker.add(render);
    gsap.to(state, { focus:1, ease:'none', scrollTrigger:{trigger:'.hero', start:'top top',end:() => `+=${innerHeight * (phone ? .55 : .9)}`,pin:innerHeight>=750,invalidateOnRefresh:true,scrub:.7} });
    // Only the app demonstration moves; headings remain readable in their final layouts.
    gsap.from('.product-surface img', { y:45, rotation:2, scale:.96, ease:'none',scrollTrigger:{trigger:'.product-surface',start:'top 95%',end:'top 30%',scrub:.7} });
    disposers.push(() => { gsap.ticker.remove(render); observer.disconnect(); });
  }
  return () => disposers.forEach(dispose => dispose());
}
