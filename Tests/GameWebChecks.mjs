import {createRequire} from 'node:module';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
const [root,modules]=process.argv.slice(2);
const {chromium}=createRequire(`${modules}/placeholder.js`)('playwright');
for(const dimension of ['2D','3D']) {
  const folder=`${root}/${dimension}-js`;
  const server=spawn(process.execPath,[`${folder}/serve.mjs`],{env:{...process.env,NETVISTA_GAME_PORT:'0'}});
  let browser;
  try {
    const url=await new Promise((resolve,reject)=>{server.stdout.on('data',data=>{const match=String(data).match(/http:\/\/127\.0\.0\.1:\d+/);if(match)resolve(match[0]);});server.on('error',reject);server.on('exit',code=>reject(Error(`Server exited ${code}`)));});
    browser=await chromium.launch({headless:true,...(process.env.NETVISTA_TEST_BROWSER?{executablePath:process.env.NETVISTA_TEST_BROWSER}:{})});const page=await browser.newPage({viewport:{width:960,height:600}});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(url);
    await page.waitForFunction(()=>document.querySelector('#hud').textContent.includes('Score:'));
    await page.keyboard.down('w');await page.waitForTimeout(500);await page.keyboard.up('w');
    await page.screenshot({path:`${root}/${dimension}-web.png`});
    assert.equal(await page.locator('canvas').count(),1);assert.deepEqual(errors,[]);
    await page.getByRole('button',{name:'Restart'}).click();
    assert(!(await page.locator('#hud').textContent()).includes('Could not start'));
    console.log(`PASS: ${dimension} exported Three.js game loads, renders, receives input and restarts without JS errors`);
  } finally {await browser?.close();server.kill();}
}
