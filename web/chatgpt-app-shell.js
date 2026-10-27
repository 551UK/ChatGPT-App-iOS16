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
    ".cg-ios16-solid-topbar { background-color: transparent !important; background-image: linear-gradient(to bottom, var(--cg-ios16-topbar-bg, #eeeef0) 0, var(--cg-ios16-topbar-bg, #eeeef0) var(--cg-ios16-topbar-cutoff, 0px), transparent var(--cg-ios16-topbar-cutoff, 0px), transparent 100%) !important; opacity: 1 !important; backdrop-filter: none !important; -webkit-backdrop-filter: none !important; }",
    ".cg-ios16-topbar-control { transform: scale(1.30) !important; transform-origin: center center !important; }",
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

  function parseComputedColor(value) {
    const match = String(value || "").match(
      /rgba?\(\s*([\d.]+)[, ]+\s*([\d.]+)[, ]+\s*([\d.]+)(?:\s*[,\/]\s*([\d.]+))?\s*\)/i
    );
    if (!match) return null;
    return {
      r: Number(match[1]),
      g: Number(match[2]),
      b: Number(match[3]),
      a: match[4] == null ? 1 : Number(match[4])
    };
  }

  function compositeColor(foreground, background) {
    const outA = foreground.a + background.a * (1 - foreground.a);
    if (outA <= 0) return { r: 0, g: 0, b: 0, a: 0 };
    return {
      r: (foreground.r * foreground.a +
          background.r * background.a * (1 - foreground.a)) / outA,
      g: (foreground.g * foreground.a +
          background.g * background.a * (1 - foreground.a)) / outA,
      b: (foreground.b * foreground.a +
          background.b * background.a * (1 - foreground.a)) / outA,
      a: outA
    };
  }

  function renderedBackgroundColor(element) {
    let accumulated = { r: 0, g: 0, b: 0, a: 0 };
    let node = element;

    for (let depth = 0; node && depth < 12; depth++, node = node.parentElement) {
      const color = parseComputedColor(getComputedStyle(node).backgroundColor);
      if (color && color.a > 0) {
        accumulated = compositeColor(accumulated, color);
        if (accumulated.a >= 0.999) break;
      }
      if (node === document.body || node === document.documentElement) break;
    }

    if (accumulated.a < 0.999) {
      accumulated = compositeColor(accumulated, { r: 255, g: 255, b: 255, a: 1 });
    }

    return `rgb(${Math.round(accumulated.r)}, ${Math.round(accumulated.g)}, ${Math.round(accumulated.b)})`;
  }

  function stabilizeTopActionBar() {
    // The root route is the ChatGPT home page. Know this immediately from the
    // URL instead of waiting for the Chat/Work segmented control to render.
    // That prevents a partially loaded home header from being mistaken for a
    // chat header and briefly receiving the custom dark/solid top-bar colour.
    const isHomeRoute =
      window.location.pathname === "/" ||
      window.location.pathname === "";

    const allControls = Array.from(document.querySelectorAll(
      "button, [role='button'], a"
    ));

    const visibleTopControls = allControls.filter((element) => {
      const rect = element.getBoundingClientRect();
      if (rect.width < 20 || rect.height < 20) return false;
      if (rect.bottom <= 0 || rect.top >= Math.min(140, innerHeight * 0.20)) return false;
      if (rect.right <= 0 || rect.left >= innerWidth) return false;

      const style = getComputedStyle(element);
      if (style.display === "none" || style.visibility === "hidden") return false;
      if (Number(style.opacity || 1) <= 0.05) return false;
      return true;
    });

    if (visibleTopControls.length < 2) {
      for (const old of document.querySelectorAll(".cg-ios16-topbar-control")) {
        old.classList.remove("cg-ios16-topbar-control");
      }
      return false;
    }

    // ChatGPT uses several different header DOM shapes across normal chats,
    // Work/Astra chats, loading states and the home page. Do not depend on a
    // specific label such as "Share". Group visible controls by their vertical
    // centre and use the highest real control row.
    const sorted = visibleTopControls
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          element,
          centerY: rect.top + rect.height / 2
        };
      })
      .sort((a, b) => a.centerY - b.centerY);

    const rows = [];
    for (const item of sorted) {
      let row = rows.find((candidate) =>
        Math.abs(candidate.centerY - item.centerY) <= 18
      );
      if (!row) {
        row = { centerY: item.centerY, items: [] };
        rows.push(row);
      }
      row.items.push(item.element);
      row.centerY =
        row.items.reduce((sum, element) => {
          const rect = element.getBoundingClientRect();
          return sum + rect.top + rect.height / 2;
        }, 0) / row.items.length;
    }

    const eligibleRows = rows
      .filter((row) => row.items.length >= 2)
      .sort((a, b) => a.centerY - b.centerY);

    if (!eligibleRows.length) return false;

    const rowControls = eligibleRows[0].items;
    const rowLabels = rowControls.map((element) => {
      const text = normalizedText(element).toLowerCase();
      const aria = (element.getAttribute("aria-label") || "").trim().toLowerCase();
      const title = (element.getAttribute("title") || "").trim().toLowerCase();
      return { element, text, aria, title };
    });

    const shareControl =
      rowLabels.find(({ text, aria, title }) =>
        text === "share" ||
        aria === "share" ||
        title === "share" ||
        aria.startsWith("share ") ||
        title.startsWith("share ")
      )?.element || null;

    // The home page has the Chat/Work segmented control in the middle. The
    // request is to enlarge only the top-left and top-right icons there, not
    // the segmented switch itself.
    const hasHomeSwitcher =
      rowLabels.some(({ text }) => text === "chat") &&
      rowLabels.some(({ text }) => text === "work");

    let scaleControls = rowControls;
    if (isHomeRoute || hasHomeSwitcher) {
      scaleControls = rowControls.filter((element) => {
        const label = normalizedText(element).toLowerCase();
        if (label === "chat" || label === "work") return false;

        const rect = element.getBoundingClientRect();
        const centerX = rect.left + rect.width / 2;
        return centerX <= innerWidth * 0.28 || centerX >= innerWidth * 0.72;
      });
    }

    if (!scaleControls.length) return false;

    for (const old of document.querySelectorAll(".cg-ios16-topbar-control")) {
      if (!scaleControls.includes(old)) {
        old.classList.remove("cg-ios16-topbar-control");
      }
    }
    for (const element of scaleControls) {
      element.classList.add("cg-ios16-topbar-control");
    }

    // Home page: keep ChatGPT's native white header completely untouched,
    // including the partial loading state before Chat/Work exists in the DOM.
    // The left/right icon controls above are still enlarged to 1.30x, but do
    // not sample a transparent icon as a background colour and do not apply
    // the custom solid-topbar treatment here.
    if (isHomeRoute || hasHomeSwitcher) {
      for (const old of document.querySelectorAll(".cg-ios16-solid-topbar")) {
        old.classList.remove("cg-ios16-solid-topbar");
        old.style.removeProperty("--cg-ios16-topbar-bg");
        old.style.removeProperty("--cg-ios16-topbar-cutoff");
        delete old.dataset.cgIos16SolidTopbar;
      }
      return true;
    }

    // Locate the real full-width top header from the detected row, rather than
    // walking upward from Share. This works on chat variants where Share is
    // missing, renamed, disabled or rendered in a different subtree.
    const edgeTolerance = Math.max(12, innerWidth * 0.02);
    const candidates = new Set();

    for (const control of rowControls) {
      let node = control;
      for (let depth = 0; node && depth < 12; depth++, node = node.parentElement) {
        if (node === document.body || node === document.documentElement) break;

        const rect = node.getBoundingClientRect();
        const inTopBand =
          rect.top <= 100 &&
          rect.bottom >= 34 &&
          rect.height >= 42 &&
          rect.height <= 160 &&
          rect.width >= innerWidth * 0.72;

        if (inTopBand) candidates.add(node);
      }
    }

    let best = null;
    const rankedCandidates = Array.from(candidates).sort((a, b) => {
      const ar = a.getBoundingClientRect();
      const br = b.getBoundingClientRect();

      const aFull =
        ar.left <= edgeTolerance &&
        ar.right >= innerWidth - edgeTolerance &&
        ar.width >= innerWidth * 0.96;
      const bFull =
        br.left <= edgeTolerance &&
        br.right >= innerWidth - edgeTolerance &&
        br.width >= innerWidth * 0.96;

      if (aFull !== bFull) return aFull ? -1 : 1;
      if (Math.abs(ar.width - br.width) > 2) return br.width - ar.width;
      return ar.height - br.height;
    });

    if (rankedCandidates.length) best = rankedCandidates[0];

    if (!best) {
      const header = rowControls
        .map((element) => element.closest("header"))
        .find(Boolean);
      if (header) best = header;
    }

    // Scaling must still apply even if ChatGPT changes the header container
    // markup. In that case leave its native white background alone.
    if (!best) return true;

    for (const old of document.querySelectorAll(".cg-ios16-solid-topbar")) {
      if (old !== best) old.classList.remove("cg-ios16-solid-topbar");
    }

    const bestRect = best.getBoundingClientRect();

    // getBoundingClientRect() includes the 1.30x transform, so this cutoff is
    // measured after scaling. Use the whole detected row for the white strip:
    // on the home page this also respects the untouched Chat/Work switch.
    const rowBottom = rowControls.reduce(
      (bottom, element) => Math.max(bottom, element.getBoundingClientRect().bottom),
      bestRect.top
    );

    const cutoff = Math.max(
      0,
      Math.min(bestRect.height, Math.ceil(rowBottom - bestRect.top))
    );

    const backgroundProbe = shareControl || scaleControls[0] || best;
    best.style.setProperty(
      "--cg-ios16-topbar-bg",
      renderedBackgroundColor(backgroundProbe)
    );
    best.style.setProperty("--cg-ios16-topbar-cutoff", `${cutoff}px`);

    best.classList.add("cg-ios16-solid-topbar");
    best.dataset.cgIos16SolidTopbar = "1";
    return true;
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
    const controls = new Set(["stay on web", "open the app"]);
    const newPromoHeadline = "chatgpt is better in the app";
    let stayOnWebButton = null;
    let closeButton = null;
    let hiddenSurface = null;
    let matchedNewPromo = false;

    // ChatGPT currently has two mobile-app promotion variants:
    // 1) a modal with "Stay on web" + "Open the app"
    // 2) a compact bottom card headed "ChatGPT is better in the app"
    //    with an X + "Open the app".
    //
    // Match the controls/headline rather than transient CSS class names so
    // minor web UI changes do not make the promotion visible again.
    for (const button of document.querySelectorAll("button, [role='button']")) {
      const label = normalizedText(button).toLowerCase();
      if (!controls.has(label)) continue;
      if (label === "stay on web") stayOnWebButton = button;

      let node = button;
      for (let depth = 0; node && depth < 12; depth++, node = node.parentElement) {
        if (node === document.body || node === document.documentElement) break;

        const text = normalizedText(node).toLowerCase();
        const hasStay = text.includes("stay on web");
        const hasOpen = text.includes("open the app");
        const hasNewHeadline = text.includes(newPromoHeadline);
        if (!hasOpen && !hasStay && !hasNewHeadline) continue;

        const role = (node.getAttribute("role") || "").toLowerCase();
        const ariaModal = (node.getAttribute("aria-modal") || "").toLowerCase();
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        const isDialog = role === "dialog" || ariaModal === "true";
        const isLargeOverlay =
          (style.position === "fixed" || style.position === "absolute") &&
          rect.width >= innerWidth * 0.72 &&
          rect.height >= innerHeight * 0.36;
        const hasBothActions = hasStay && hasOpen;

        // The newer card is much smaller than the old modal. Require both its
        // exact headline and Open-the-app CTA, then choose the smallest
        // reasonable ancestor so we never hide the ChatGPT composer beneath it.
        const isNewPromoCard =
          hasNewHeadline &&
          hasOpen &&
          rect.width >= Math.min(innerWidth * 0.70, 280) &&
          rect.height >= 110 &&
          rect.height <= Math.min(innerHeight * 0.55, 460) &&
          text.length <= 420;

        if (isNewPromoCard || isDialog || isLargeOverlay || hasBothActions) {
          hiddenSurface = node;
          matchedNewPromo = isNewPromoCard;
          break;
        }
      }

      if (hiddenSurface) break;
    }

    if (!hiddenSurface) return false;

    // Hide synchronously from the MutationObserver callback before the browser's next paint,
    // so the card/modal never reaches a rendered frame.
    hiddenSurface.dataset.cgIos16Hidden = "1";
    hiddenSurface.dataset.cgIos16AppPromo = "1";
    hiddenSurface.classList.add("cg-ios16-hide");

    let blocker = hiddenSurface;

    if (!matchedNewPromo) {
      // The older promotion may be wrapped in a full-screen fixed backdrop.
      for (let depth = 0, parent = hiddenSurface.parentElement;
           parent && depth < 6 && parent !== document.body && parent !== document.documentElement;
           depth++, parent = parent.parentElement) {
        const text = normalizedText(parent).toLowerCase();
        if (!text.includes("stay on web") && !text.includes("open the app")) continue;

        const rect = parent.getBoundingClientRect();
        const style = getComputedStyle(parent);
        const coversViewport =
          rect.width >= innerWidth * 0.90 &&
          rect.height >= innerHeight * 0.72;

        if (style.position === "fixed" && coversViewport) {
          blocker = parent;
          blocker.dataset.cgIos16Hidden = "1";
          blocker.dataset.cgIos16AppPromo = "1";
          blocker.classList.add("cg-ios16-hide");
          break;
        }
      }
    }

    if (matchedNewPromo) {
      // Persist ChatGPT's own dismissal state after the card has already been
      // hidden. Never click the "Open the app" CTA.
      closeButton = Array.from(
        blocker.querySelectorAll("button, [role='button']")
      ).find((element) => {
        const text = normalizedText(element).toLowerCase();
        const aria = (element.getAttribute("aria-label") || "").trim().toLowerCase();
        const title = (element.getAttribute("title") || "").trim().toLowerCase();
        return (
          aria === "close" ||
          aria === "dismiss" ||
          title === "close" ||
          title === "dismiss" ||
          text === "×" ||
          text === "✕"
        );
      }) || null;

      if (closeButton && closeButton.isConnected) {
        try {
          closeButton.click();
        } catch (_) {
          closeButton.dispatchEvent(new MouseEvent("click", {
            bubbles: true,
            cancelable: true,
            view: window
          }));
        }
      }
    } else {
      // Preserve the older promotion's normal "Stay on web" acknowledgement.
      if (!stayOnWebButton || !stayOnWebButton.isConnected) {
        stayOnWebButton = Array.from(
          blocker.querySelectorAll("button, [role='button']")
        ).find((element) => normalizedText(element).toLowerCase() === "stay on web") || null;
      }

      if (stayOnWebButton) {
        try {
          stayOnWebButton.click();
        } catch (_) {
          stayOnWebButton.dispatchEvent(new MouseEvent("click", {
            bubbles: true,
            cancelable: true,
            view: window
          }));
        }
      }
    }

    return true;
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
    stabilizeTopActionBar();
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

  const observer = new MutationObserver(() => {
    // Hide this exact mobile-web app promotion before the next paint.
    dismissAppPromotion();
    schedule();
  });
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true
  });
  window.addEventListener("resize", schedule, { passive: true });
  window.addEventListener("popstate", schedule);
})();
