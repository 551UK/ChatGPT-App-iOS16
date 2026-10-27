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

  function dismissAppPromotion() {
    const promoPhrase = "do more with the chatgpt app";

    for (const button of document.querySelectorAll("button, [role='button']")) {
      if (normalizedText(button).toLowerCase() !== "stay on web") continue;

      let node = button;
      let surface = null;
      for (let depth = 0; node && depth < 10; depth++, node = node.parentElement) {
        if (node === document.body || node === document.documentElement) break;
        const text = normalizedText(node).toLowerCase();
        if (
          text.includes(promoPhrase) &&
          text.includes("open the app") &&
          text.includes("stay on web")
        ) {
          surface = node;
          if (node.getAttribute("role") === "dialog") break;
        }
      }
      if (!surface) continue;

      // Hide the prompt synchronously in the same mutation turn in which
      // ChatGPT inserts it. MutationObserver callbacks run before the next
      // paint, so the app-only promotion never needs to flash on screen.
      let blocker = surface;
      for (let depth = 0, parent = surface.parentElement;
           parent && depth < 5 && parent !== document.body && parent !== document.documentElement;
           depth++, parent = parent.parentElement) {
        const rect = parent.getBoundingClientRect();
        const style = getComputedStyle(parent);
        const text = normalizedText(parent).toLowerCase();
        const coversViewport =
          rect.width >= innerWidth * 0.90 &&
          rect.height >= innerHeight * 0.75;
        if (
          style.position === "fixed" &&
          coversViewport &&
          text.includes(promoPhrase) &&
          text.includes("stay on web")
        ) {
          blocker = parent;
          break;
        }
      }

      blocker.dataset.cgIos16Hidden = "1";
      blocker.classList.add("cg-ios16-hide");

      // Let ChatGPT perform its own normal dismissal bookkeeping while the
      // prompt is already invisible. This is deliberately scoped to this
      // exact app-promotion prompt; other dialogs are untouched.
      try {
        button.click();
      } catch (_) {
        button.dispatchEvent(new MouseEvent("click", {
          bubbles: true,
          cancelable: true,
          view: window
        }));
      }
      return true;
    }

    return false;
  }

  let keyboardAdjustedElement = null;

  function clearKeyboardAdjustment() {
    if (!keyboardAdjustedElement) return;
    keyboardAdjustedElement.style.removeProperty("translate");
    keyboardAdjustedElement.removeAttribute("data-cg-ios16-keyboard-adjusted");
    keyboardAdjustedElement = null;
  }

  function isMessageEditor(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
    return element.matches(
      "textarea, [contenteditable='true'], input:not([type]), input[type='text'], input[type='search']"
    );
  }

  function findMessageBar(editor, visibleBottom) {
    let node = editor;
    let candidate = null;

    for (let depth = 0; node && depth < 9; depth++, node = node.parentElement) {
      if (node === document.body || node === document.documentElement) break;
      const rect = node.getBoundingClientRect();
      const wideEnough = rect.width >= innerWidth * 0.58;
      const barSized = rect.height >= 38 && rect.height <= 150;
      const nearKeyboard = rect.bottom >= visibleBottom * 0.55;

      if (wideEnough && barSized && nearKeyboard) {
        // Keep walking outward while the ancestor is still bar-sized. This
        // picks up the + / microphone controls with the text field instead of
        // shifting just the editable element itself.
        candidate = node;
      } else if (candidate && rect.height > 190) {
        break;
      }
    }

    return candidate;
  }

  function removeKeyboardGap() {
    const viewport = window.visualViewport;
    const editor = document.activeElement;

    if (!viewport || !isMessageEditor(editor)) {
      clearKeyboardAdjustment();
      return;
    }

    // Only apply while iOS has substantially reduced the visual viewport for
    // its on-screen keyboard. This avoids touching the normal resting composer.
    const screenHeight = Math.max(screen.width || 0, screen.height || 0);
    const keyboardVisible = screenHeight > 0 && viewport.height < screenHeight * 0.82;
    if (!keyboardVisible) {
      clearKeyboardAdjustment();
      return;
    }

    const visibleBottom = viewport.offsetTop + viewport.height;
    const bar = findMessageBar(editor, visibleBottom);
    if (!bar) {
      clearKeyboardAdjustment();
      return;
    }

    const rect = bar.getBoundingClientRect();
    const gap = visibleBottom - rect.bottom;

    // The unwanted mobile-web spacer in our Gecko shell is roughly a
    // keyboard-safe-area sized gap. Measure it instead of hard-coding a device
    // value, but refuse extreme values so a changed ChatGPT layout cannot move
    // the composer across the page.
    if (gap < 8 || gap > 220) {
      clearKeyboardAdjustment();
      return;
    }

    if (keyboardAdjustedElement && keyboardAdjustedElement !== bar) {
      clearKeyboardAdjustment();
    }

    keyboardAdjustedElement = bar;
    bar.dataset.cgIos16KeyboardAdjusted = "1";
    bar.style.setProperty("translate", `0 ${Math.round(gap)}px`, "important");
  }

  let keyboardFrame = 0;
  function scheduleKeyboardGapRemoval() {
    cancelAnimationFrame(keyboardFrame);
    keyboardFrame = requestAnimationFrame(removeKeyboardGap);
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
    dismissAppPromotion();
    hideSuggestion();
    hideDisclaimers();
    scheduleKeyboardGapRemoval();
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

  const observer = new MutationObserver(() => {
    // Do this synchronously so the app-promotion modal is hidden before paint.
    dismissAppPromotion();
    schedule();
  });
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true
  });
  window.addEventListener("resize", () => {
    schedule();
    scheduleKeyboardGapRemoval();
  }, { passive: true });
  window.addEventListener("popstate", schedule);
  document.addEventListener("focusin", scheduleKeyboardGapRemoval, true);
  document.addEventListener("focusout", () => {
    requestAnimationFrame(clearKeyboardAdjustment);
  }, true);
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", scheduleKeyboardGapRemoval, { passive: true });
    window.visualViewport.addEventListener("scroll", scheduleKeyboardGapRemoval, { passive: true });
  }
})();
