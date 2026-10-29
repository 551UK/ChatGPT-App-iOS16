// Regression for ChatGPT icon greying at bottom during streaming and on chat re-entry.
// The real v1.09 function is evaluated under mocked browser geometry.
const fs = require('fs');
const vm = require('vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('web/chatgpt-app-shell.js', 'utf8');
const first = source.indexOf('  function makeTopLeftHeaderIconsBlack() {');
const last = source.indexOf('\n  let revealed = false;', first);
assert(first >= 0 && last > first, 'icon selector must exist');
const routine = source.slice(first, last);
assert(source.includes('#browser-sidebar-popover { width: 75vw !important; }'), 'confirmed v1.08 sidebar fix retained');

const state = [];
function icon(name, x) {
  const css = new Set();
  const wrapperCss = new Set();
  const wrapper = {
    classList: {
      add(k) { wrapperCss.add(k); },
      remove(k) { wrapperCss.delete(k); },
      contains(k) { return wrapperCss.has(k); }
    },
    getBoundingClientRect() { return {width: 40, height: 40, top: 50}; },
    parentElement: null,
    isConnected: true
  };
  const obj = {
    name,
    left: x,
    top: 60,
    visible: true,
    isConnected: true,
    parentElement: wrapper,
    classList: {
      add(k) { css.add(k); },
      remove(k) { css.delete(k); },
      contains(k) { return css.has(k); }
    },
    getBoundingClientRect() {
      return {left: obj.left, top: obj.top, bottom: obj.top + 24, width: 24, height: 24};
    },
    closest() { return null; }
  };
  state.push({svg: obj, wrapper});
  return {svg: obj, wrapper};
}
const left = icon('sidebar',14);
const right = icon('new chat',60);
const share = icon('share',260);
const context = {
  innerWidth: 430,
  document: {
    body: {},
    querySelectorAll(sel) {
      if (sel === 'svg') return state.map(x => x.svg);
      if (sel === '.cg-ios16-direct-black-svg') return state.filter(x => x.svg.classList.contains('cg-ios16-direct-black-svg')).map(x => x.svg);
      if (sel === '.cg-ios16-direct-black-wrapper') return state.filter(x => x.wrapper.classList.contains('cg-ios16-direct-black-wrapper')).map(x => x.wrapper);
      throw Error('Unexpected selector ' + sel);
    }
  },
  getComputedStyle(svg) { return {display: 'block', visibility: svg.visible ? 'visible' : 'hidden', opacity: '1'}; },
  normalizedText() { return ''; }
};
const apply = vm.runInNewContext(routine + '\nmakeTopLeftHeaderIconsBlack;', context);
const black = 'cg-ios16-direct-black-svg';
const unfaded = 'cg-ios16-direct-black-wrapper';
apply();
for (const e of [left,right]) {
  assert(e.svg.classList.contains(black), e.svg.name + ' must be black initially');
  assert(e.wrapper.classList.contains(unfaded), e.svg.name + ' ancestor unfaded initially');
}
assert(!share.svg.classList.contains(black), 'Unrelated Share icon not forced black');
// Simulate the ChatGPT streaming/scroll reflow: neither icon passes the
// original geometry test for one render frame.
left.svg.top = 190;
right.svg.top = 190;
apply();
for (const e of [left,right]) {
  assert(e.svg.classList.contains(black), e.svg.name + ' lost black on transient reflow');
  assert(e.wrapper.classList.contains(unfaded), e.svg.name + ' wrapper dimmed on transient reflow');
}
// Restore first glyph; replace the second after navigating to a chat.
left.svg.top = 60;
const replacement = icon('new chat replacement',60);
right.svg.visible = false;
apply();
assert(replacement.svg.classList.contains(black), 'Newly mounted new-chat button should be black');
assert(replacement.wrapper.classList.contains(unfaded), 'Newly mounted new-chat wrapper should be unfaded');
assert(right.svg.classList.contains(black), 'Previously selected glyph stays stable even when temporarily hidden');
console.log('PASS: v1.08 sidebar kept; black icons persist across temporary reflow; replacement icons become black.');
