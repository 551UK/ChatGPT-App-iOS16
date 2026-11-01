const {firefox}=require('playwright');
const fs=require('node:fs');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await firefox.launch();
 let release;
 try {
 const page=await browser.newPage({viewport:{width:430,height:932}});
 const source=fs.readFileSync(process.env.HEADER_SOURCE||'web/chatgpt-app-shell.js','utf8');
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 const blocked=new Promise(r=>release=r);
 await page.route('http://home.test/slow.js',async r=>{await blocked;await r.fulfill({body:'',contentType:'text/javascript'});});
 await page.route('http://home.test/',r=>r.fulfill({contentType:'text/html',body:`<!doctype html><html><head><title>Home</title><style>
 body{margin:0;background:rgb(227,227,227)} .home-header{height:64px;width:100%;display:flex;align-items:center;background:white}
 button{height:36px;border:0} .tabs{margin:auto;display:flex;background:#ccc;border-radius:30px} .tabs button{width:90px;background:transparent} .tabs button:first-child{background:white} .right{background:transparent;width:35px} svg{width:24px;height:24px}
 </style><script>${source}</script></head><body><main><div class="home-header"><div class="tabs" role="tablist"><button role="tab">Chat</button><button role="tab">Work</button></div><button class="right" aria-label="Temporary chat"><svg></svg></button></div><p>What's on your mind today?</p></main><script src="/slow.js"></script></body></html>`}));
 // Execute in the parser head, before body creation and the blocked script.
 const navigation=page.goto('http://home.test/');
 navigation.catch(()=>{});
 await page.waitForSelector('.home-header');
 // Keep DOMContentLoaded blocked: a visible Home row must already be adaptive.
 await page.waitForTimeout(150);
 const state=await page.$eval('.home-header',h=>({ready:document.readyState,bg:getComputedStyle(h).backgroundImage,base:getComputedStyle(h).backgroundColor,cut:parseFloat(h.style.getPropertyValue('--cg-ios16-topbar-cutoff')),bottom:Math.max(...Array.from(h.querySelectorAll('button')).map(b=>b.getBoundingClientRect().bottom))-h.getBoundingClientRect().top}));
 assert.equal(state.ready,'loading');
 assert(state.bg.includes('rgb(227, 227, 227)'),JSON.stringify({state,errors}));
 assert.equal(state.base,'rgba(0, 0, 0, 0)');
 assert.equal(state.cut,state.bottom);
 release();await navigation;
 await page.evaluate(()=>{const b=document.createElement('button');b.setAttribute('aria-label','Open sidebar');b.innerHTML='<svg></svg>';b.style.background='#DFEAFF';document.querySelector('.home-header').prepend(b);});
 await page.waitForTimeout(150);
 assert((await page.$eval('.home-header',h=>getComputedStyle(h).backgroundImage)).includes('rgb(223, 234, 255)'));
 assert.deepEqual(errors,[]);
 console.log('PASS: div Home header with Chat/Work and no sidebar adapts before DOMContentLoaded; selected white tab ignored; late sidebar colour updates');
 } finally {release?.(); await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
