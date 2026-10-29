"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const cp = require("node:child_process");
const script = fs.readFileSync("web/chatgpt-app-shell.js","utf8");
const stable = cp.execFileSync("git",["show","origin/best-known-v1.24:web/chatgpt-app-shell.js"],{encoding:"utf8"});

for (const css of [
  "#browser-sidebar-popover { width: 75vw !important; }",
  ".cg-ios16-direct-black-svg { color: #000000 !important;",
  ".cg-ios16-left-header-size-stable svg { filter: brightness(0) !important;",
  ".cg-ios16-share-control-stable { transform: scale(1.30) !important;"
]) {
  assert(stable.includes(css) && script.includes(css), "Known-good CSS lost: "+css);
}
assert(script.includes("}, 160);"),"Full document refresh must be throttled to 160ms");
assert(script.includes("for (const delay of [160, 600, 1600, 3200])"),"Late resume recovery missing");
assert(!script.includes("for (const delay of [120, 360, 800, 1600, 3200])"),"Duplicate old recovery burst still present");

const observerStart = script.indexOf("  function isChatContentMutation(mutation) {");
const observerEnd = script.indexOf("  observer.observe(document.documentElement, {", observerStart);
assert(observerStart > 0 && observerEnd > observerStart, "Message-only mutation filter missing");
let observe = null, scheduled=[], promotions=0, hidden=false;
const observerVM = {
  document: {get hidden(){return hidden}},
  mutationChangesHeader: mutations => mutations.some(m=>m.isHeader === true),
  dismissAppPromotion: ()=>{promotions++;},
  schedule: value => scheduled.push(value),
  MutationObserver: class {
    constructor(fn) { observe=fn; }
  }
};
vm.runInNewContext(script.slice(observerStart,observerEnd),observerVM);
const message = {target:{nodeType:1,closest:()=>({})},isHeader:false};
const other = {target:{nodeType:1,closest:()=>null},isHeader:false};
const header = {target:{nodeType:1,closest:()=>null},isHeader:true};
observe([message,message,message]);
assert.equal(scheduled.length,0,"Streaming updates must not trigger full DOM scans");
assert.equal(promotions,0,"Streaming must not rescan promotions");
observe([message,other]);
assert.deepEqual(scheduled,[false],"Other UI changes should run an ink-only update");
observe([header]);
assert.deepEqual(scheduled,[false,true],"Header updates must still run full refresh");
hidden=true;observe([header]);
assert.equal(scheduled.length,2,"Hidden app must not scan the document");

const recoveryStart = script.indexOf("  let inkRecoveryTimers = [];");
const recoveryEnd = script.indexOf("  function sidebarInteraction(event) {", recoveryStart);
assert(recoveryStart > 0 && recoveryEnd > recoveryStart,"Resume recovery handler missing");
let clock=1000, scans=0, backgrounds=0, frames=[], timers=[], clears=[];
const recoveryVM = {
  Date: {now:()=>clock},
  document:{hidden:false},
  makeTopLeftHeaderIconsBlack:()=>scans++,
  hasUsableConversationHeaderBackground:()=>true,
  restoreConversationHeaderBackground:()=>backgrounds++,
  clearTimeout: id=>clears.push(id),
  setTimeout:(callback,delay)=>{timers.push({callback,delay});return timers.length;},
  requestAnimationFrame:callback=>{frames.push(callback);}
};
const recover=vm.runInNewContext(script.slice(recoveryStart,recoveryEnd)+"\nrecoverHeaderInkAfterTransition;",recoveryVM);
recover();
recover(); // pageshow/focus delivered together
assert.equal(scans,1,"Duplicate resume events must coalesce");
assert.equal(timers.length,4,"Exactly one limited set of delayed checks expected");
assert.equal(frames.length,1,"Only one requested frame scan expected");
assert.equal(backgrounds,0,"Healthy white strip must not be rebuilt");
frames[0]();
assert.equal(scans,2);
clock=1300; recover();
assert.equal(scans,3,"Separate later transition should still refresh icons");
assert.equal(timers.length,8);
recoveryVM.document.hidden=true;
clock=2000; recover();
assert.equal(scans,3,"Background app must not execute recovery scans");
console.log("PASS v1.25: streaming ignored, header changes still refresh, resume events coalesce, original v1.24 icon/Share/sidebar CSS preserved");
