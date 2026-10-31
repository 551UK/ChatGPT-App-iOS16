"use strict";
const {firefox}=require("playwright");
const fs=require("node:fs");
const assert=require("node:assert/strict");
const source=fs.readFileSync("web/chatgpt-app-shell.js","utf8");
const instrumented=source.replace("function refreshChrome() {",
  "function refreshChrome() { window.__chromePasses = (window.__chromePasses || 0) + 1;");
const controls=()=>`<button aria-label="Open sidebar"><span><svg viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18"/><line x1="8" y1="4" x2="8" y2="20"/></svg></span></button>
<button aria-label="New chat"><span><svg viewBox="0 0 24 24"><line x1="6" y1="18" x2="20" y2="4"/></svg></span></button>
<button aria-label="Share" class="share"><svg viewBox="0 0 24 24"><path d="M12 2L12 18"/></svg>Share</button>`;
const markup=`<!doctype html><html><head><title>Test chat</title><style>
body{margin:0;background:white;font:16px sans-serif}
header{width:100%;height:64px;display:flex;gap:22px;align-items:center;padding:0 20px;box-sizing:border-box;background:transparent}
button{width:30px;height:30px;border:0;background:none;padding:3px;color:#888;flex-shrink:0}
button span{opacity:.45}svg{width:24px;height:24px;stroke:currentColor;fill:none}
.share{margin-left:auto;width:80px;display:flex}
main{min-height:1400px}#messages{padding:20px}
textarea{position:fixed;bottom:10px;left:20px}
</style></head><body><div id="app"><main><section id="route"><header id="page-header">${controls()}</header><div id="messages"></div></section></main></div><textarea placeholder="Ask ChatGPT"></textarea></body></html>`;
(async()=>{
 const browser=await firefox.launch();
 const page=await browser.newPage({viewport:{width:430,height:932}});
 const errors=[];page.on("pageerror",e=>errors.push(e.message));
 await page.route("http://fixture.test/**",route=>route.fulfill({contentType:"text/html",body:markup}));
 await page.addInitScript({content:instrumented});
 await page.goto("http://fixture.test/c/one");
 async function verify(label) {
  const state=await page.evaluate(()=>{
   const side=document.querySelector('#page-header [aria-label="Open sidebar"]');
   const fresh=document.querySelector('#page-header [aria-label="New chat"]');
   const result=b=>({transform:getComputedStyle(b).transform,color:getComputedStyle(b).color,
     filter:getComputedStyle(b.querySelector("svg")).filter,
     opacity:getComputedStyle(b.querySelector("span")).opacity});
   return {side:result(side),fresh:result(fresh),bg:getComputedStyle(document.querySelector("#page-header")).backgroundImage};
  });
  assert.equal(state.side.transform,"matrix(1.4, 0, 0, 1.4, 0, 0)",label+" sidebar");
  assert.equal(state.fresh.transform,"matrix(1.5, 0, 0, 1.5, 0, 0)",label+" new");
  for(const b of [state.side,state.fresh]) {
   assert.equal(b.color,"rgb(0, 0, 0)",label+" colour");assert.equal(b.opacity,"1",label+" wrapper opacity");
   assert.equal(b.filter,"brightness(0)",label+" svg ink");
  }
  assert(state.bg.includes("rgb(255, 255, 255)"),label+" white strip");
 }
 await page.waitForTimeout(200);await verify("initial paint");
 // React rewrites classes and SVG, without replacing button or header.
 await page.evaluate(()=>{
  for(const b of document.querySelectorAll("#page-header button")) {
   b.className="react-replacement";
   b.removeAttribute("data-cg-left-header-icon");b.removeAttribute("data-cg-icon-role");
   b.style.color="#999";
   b.querySelector("svg").outerHTML=b.querySelector("svg").outerHTML.replace(/class="[^"]*"/g,"");
  }
 });
 await verify("immediate class/SVG replacement");
 await page.waitForTimeout(120);await verify("settled replacement");
 // Reorder controls: identity must not depend on slot/order.
 await page.evaluate(()=>{const h=document.querySelector("#page-header");h.prepend(h.querySelector('[aria-label="New chat"]'));});
 await page.waitForTimeout(100);await verify("swapped controls");
 // Replace a tall ancestor; direct compact-parent monitoring used to miss this.
 await page.evaluate(html=>{
  const old=document.querySelector("#route");const n=document.createElement("section");
  n.id="route";n.innerHTML='<header id="page-header">'+html+'</header><div id="messages"></div>';
  old.replaceWith(n);
 },controls());
 await verify("whole route replacement before recovery");
 await page.waitForTimeout(200);await verify("whole route settled");
 // A detached header can return long after bounded retries expire.
 await page.evaluate(()=>document.querySelector("#page-header").remove());
 await page.waitForTimeout(3500);
 await page.evaluate(html=>{
  const wrapper=document.createElement("div");
  wrapper.innerHTML='<header id="page-header">'+html+'</header>';
  document.querySelector("#route").prepend(wrapper);
 },controls());
 await page.waitForTimeout(160);
 await verify("header restored after long structural gap");
 assert(await page.$eval("#page-header button",b=>b.classList.contains("cg-ios16-left-header-size-stable")),
   "structural recovery must rediscover header, not just rely on CSS");
 // No pair prerequisite: one left icon can hydrate late into a connected header.
 await page.evaluate(html=>{
  history.pushState(null,"","/c/two");document.title="Second chat";
  const h=document.querySelector("#page-header");h.innerHTML="";
  setTimeout(()=>{h.innerHTML=html;},900);
 },controls());
 await page.waitForTimeout(1000);await verify("delayed hydration");
 // Unlabelled replacement still needs the geometry/shape fallback and an
 // attribute-only React rewrite must be repaired even with no child mutation.
 await page.evaluate(()=>{
  const b=document.querySelector('#page-header [aria-label="New chat"]');
  b.removeAttribute("aria-label");b.className="";b.removeAttribute("data-cg-left-header-icon");
 });
 await page.waitForTimeout(150);
 const unlabeled=await page.evaluate(()=>{
  const b=document.querySelectorAll("#page-header button")[1];
  return {transform:getComputedStyle(b).transform,filter:getComputedStyle(b.querySelector("svg")).filter};
 });
 assert.equal(unlabeled.transform,"matrix(1.5, 0, 0, 1.5, 0, 0)");
 assert.equal(unlabeled.filter,"brightness(0)");
 // Restore label, then ensure sidebar controls don't get header scaling.
 await page.evaluate(()=>{
  document.querySelectorAll("#page-header button")[1].setAttribute("aria-label","New chat");
  const panel=document.createElement("div");panel.id="browser-sidebar-popover";
  panel.innerHTML='<header><button aria-label="New chat"><svg></svg></button></header>';
  document.body.append(panel);
 });
 await page.waitForTimeout(150);
 assert.equal(await page.$eval("#browser-sidebar-popover button",b=>getComputedStyle(b).transform),"none");
 await page.evaluate(()=>document.querySelector("#browser-sidebar-popover").remove());
 // Wait for bounded navigation recovery to finish, then stream actual mutations.
 await page.waitForTimeout(3400);
 const before=await page.evaluate(()=>window.__chromePasses);
 await page.evaluate(()=>{
  const feed=document.querySelector("#messages");
  for(let i=0;i<5000;i++){const p=document.createElement("p");p.textContent="token "+i;feed.append(p);}
 });
 await page.waitForTimeout(250);
 assert.equal(await page.evaluate(()=>window.__chromePasses),before,"message updates must trigger zero chrome scans");
 // No self-sustaining attribute observer loop from our own style writes.
 await page.waitForTimeout(300);
 assert.equal(await page.evaluate(()=>window.__chromePasses),before,"styling must not retrigger itself");
 // Appearance changes must update both the colour and exact painted edge.
 async function appearance(expected,label) {
  await page.waitForTimeout(120);
  const state=await page.evaluate(()=>{
   const h=document.querySelector('#page-header'),r=h.getBoundingClientRect();
   const bottom=Math.max(...Array.from(h.querySelectorAll('button')).map(b=>b.getBoundingClientRect().bottom));
   return {bg:getComputedStyle(h).backgroundImage,cutoff:parseFloat(h.style.getPropertyValue('--cg-ios16-topbar-cutoff')),edge:bottom-r.top};
  });
  assert(state.bg.includes(expected),label+' colour: '+state.bg);
  assert(Math.abs(state.cutoff-state.edge)<.1,label+' bottom aligns with buttons');
 }
 await page.evaluate(()=>{const s=document.createElement('style');s.id='appearance';s.textContent='header button {background:var(--appearance-bg)}';document.head.append(s);document.documentElement.style.setProperty('--appearance-bg','#DFEAFF');});
 await appearance('rgb(223, 234, 255)','light blue');
 await page.evaluate(()=>document.documentElement.style.setProperty('--appearance-bg','#ffe0eb'));
 await appearance('rgb(255, 224, 235)','live pink');
 await page.evaluate(()=>document.querySelector('#appearance').textContent='header button {background:#d0eed0}');
 await appearance('rgb(208, 238, 208)','stylesheet replacement');
 await page.evaluate(()=>{document.querySelector('#appearance').remove();document.body.style.background='#DFEAFF';});
 await appearance('rgb(223, 234, 255)','transparent controls use page');
 await page.evaluate(()=>{history.pushState(null,'','/');document.title='Home';document.querySelector('#page-header').innerHTML=document.querySelector('#page-header button').outerHTML;});
 await appearance('rgb(223, 234, 255)','home single button');
 await page.waitForTimeout(3400);
 const settled=await page.evaluate(()=>window.__chromePasses);
 await page.waitForTimeout(300);
 assert.equal(await page.evaluate(()=>window.__chromePasses),settled,'theme refresh must settle');
 assert.deepEqual(errors,[]);
 console.log("PASS: Firefox header navigation, class/SVG replacement, delayed hydration, swapped icons, unlabelled fallback, sidebar exclusion, white strip and 5000 real message mutations");
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});
