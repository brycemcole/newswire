const {chromium}=require('playwright');
const {spawn}=require('node:child_process');
const {mkdir}=require('node:fs/promises');
const assert=require('node:assert/strict');
(async()=>{
const root=require('node:path').resolve(__dirname,'..');
const out=root+'/screenshots/web-navigation';
await mkdir(out,{recursive:true});
const server=spawn(process.execPath,[root+'/scripts/preview-web.mjs'],{stdio:'ignore'});
let browser;
try {
for(let i=0;i<40;i++){try{await fetch('http://127.0.0.1:8800');break;}catch{await new Promise(r=>setTimeout(r,100));}}
browser=await chromium.launch(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? {executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE} : {});
for(const [name,viewport] of [['desktop',{width:1280,height:800}],['phone',{width:390,height:844}]]){
const page=await browser.newPage({viewport});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
await page.route('**/v1/stories?*',async route=>{const resp=await route.fetch();const data=await resp.json();for(const s of data.stories)s.body+='\n'+('Long synthetic report for scroll verification.\n'.repeat(60));await route.fulfill({response:resp,json:data});});
await page.goto('http://127.0.0.1:8800');await page.click('#connect');await page.fill('#token','preview-only');await page.click('button[type=submit]');await page.waitForSelector('.story');
assert.equal(await page.locator('.story').count(),50);
await page.locator('.story').first().click();
assert.equal(await page.locator('#report-prev').isDisabled(),true);
assert.match(await page.locator('#report-position').innerText(),/1 OF 50 LOADED/i);
await page.click('#report-next');
assert.match(await page.locator('.report h2').innerText(),/dispatch 02/i);
assert.equal(await page.evaluate(()=>document.activeElement.id),'report-next');
await page.screenshot({path:out+'/newswire-'+name+'-navigation.png'});
{
await page.locator('#detail').evaluate(el=>el.scrollTop=500);
const b=await page.locator('#report-next').boundingBox();assert(b.y>=0&&b.y<viewport.height);
if(name==='phone')assert(b.height>=44);
await page.click('#report-next');assert.equal(await page.locator('#detail').evaluate(el=>el.scrollTop),0);
}
await page.locator('#report-next').focus();await page.keyboard.press('k');
assert.equal(await page.evaluate(()=>document.activeElement.id),'report-next');
await page.click('#report-close');
assert.equal(await page.locator('#detail').evaluate(el=>el.classList.contains('open')),false);
assert.equal(await page.evaluate(()=>document.activeElement.dataset.id),'preview-1');
await page.locator('.story').nth(49).click();assert.equal(await page.locator('#report-next').isDisabled(),true);
await page.click('#report-close');
await page.click('#load-more');await page.waitForFunction(()=>document.querySelectorAll('.story').length===55);
await page.locator('.story').nth(49).click();assert.equal(await page.locator('#report-next').isDisabled(),false);
await page.click('#report-next');assert.match(await page.locator('#report-position').innerText(),/51 OF 55 LOADED/i);
await page.click('#report-close');await page.click('[data-category="markets"]');await page.waitForFunction(()=>document.querySelectorAll('.story').length===27);
assert.equal(await page.locator('.report').count(),0);
await page.locator('.story').first().click();assert.match(await page.locator('#report-position').innerText(),/1 OF 27 LOADED/i);
await page.click('#report-close');await page.selectOption('#priority','breaking');await page.waitForFunction(()=>document.querySelectorAll('.story').length===0);
assert.equal(await page.locator('.report').count(),0);assert.deepEqual(errors,[]);
console.log('PASS '+name+': navigation, boundaries, scroll, keyboard focus, pagination, filters, empty feed');
await page.close();
}
}finally{await browser?.close();server.kill();}
})().catch(e=>{console.error(e);process.exit(1)});
