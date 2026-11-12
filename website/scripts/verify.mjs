import { chromium } from 'playwright';
import fs from 'node:fs/promises';
const url=process.argv[2]||'http://127.0.0.1:4400';
const browser=await chromium.launch({headless:true});
const failures=[];const checks=[];
function assert(ok,label){checks.push({label,pass:!!ok});if(!ok)failures.push(label)}
const page=await browser.newPage({viewport:{width:1440,height:1000}});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
await page.goto(url);await page.waitForTimeout(1500);
await page.locator('.focus-switch').click();
assert(await page.locator('.focus-switch').getAttribute('aria-pressed')==='true','Focus mode activates');
assert(await page.locator('.focus-figure').evaluate(el=>el.classList.contains('focus-on')),'Actual focus capture appears');
await page.locator('.focus-switch').click();
assert(await page.locator('.focus-switch').getAttribute('aria-pressed')==='false','Focus mode reverses');
for(const theme of ['sepia','slate','paper']){
 await page.locator(`[data-theme-choice=${theme}]`).click();
 assert(await page.locator(`[data-theme-image=${theme}]`).evaluate(el=>el.classList.contains('is-active')&&el.complete&&el.naturalWidth>0),`${theme} preview uses a loaded real capture`);
 assert(await page.locator('[data-theme-choice][aria-pressed=true]').count()===1,`${theme} has one selected control`);
}
await page.locator('[data-theme-choice=slate]').click();await page.waitForTimeout(600);await page.locator('.themes-section').screenshot({path:'.shots-pass2/theme-slate.png'});
await page.locator('[data-theme-choice=sepia]').click();await page.waitForTimeout(600);await page.locator('.themes-section').screenshot({path:'.shots-pass2/theme-sepia.png'});
await page.locator('.focus-switch').click();await page.waitForTimeout(650);await page.locator('.focus-section').screenshot({path:'.shots-pass2/focus-active.png'});
for(const summary of await page.locator('.feature-list summary').all()){
 await summary.click();assert(await summary.evaluate(el=>el.parentElement.open),'Feature disclosure opens');await summary.click();
}
assert(await page.locator('a[href="https://github.com/ahsanjahangirmir/type"]').count()===3,'All three source CTAs use the actual repository');
for(const width of [390,768,1024,1440,1920]){
 await page.setViewportSize({width,height:900});await page.goto(url);await page.waitForTimeout(500);
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`No overflow at ${width}px`);
}
const reduced=await browser.newPage({viewport:{width:390,height:844},reducedMotion:'reduce'});
await reduced.goto(url);await reduced.waitForTimeout(700);
assert(await reduced.locator('.pin-spacer').count()===0,'Reduced motion has no pinned section');
assert(await reduced.locator('h1').isVisible(),'Reduced motion headline is visible');
const nojs=await browser.newPage({javaScriptEnabled:false,viewport:{width:390,height:844}});
await nojs.goto(url);assert(await nojs.locator('h1').isVisible(),'No-JavaScript headline visible');assert(await nojs.locator('a[href*=github]').first().isVisible(),'No-JavaScript GitHub CTA usable');
const response=await page.goto(`${url}/this-page-is-unwritten`);assert(response.status()===404,'Designed missing page returns HTTP 404');assert(await page.locator('h1').textContent()==='Nothing here.Yet.','Designed missing page renders');
assert(errors.length===0,'No browser runtime errors');
await browser.close();
await fs.writeFile('.shots-pass2/functional.json',JSON.stringify({url,checks,errors,failures},null,2));
console.log(JSON.stringify({passed:checks.length-failures.length,total:checks.length,failures,errors},null,2));if(failures.length)process.exitCode=1;
