// Protect the successful v1.08 75vw sidebar against accidental
// chat-title scaling when sidebar entries scroll through the top screen band.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('web/chatgpt-app-shell.js', 'utf8');
assert(source.includes('#browser-sidebar-popover { width: 75vw !important; }'), 'sidebar width must remain 75vw');
const start = source.indexOf('  function stabilizeTopActionBar() {');
const end = source.indexOf('\n  function hideSuggestion() {',start);
assert(start>=0&&end>start, 'header routine absent');
const fn=source.slice(start,end);
const controls=[];
function element(name,x,y,w,h,{sidebar=false,svg=true,label=''}={}) {
  const cls=new Set(), attrs={};
  const el={
    name,
    classList:{ add(v){cls.add(v)},remove(v){cls.delete(v)}, contains(v){return cls.has(v)} },
    getBoundingClientRect(){return {left:x,top:y,width:w,height:h,bottom:y+h,right:x+w}},
    querySelector(sel){return svg&&sel==='svg'?{}:null},
    closest(sel){return sidebar&&sel.includes('#browser-sidebar-popover')?{}:null},
    contains(other){return this===other},
    getAttribute(k){return attrs[k]??null},
    setAttribute(k,v){attrs[k]=v},
    removeAttribute(k){delete attrs[k]},
    style:{removeProperty(){}},
    dataset:{},
    label
  };
  controls.push(el);
  return el;
}
// Chat entries wrongly matched prior to v1.10 when they reach the screen top.
const history1=element('chat title one',22,16,90,42,{sidebar:true,svg:true,label:'Long chat title'});
const history2=element('chat title two',66,17,90,42,{sidebar:true,svg:true,label:'Another chat title'});
const textRow=element('text-only row',18,21,78,38,{label:'Message'});
const sidebarIcon=element('real sidebar icon',14,15,38,38);
const newChatIcon=element('real new chat',66,15,38,38);
const ctx={
  innerWidth:430,innerHeight:932, window:{location:{pathname:'/'}},
  document:{
    querySelectorAll(sel){
      if(sel==='button, [role=\'button\'], a')return controls;
      if(sel==='.cg-ios16-topbar-control')return controls.filter(x=>x.classList.contains('cg-ios16-topbar-control'));
      if(sel==='.cg-ios16-home-topbar-control')return controls.filter(x=>x.classList.contains('cg-ios16-home-topbar-control'));
      if(sel==='[data-cg-icon-role]')return controls.filter(x=>x.getAttribute('data-cg-icon-role'));
      if(sel==='.cg-ios16-solid-topbar')return [];
      throw Error('Unexpected selector '+sel);
    }
  },
  getComputedStyle(){return {display:'block',visibility:'visible',opacity:'1'}},
  normalizedText(el){return el.label||''},
  iconIdentity(el){return el.name==='real sidebar icon'?'sidebar':el.name==='real new chat'?'new':''}
};
vm.runInNewContext(fn+'\nstabilizeTopActionBar;',ctx)();
for(const el of [sidebarIcon,newChatIcon])assert(el.classList.contains('cg-ios16-topbar-control'), el.name+' lost intended icon scaling');
for(const el of [history1,history2,textRow])assert(!el.classList.contains('cg-ios16-topbar-control'),el.name+' enlarged unexpectedly');
console.log('PASS: only actual top header icons scaled; chat sidebar titles and message text ignored.');
