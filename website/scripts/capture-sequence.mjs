import { chromium } from 'playwright';
import fs from 'node:fs/promises';
await fs.mkdir('.shots-final',{recursive:true});const browser=await chromium.launch({headless:true});
for(const [name,width,height] of [['desktop',1440,1000],['mobile',390,844]]){
 const page=await browser.newPage({viewport:{width,height}});await page.goto('http://127.0.0.1:4400/');await page.waitForTimeout(1400);
 const start=await page.locator('.hero').evaluate(el=>el.getBoundingClientRect().top+scrollY);
 for(let i=0;i<5;i++){
  await page.evaluate(y=>window.scrollTo({top:y,behavior:'instant'}),start+height*(width<600?.55:.9)*i/4);await page.waitForTimeout(1050);await page.screenshot({path:`.shots-final/hero-${name}-${i}.png`});
 }
 await page.locator('.organization').scrollIntoViewIfNeeded();await page.waitForTimeout(500);await page.locator('.organization').screenshot({path:`.shots-final/organization-${name}.png`});
 // Traverse the entire document to load authentic below-fold media before a full-page shot.
 await page.evaluate(()=>document.querySelectorAll('img').forEach(img=>img.loading='eager'));await page.waitForFunction(()=>[...document.images].every(img=>img.complete));
 await page.evaluate(()=>window.scrollTo({top:0,behavior:'instant'}));await page.waitForTimeout(1200);await page.screenshot({path:`.shots-final/full-${name}.png`,fullPage:true});await page.close();
}
await browser.close();
