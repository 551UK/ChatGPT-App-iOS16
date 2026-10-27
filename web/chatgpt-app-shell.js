(() => {
  "use strict";

  // Dedicated presentation layer for the ChatGPT Gecko app.
  // ChatGPT still owns messages, uploads, account state and voice.
  const STYLE_ID = "cg-ios16-app-style";

  const styleText = [
    ".cg-ios16-hide { display: none !important; }",
    ".cg-ios16-composer {",
    "  position: fixed !important;",
    "  left: 18px !important;",
    "  right: 18px !important;",
    "  bottom: env(safe-area-inset-bottom, 0px) !important;",
    "  top: auto !important;",
    "  width: auto !important;",
    "  max-width: 760px !important;",
    "  margin-left: auto !important;",
    "  margin-right: auto !important;",
    "  z-index: 2147482000 !important;",
    "}"
  ].join("\n");

  function installStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = styleText;
    (document.head || document.documentElement).appendChild(style);
  }

  function normalizedText(element) {
    return (element && element.textContent ? element.textContent : "")
      .replace(/\s+/g, " ")
      .trim();
  }

  function hideSuggestion() {
    for (const element of document.querySelectorAll("button, [role='button']")) {
      const text = normalizedText(element);
      if (text === "What can you do?" || text === "What can you do") {
        element.classList.add("cg-ios16-hide");
        const parent = element.parentElement;
        if (parent && parent.children.length === 1 && parent.getBoundingClientRect().height < 100) {
          parent.classList.add("cg-ios16-hide");
        }
      }
    }
  }

  function hideDisclaimers() {
    const phrases = [
      "chatgpt is ai and can make mistakes",
      "chatgpt is ai. by using it, you agree to our terms & privacy policy",
      "chats may be reviewed and used to improve our ai models",
      "chatgpt can make mistakes",
      "check important info"
    ];

    const candidates = document.querySelectorAll(
      "footer, small, p, div, span, a, [class*='footer'], [class*='disclaimer']"
    );

    for (const element of candidates) {
      if (element.dataset.cgIos16Hidden === "1") continue;

      const text = normalizedText(element);
      const lower = text.toLowerCase();
      if (!text || text.length > 420 || !phrases.some((phrase) => lower.includes(phrase))) {
        continue;
      }

      const rect = element.getBoundingClientRect();
      const nearBottom = rect.top > innerHeight * 0.48 || !!element.closest("footer");
      if (!nearBottom || rect.height > 190) continue;

      // Prefer the complete disclaimer/footer block, but never climb into the
      // actual composer or another interactive ChatGPT section.
      let target = element.closest("footer") || element;
      for (let i = 0; !element.closest("footer") && i < 3 && target.parentElement; i++) {
        const parent = target.parentElement;
        const parentRect = parent.getBoundingClientRect();
        const parentText = normalizedText(parent).toLowerCase();
        const containsComposer =
          !!parent.querySelector("textarea, [contenteditable='true'], input[placeholder*='ChatGPT' i]");
        const stillDisclaimer =
          phrases.some((phrase) => parentText.includes(phrase)) &&
          parentText.length <= 460 &&
          parentRect.height <= 200;

        if (containsComposer || !stillDisclaimer) break;
        target = parent;
      }

      target.dataset.cgIos16Hidden = "1";
      target.classList.add("cg-ios16-hide");
    }
  }

  function findComposerInput() {
    const candidates = [
      ...document.querySelectorAll("textarea, [contenteditable='true'], input")
    ];
    return candidates.find((element) => {
      const text = [
        element.getAttribute("placeholder"),
        element.getAttribute("aria-label"),
        element.getAttribute("data-placeholder")
      ].filter(Boolean).join(" ");
      return /ask chatgpt/i.test(text);
    }) || null;
  }

  function moveComposerDown() {
    const input = findComposerInput();
    if (!input) return;

    let best = null;

    // The form is the safest stable wrapper on current ChatGPT mobile pages.
    const form = input.closest("form");
    if (form) {
      const rect = form.getBoundingClientRect();
      if (rect.width >= innerWidth * 0.68 && rect.height >= 42 && rect.height <= 180) {
        best = form;
      }
    }

    // Fall back to the rounded visual composer wrapper if the page changes.
    if (!best) {
      let node = input;
      for (let depth = 0; node && depth < 9; depth++, node = node.parentElement) {
        const rect = node.getBoundingClientRect();
        if (rect.width >= innerWidth * 0.70 && rect.height >= 42 && rect.height <= 150) {
          best = node;
          const radius = parseFloat(getComputedStyle(node).borderRadius) || 0;
          if (radius >= 18) break;
        }
      }
    }
    if (!best) return;

    for (const old of document.querySelectorAll(".cg-ios16-composer")) {
      if (old !== best) old.classList.remove("cg-ios16-composer");
    }
    best.classList.add("cg-ios16-composer");
  }

  function applyAppPresentation() {
    installStyle();
    hideSuggestion();
    hideDisclaimers();
    moveComposerDown();
  }

  let timer = null;
  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(applyAppPresentation, 120);
  }

  installStyle();
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", applyAppPresentation, { once: true });
  } else {
    applyAppPresentation();
  }

  const observer = new MutationObserver(schedule);
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true
  });
  window.addEventListener("resize", schedule, { passive: true });
  window.addEventListener("popstate", schedule);
})();
