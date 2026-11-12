import sharp from 'sharp';
import fs from 'node:fs/promises';
const input = process.argv[2] || '/tmp/type-website-capture/media';
const out = 'public/media';
await fs.mkdir(out,{recursive:true});
// Crops are authentic app pixels. The top 100px are omitted to exclude the OS
// screen-sharing indicator; no app UI or manuscript content is synthesized.
for (const theme of ['paper','sepia','slate']) {
 await sharp(`${input}/${theme}-screen.png`).extract({left:0,top:100,width:2480,height:1320}).resize({width:1984}).webp({quality:88}).toFile(`${out}/${theme}.webp`);
}
for(const [name,file] of [['paper-editor','paper'],['focus-editor','focus']]) {
 await sharp(`${input}/${file}-screen.png`).extract({left:650,top:190,width:1740,height:1170}).resize({width:1500}).webp({quality:90}).toFile(`${out}/${name}.webp`);
}
await sharp(`${input}/paper-screen.png`).extract({left:934,top:15,width:845,height:80}).webp({quality:92}).toFile(`${out}/toolbar.webp`);
await sharp(`${input}/paper-screen.png`).extract({left:20,top:100,width:530,height:620}).resize({width:430}).webp({quality:90}).toFile(`${out}/sidebar.webp`);
await sharp(`${input}/paper-screen.png`).extract({left:20,top:100,width:530,height:1420}).webp({quality:90}).toFile(`${out}/notebooks.webp`);
await sharp('public/favicon.svg').resize(180,180).png().toFile('public/apple-touch-icon.png');
