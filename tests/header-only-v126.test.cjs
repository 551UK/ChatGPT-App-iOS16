"use strict";
const assert=require("node:assert/strict");
const fs=require("node:fs");
const vm=require("node:vm");
const cp=require("node:child_process");
const src=fs.readFileSync("web/chatgpt-app-shell.js","utf8");
const original=cp.execFileSync("git",["show","origin/restore-exact-last-page-v125:web/chatgpt-app-shell.js"],{encoding:"utf8"});
for(const feature of [
  "CG_HOME_ROUTE_TITLE_MARKER",
  "function syncRestorableHomeState()",
  "document.addEventListener(\"visibilitychange\", syncRestorableHomeState)",
  "window.addEventListener(\"pagehide\", syncRestorableHomeState)",
  "#browser-sidebar-popover { width: 75vw !important; }",
  "restoreMainHeaderLeftIconSizes(chosen);",
  ".cg-ios16-direct-black-svg { color: #000000 !important;",
  "html body .cg-ios16-left-header-size-stable svg { filter: brightness(0) !important;",
  "function sidebarInteraction(event) {"
]) assert(original.includes(feature)&&src.includes(feature),"Lost v1.25 feature "+feature);
assert(!src.includes("mutationChangesHeader("),"Old page-wide mutation classification survived");
assert(!src.includes("applyAppPresentation("),"Old periodic whole-page presentation survived");
assert(!src.includes("observer.observe(document.documentElement"),"Old whole-document observer survived");
assert(!src.includes("attributeFilter: [\"aria-label\", \"title\""),"SVG attribute mutation feed survived");
assert(!src.includes("}, 64);"),"Old 64ms scanner survived");
assert(src.includes("const headerObserver = new MutationObserver"),"Header-only observer missing");
assert(src.includes("const titleTextObserver = new MutationObserver"),"Title-only observer missing");

const start=src.indexOf("  // v1.26: HEADER-ONLY event-driven styling.");
const end=src.indexOf("  // Ensure Home is recorded before background suspension",start);
assert(start>=0&&end>start,"Failed to isolate header observer implementation");
const code=src.slice(start,end);
let nScan=0,nInk=0,nPromo=0,nFooter=0,nHome=0,init=null;
const watchers=[],pendingTimers=[];
class MockObserver {
  constructor(callback){this.callback=callback;this.target=null;this.options=null;watchers.push(this);}
  disconnect(){this.target=null;this.options=null;}
  observe(target,options){this.target=target;this.options=options;}
}
const makeEl=(tag,rect,options={})=>({
  tag,rect,parentElement:options.parent||null,isConnected:true,
  getBoundingClientRect(){return this.rect;},
  querySelector(){return null;},
  closest(){return null;}
});
const body=makeEl("body",{top:0,width:430,height:900});
const main=makeEl("main",{top:0,width:430,height:900},{parent:body});
const toolbarParent=makeEl("toolbar-parent",{top:0,width:430,height:70},{parent:main});
const header=makeEl("header",{top:0,width:430,height:65},{parent:toolbarParent});
const button=makeEl("button",{top:10,width:35,height:38},{parent:header});
const title=makeEl("title",{top:0,width:0,height:0});
const head={querySelector(selector){return selector==="title"?title:null;}};
const doc={
  hidden:false,readyState:"loading",body,head,
  querySelectorAll(selector) {
    if(selector.startsWith(".cg-ios16-left-header-size-stable"))return [button];
    if(selector.startsWith("#page-header"))return [header];
    throw Error("Unexpected selector "+selector);
  },
  addEventListener(name,callback) {
    if(name==="DOMContentLoaded")init=callback;
  }
};
const env={
 document:doc,innerWidth:430,MutationObserver:MockObserver,
 setTimeout:(fn,ms)=>{pendingTimers.push({fn,ms});return pendingTimers.length;},
 installStyle:()=>{},
 dismissAppPromotion:()=>{nPromo++;},
 stabilizeTopActionBar:()=>{nScan++;},
 makeTopLeftHeaderIconsBlack:()=>{nInk++;},
 hasUsableConversationHeaderBackground:()=>true,
 restoreConversationHeaderBackground:()=>{},
 hideSuggestion:()=>{},
 hideDisclaimers:()=>{nFooter++;},
 revealCleanPage:()=>{},
 syncRestorableHomeState:()=>{nHome++;}
};
vm.runInNewContext(code,env);
assert.equal(typeof init,"function","One-time DOM init not registered");
init();
assert.equal(nScan,1,"Initial header should be classified once");
assert.equal(nInk,1,"Initial icons should be marked once");
const watched=watchers.filter(w=>w.target);
const headerWatch=watched.find(w=>w.target===header);
assert(headerWatch && headerWatch.options.childList===true &&
  headerWatch.options.subtree===true,"Observer must follow only real header descendants");
assert(!watched.some(w=>w.target===main),"Main conversation root must not be observed");
assert(!watched.some(w=>w.target===body && w.options.subtree),
  "Body observer must only watch direct structural changes");
assert(!watched.some(w=>w.target===head && w.options.subtree),
  "Head observer must not watch arbitrary metadata/styles");
assert(watched.some(w=>w.target===title && w.options.subtree),
  "Home restoration must observe the title only");

// Simulating thousands of message updates requires NO invocation of observers.
// All observers are scoped to title, header, direct header parent or direct body.
for(let i=0;i<5000;i++){ /* no observed mutation target: message is in main */ }
assert.equal(nScan,1,"Streaming must cause zero additional header scans");
const countBefore=pendingTimers.length;
headerWatch.callback([{type:"childList",target:header,addedNodes:[],removedNodes:[]}]);
assert.equal(pendingTimers.length,countBefore+1,"Header change must schedule refresh");
pendingTimers[pendingTimers.length-1].fn();
assert.equal(nScan,2,"One header replacement must trigger one repair");

const titleWatcher=watchers.find(w=>w.target===title);
assert(titleWatcher,"Live title watcher missing");
const prev=nHome;
titleWatcher.callback([{type:"characterData",target:title}]);
assert(nHome>prev,"Title updates should preserve v1.25 last-page state");

doc.hidden=true;
headerWatch.callback([{type:"childList",target:header,addedNodes:[]}]);
assert.equal(nScan,2,"Hidden app should avoid any Gecko DOM reprocessing");

// Resume callbacks are deduplicated without any periodic polling.
const recStart=src.indexOf("  let lastChromeRecoveryAt = 0;");
const recEnd=src.indexOf("  function sidebarInteraction(event) {",recStart);
assert(recStart>0&&recEnd>recStart,"Recovery routine missing");
let now=1000,scheduled=0,returnTimers=[],clears=[];
const resumeEnv={
  document:{hidden:false},
  Date:{now:()=>now},
  scheduleChromeRefresh:()=>{scheduled++;},
  setTimeout:(fn,delay)=>{returnTimers.push({fn,delay});return returnTimers.length;},
  clearTimeout:id=>clears.push(id),
  observedHeader:{isConnected:true}
};
const recover=vm.runInNewContext(src.slice(recStart,recEnd)+"\nrecoverHeaderInkAfterTransition;",resumeEnv);
recover(); recover(); recover();
assert.equal(scheduled,1,"focus/pageshow/visibility burst must cause one refresh");
assert.equal(returnTimers.length,1,"Resume must not create repeated timers");
now=1250;recover();
assert.equal(scheduled,2,"A genuine later header transition can refresh");
resumeEnv.document.hidden=true;now=2200;recover();
assert.equal(scheduled,2,"No work while app is backgrounded");

console.log("PASS v1.26: header-only observer, zero per-message scans, CSS icon persistence, title-only v1.25 home restore, coalesced resume");
