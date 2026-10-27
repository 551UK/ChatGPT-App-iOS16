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
    "  bottom: calc(env(safe-area-inset-bottom, 0px) + 6px) !important;",
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
      "ChatGPT is AI and can make mistakes.",
      "ChatGPT is AI. By using it, you agree to our Terms & Privacy Policy.",
      "Chats may be reviewed and used to improve our AI models."
    ];

    for (const element of document.querySelectorAll("footer, small, p, div, span")) {
      if (element.dataset.cgIos16Hidden === "1") continue;
      const text = normalizedText(element);
      if (!text || text.length > 320 || !phrases.some((phrase) => text.includes(phrase))) continue;

      const rect = element.getBoundingClientRect();
      // Keep this limited to small lower-page/footer elements so matching text
      // inside an actual conversation is not removed.
      if (rect.height <= 140 && (rect.top > innerHeight * 0.55 || element.closest("footer"))) {
        let target = element;
        for (let i = 0; i < 2 && target.parentElement; i++) {
          const parent = target.parentElement;
          const parentText = normalizedText(parent);
          const parentRect = parent.getBoundingClientRect();
          if (parentText.length <= 360 && parentRect.height <= 150) {
            target = parent;
          } else {
            break;
          }
        }
        target.dataset.cgIos16Hidden = "1";
        target.classList.add("cg-ios16-hide");
      }
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

    let node = input;
    let best = null;
    for (let depth = 0; node && depth < 8; depth++, node = node.parentElement) {
      const rect = node.getBoundingClientRect();
      if (rect.width >= innerWidth * 0.72 && rect.height >= 42 && rect.height <= 130) {
        best = node;
        const radius = parseFloat(getComputedStyle(node).borderRadius) || 0;
        if (radius >= 18) break;
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
