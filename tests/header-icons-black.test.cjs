// Simulate both header icon orders, including a grey SVG inside
// a faded wrapper, without depending on real iPhone DOM or network.
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
const source = fs.readFileSync("web/chatgpt-app-shell.js", "utf8");
const first = source.indexOf("  function makeTopLeftHeaderIconsBlack() {");
const last = source.indexOf("\n  let revealed = false;", first);
assert(first !== -1 && last > first, "black icon routine missing");
const fn = source.slice(first, last);

function simulatedIcon(name, x, faded = false) {
  const classes = new Set();
  const wrapperClasses = new Set();
  const wrapper = {
    classList: {
      add(c) { wrapperClasses.add(c); },
      remove(c) { wrapperClasses.delete(c); },
      contains(c) { return wrapperClasses.has(c); }
    },
    getBoundingClientRect() { return { width: 40, height: 40, top: 52 }; },
    parentElement: null
  };
  const svg = {
    name, parentElement: wrapper,
    classList: {
      add(c) { classes.add(c); },
      remove(c) { classes.delete(c); },
      contains(c) { return classes.has(c); }
    },
    getBoundingClientRect() {
      return { left: x, top: 61, width: 24, height: 24, bottom: 85 };
    },
    closest() { return null; } // no button tags/aria-labels; v1.00 missed this
  };
  wrapper.faded = faded;
  return { svg, wrapper };
}

function run(order) {
  const sidebar = simulatedIcon("sidebar", order === "first" ? 14 : 60, true);
  const pencil = simulatedIcon("pencil", order === "first" ? 60 : 14);
  const share = simulatedIcon("share", 280);
  const all = [share, pencil, sidebar];
  const context = {
    innerWidth: 430,
    document: {
      body: {},
      querySelectorAll(selector) {
        if (selector === "svg") return all.map(x => x.svg);
        if (selector === ".cg-ios16-direct-black-svg")
          return all.map(x => x.svg).filter(svg =>
            svg.classList.contains("cg-ios16-direct-black-svg"));
        if (selector === ".cg-ios16-direct-black-wrapper")
          return all.map(x => x.wrapper).filter(wrapper =>
            wrapper.classList.contains("cg-ios16-direct-black-wrapper"));
        throw new Error("Unexpected selector " + selector);
      }
    },
    getComputedStyle(element) {
      return { display: "block", visibility: "visible",
        opacity: element.faded ? "0.5" : "1" };
    },
    normalizedText: () => ""
  };
  // The function is read directly from the file GitHub is about to package.
  const apply = vm.runInNewContext(fn + "\nmakeTopLeftHeaderIconsBlack;", context);
  apply();
  for (const icon of [sidebar, pencil]) {
    assert(icon.svg.classList.contains("cg-ios16-direct-black-svg"),
      icon.svg.name + " unselected in " + order + " order");
    assert(icon.wrapper.classList.contains("cg-ios16-direct-black-wrapper"),
      icon.svg.name + " wrapper still faded in " + order + " order");
  }
  assert(!share.svg.classList.contains("cg-ios16-direct-black-svg"),
    "Share should remain untouched");
}
run("first");
run("second");
console.log("Passed: both icons directly selected; faded Sidebar wrapper restored in both orders.");
