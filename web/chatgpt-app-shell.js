(() => {
  "use strict";

  // Dedicated presentation layer for the ChatGPT Gecko app.
  // ChatGPT still owns messages, uploads, account state and voice.
  const STYLE_ID = "cg-ios16-app-style";
  const PREPARE_ATTR = "data-cg-ios16-preparing";

  // document_start runs before ChatGPT paints. Keep the document invisible
  // until the app-only cleanup has been applied, preventing the footer and
  // suggestion from flashing briefly on launch. A hard timeout always reveals
  // the page even if ChatGPT changes its markup later.
  const root = document.documentElement;
  if (root) root.setAttribute(PREPARE_ATTR, "1");
  const revealFailsafe = setTimeout(() => {
    document.documentElement?.removeAttribute(PREPARE_ATTR);
  }, 1400);

  const styleText = [
    "html[data-cg-ios16-preparing='1'] { visibility: hidden !important; }",
    ".cg-ios16-hide { display: none !important; }",
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

  let revealed = false;
  function revealCleanPage() {
    if (revealed) return;
    revealed = true;
    clearTimeout(revealFailsafe);
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        document.documentElement?.removeAttribute(PREPARE_ATTR);
      });
    });
  }

  function applyAppPresentation() {
    installStyle();
    hideSuggestion();
    hideDisclaimers();
    if (document.body) revealCleanPage();
  }

  let timer = null;
  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(applyAppPresentation, 16);
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
