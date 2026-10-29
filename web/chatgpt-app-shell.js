(() => {
  "use strict";

  // Dedicated presentation layer for the ChatGPT Gecko app.
  // ChatGPT still owns messages, uploads, account state and voice.
  const STYLE_ID = "cg-ios16-app-style";
  const PREPARE_ATTR = "data-cg-ios16-preparing";
  // Subtle white-strip reduction only; independent of icon and Share size.
  const HEADER_WHITE_BAR_TRIM_PX = 3;

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
    // Independent Share-button sizing: the sidebar may temporarily hide or rearrange the underlying header.
    "html body .cg-ios16-share-control-stable { transform: scale(1.30) !important; transform-origin: center center !important; transition: none !important; animation: none !important; }",
    // First-paint fallback for the accessible header Share button, before JS marks it.
    ":is(header, [role='banner'], #page-header, #conversation-header-actions) :is(button, a, [role='button']):is([aria-label='Share'], [title='Share']) { transform: scale(1.30) !important; transform-origin: center center !important; transition: none !important; animation: none !important; }",
    // Only homepage top-corner controls use 40%; chat header keeps 30%.
    ".cg-ios16-topbar-control.cg-ios16-home-topbar-control { transform: scale(1.40) !important; }",
    ".cg-ios16-topbar-control[data-cg-icon-role='sidebar'] { transform: scale(1.40) !important; }",
    ".cg-ios16-topbar-control[data-cg-icon-role='new'] { transform: scale(1.50) !important; }",
    // v1.16: independently retain the main header icon size when closing the sidebar.
    // The inner sidebar dismiss control is deliberately NOT a sizing target.
    "html body .cg-ios16-left-header-size-stable { transform: scale(1.40) !important; transform-origin: center center !important; }",
    "html body .cg-ios16-left-header-size-stable[data-cg-left-header-icon='new'] { transform: scale(1.50) !important; }",
    "#browser-sidebar-popover .cg-ios16-left-header-size-stable, #stage-popover-sidebar .cg-ios16-left-header-size-stable, #stage-slideover-sidebar .cg-ios16-left-header-size-stable, #sidebar-container .cg-ios16-left-header-size-stable { transform: none !important; }",
    // v1.01: colour the two SVG icons themselves; do not rely on their
    // containing button tags, role metadata or order.
    ".cg-ios16-direct-black-svg { color: #000000 !important; opacity: 1 !important; filter: brightness(0) !important; -webkit-filter: brightness(0) !important; }",
    ".cg-ios16-direct-black-svg * { opacity: 1 !important; }",
    // The Sidebar glyph can be half-opacity on an intermediate span/button:
    // override those icon-sized wrappers as well (not the overall header).
    ".cg-ios16-direct-black-wrapper { opacity: 1 !important; filter: none !important; -webkit-filter: none !important; }",
    // v1.19: inherited ink for the confirmed MAIN header controls.
    // ChatGPT can replace the SVG on scroll/sidebar transitions without
    // replacing its button. Styling the button AND descendant SVG means no
    // mutation callback or chat message is needed to restore black ink.
    // This marker is only applied to the two main top-left header buttons;
    // the smaller close toggle inside the sidebar does not receive it.
    "html body .cg-ios16-left-header-size-stable { color: #000000 !important; opacity: 1 !important; }",
    "html body .cg-ios16-left-header-size-stable :is(span, svg) { color: #000000 !important; opacity: 1 !important; }",
    "html body .cg-ios16-left-header-size-stable svg { filter: brightness(0) !important; -webkit-filter: brightness(0) !important; }",
    "html body .cg-ios16-left-header-size-stable svg * { opacity: 1 !important; }",
    // If the header sizing row has already identified a control before the
    // independent v1.16 pair detector catches up, protect it immediately too.
    "html body .cg-ios16-topbar-control[data-cg-icon-role='sidebar'] { color: #000000 !important; opacity: 1 !important; }",
    "html body .cg-ios16-topbar-control[data-cg-icon-role='sidebar'] svg { color: #000000 !important; opacity: 1 !important; filter: brightness(0) !important; -webkit-filter: brightness(0) !important; }",
    // v1.08: Firefox-confirmed exact sidebar popover on mobile (75vw = 322.5px at 430px).
    // Keep chat titles, buttons, navigation, header and scroll behavior untouched.
    "@media (max-width: 799px) { #browser-sidebar-popover { width: 75vw !important; } }",
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

  // Identity is recomputed from current markup, never a button's row index.
  const iconShapes = new Map();
  function iconIdentity(element) {
    const label = ["aria-label", "title", "data-testid"].map(k =>
      element.getAttribute(k) || "").join(" ").toLowerCase();
    const svg = element.querySelector("svg");
    const shape = svg ? Array.from(svg.querySelectorAll("path, rect, line, polyline, circle, use"))
      .map(n => n.tagName + ":" + Array.from(n.attributes)
        .filter(a => /^(d|x|y|x1|x2|y1|y2|width|height|points|cx|cy|r|href|xlink:href)$/.test(a.name))
        .map(a => a.name + "=" + a.value).sort().join(";")).join("|") : "";
    if (!svg) return "";
    let role = /new[ -]?chat|create[ -]?chat|compose/.test(label) ? "new" :
      /sidebar|side[ -]?bar/.test(label) ? "sidebar" : "";
    if (role && shape) {
      const previous = iconShapes.get(shape);
      iconShapes.set(shape, previous && previous !== role ? "ambiguous" : role);
    }
    if (!role && shape) role = iconShapes.get(shape) || "";
    return role === "new" || role === "sidebar" ? role : "";
  }

  // One-way styling for the real header Share button. React may temporarily
  // blank its text while inserting streaming/tool-result rows. Never toggle the
  // size class off a still-connected Share node just because its label or
  // position temporarily changes. Detached nodes clean themselves up.
  function keepHeaderShareEnlarged(allControls) {
    for (const element of allControls) {
      if (element.classList.contains("cg-ios16-share-control-stable")) continue;
      if (element.closest(
        "#stage-popover-sidebar, #stage-slideover-sidebar, #sidebar-container, " +
        "#sidebar-header, #browser-sidebar-popover, nav[aria-label='Chat history'], " +
        "[data-message-author-role], [data-testid^='conversation-turn'], " +
        "aside, [role='dialog'], [aria-modal='true']"
      )) continue;
      const aria = (element.getAttribute("aria-label") || "").trim().toLowerCase();
      const title = (element.getAttribute("title") || "").trim().toLowerCase();
      const ownText = (element.textContent || "").trim().toLowerCase();
      const isShare = ownText === "share" || aria === "share" ||
        title === "share" || aria.startsWith("share ") || title.startsWith("share ");
      if (!isShare) continue;
      const rect = element.getBoundingClientRect();
      if (rect.width < 20 || rect.height < 20 ||
          rect.top < -12 || rect.top >= Math.min(145, innerHeight * 0.24) ||
          rect.left < 0 || rect.left >= innerWidth) continue;
      element.classList.add("cg-ios16-share-control-stable");
    }
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
    keepHeaderShareEnlarged(allControls);

    const visibleTopControls = allControls.filter((element) => {
      if (element.closest(
        "#stage-popover-sidebar, #stage-slideover-sidebar, #sidebar-container, " +
        "#sidebar-header, aside, [role='dialog'], [aria-modal='true']"
      )) return false;
      // v1.10: Never classify chat-history entries, message controls or
      // other iconless text links as top-header icons. When a sidebar list
      // scrolls past the first 140px, v1.08/v1.09 could mistakenly scale
      // its chat titles as if they were toolbar buttons.
      if (element.closest("#browser-sidebar-popover, nav[aria-label='Chat history'], [data-message-author-role], [data-testid^='conversation-turn']")) return false;
      if (!element.querySelector("svg")) return false;
      // A normal chat-title row may contain an SVG too. Header buttons are
      // icon-only, apart from a short set of native accessible control labels.
      const label = normalizedText(element).trim().toLowerCase();
      if (label && !/^(share|new chat|create new chat|open sidebar|close sidebar|toggle sidebar)$/.test(label)) return false;
      const rect = element.getBoundingClientRect();
      if (rect.width > 110 || rect.height > 85) return false;
      if (rect.width < 20 || rect.height < 20) return false;
      if (rect.bottom <= 0 || rect.top >= Math.min(140, innerHeight * 0.20)) return false;
      if (rect.right <= 0 || rect.left >= innerWidth) return false;

      const style = getComputedStyle(element);
      if (style.display === "none" || style.visibility === "hidden") return false;
      if (Number(style.opacity || 1) <= 0.05) return false;
      return true;
    });

    if (visibleTopControls.length < 2) {
      // Sidebar overlays temporarily hide the conversation header: never
      // shrink buttons that are already identified as topbar controls.
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

    // A nested link/button must not receive a second ancestor scale.
    let scaleControls = rowControls.filter(element =>
      !rowControls.some(other => other !== element && element.contains(other)));
    if (isHomeRoute || hasHomeSwitcher) {
      scaleControls = scaleControls.filter((element) => {
        const label = normalizedText(element).toLowerCase();
        if (label === "chat" || label === "work") return false;

        const rect = element.getBoundingClientRect();
        const centerX = rect.left + rect.width / 2;
        return centerX <= innerWidth * 0.28 || centerX >= innerWidth * 0.72;
      });
    }

    if (!scaleControls.length) return false;

    const homeHeader = isHomeRoute || hasHomeSwitcher;
    for (const old of document.querySelectorAll(".cg-ios16-topbar-control")) {
      if (!scaleControls.includes(old) &&
          !old.classList.contains("cg-ios16-share-control-stable")) {
        old.classList.remove("cg-ios16-topbar-control");
        old.classList.remove("cg-ios16-home-topbar-control");
      }
    }
    // Remove homepage-only scaling when navigating into a conversation,
    // even if React reuses the same button element between page layouts.
    for (const old of document.querySelectorAll(".cg-ios16-home-topbar-control")) {
      if (!homeHeader || !scaleControls.includes(old)) {
        old.classList.remove("cg-ios16-home-topbar-control");
      }
    }
    // Learn labelled artwork before resolving unlabelled controls.
    scaleControls.forEach(iconIdentity);
    for (const old of document.querySelectorAll("[data-cg-icon-role]")) {
      if (!scaleControls.includes(old)) old.removeAttribute("data-cg-icon-role");
    }
    for (const element of scaleControls) {
      const role = iconIdentity(element);
      if (role) {
        if (element.getAttribute("data-cg-icon-role") !== role)
          element.setAttribute("data-cg-icon-role", role);
      } else element.removeAttribute("data-cg-icon-role");
      element.classList.add("cg-ios16-topbar-control");
      if (homeHeader) element.classList.add("cg-ios16-home-topbar-control");
    }

    // Home page: keep ChatGPT's native white header completely untouched,
    // including the partial loading state before Chat/Work exists in the DOM.
    // The left/right icon controls above are enlarged to 1.40x, but do
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
      Math.min(bestRect.height, Math.ceil(rowBottom - bestRect.top)) -
        HEADER_WHITE_BAR_TRIM_PX
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

  // A pencil has a long diagonal stroke; the sidebar toggle's square and
  // vertical divider do not. Read SVG geometry rather than guessing which
  // header icon comes first when React swaps the two controls.
  function looksLikeNewChatPencil(svg) {
    for (const line of svg.querySelectorAll("line")) {
      const dx = Math.abs(Number(line.getAttribute("x2")) - Number(line.getAttribute("x1")));
      const dy = Math.abs(Number(line.getAttribute("y2")) - Number(line.getAttribute("y1")));
      if (dx > 4.5 && dy > 4.5 && dx / dy > 0.6 && dx / dy < 1.7) return true;
    }
    for (const path of svg.querySelectorAll("path")) {
      if (typeof path.getTotalLength !== "function" ||
          typeof path.getPointAtLength !== "function") continue;
      try {
        const len = path.getTotalLength();
        for (let at = 0; at + 7.5 <= len; at += 2) {
          const a = path.getPointAtLength(at);
          const b = path.getPointAtLength(at + 7.5);
          const dx = Math.abs(a.x - b.x), dy = Math.abs(a.y - b.y);
          if (dx > 4.5 && dy > 4.5 && dx / dy > 0.6 && dx / dy < 1.7) return true;
        }
      } catch (_) { /* Skip unsupported path geometry. */ }
    }
    return false;
  }

  // Called from the EXISTING ink-only recovery function: no Share sizing,
  // no full-header row detection, no change to sidebar button scale.
  function restoreMainHeaderLeftIconSizes(chosenSvgs) {
    const panelSelector = "#browser-sidebar-popover, #stage-popover-sidebar, " +
      "#stage-slideover-sidebar, #sidebar-container, #sidebar-header, " +
      "nav[aria-label='Chat history'], aside, [role='dialog'], [aria-modal='true']";
    const pair = [];
    for (const svg of chosenSvgs) {
      const button = svg.closest("button, [role='button'], a[href]");
      if (!button || button.closest(panelSelector) ||
          pair.some(item => item.button === button)) continue;
      const rect = button.getBoundingClientRect();
      if (rect.left < -12 || rect.right > innerWidth * 0.44 ||
          rect.top < -12 || rect.bottom > 165) continue;
      pair.push({button, svg, centerY: rect.top + rect.height / 2});
    }
    // No guessing when a partial panel or overlay only exposes one glyph.
    if (pair.length !== 2 || Math.abs(pair[0].centerY - pair[1].centerY) > 24) return;

    const roles = pair.map(({button}) => iconIdentity(button));
    if (roles[0] === roles[1] || roles.some(role => !role)) {
      const pencilIndices = pair.map(({svg}) => looksLikeNewChatPencil(svg));
      if (pencilIndices.filter(Boolean).length === 1) {
        roles[pencilIndices.indexOf(true)] = "new";
        roles[pencilIndices.indexOf(false)] = "sidebar";
      } else if (roles.filter(role => role === "new").length === 1) {
        roles[roles.indexOf("")] = "sidebar";
      } else if (roles.filter(role => role === "sidebar").length === 1) {
        roles[roles.indexOf("")] = "new";
      }
    }
    pair.forEach(({button}, index) => {
      // One-way class for the lifetime of this header button. Even if the
      // normal topbar row calculation drops its size on sidebar close, the
      // independent class keeps the original 1.40x / 1.50x scaling.
      button.classList.add("cg-ios16-left-header-size-stable");
      const role = roles[index];
      if (role === "new" || role === "sidebar") {
        button.setAttribute("data-cg-left-header-icon", role);
      }
    });
  }

  // v1.01: use actual SVG geometry, not the parent button's identity.
  // In the user's screenshots the sidebar icon remains #878787 whether it is
  // on the left OR right, while the adjacent pencil is #000000. That can be
  // caused by a missing button match or intermediate wrapper opacity.
  function makeTopLeftHeaderIconsBlack() {
    const svgMarker = "cg-ios16-direct-black-svg";
    const wrapperMarker = "cg-ios16-direct-black-wrapper";
    const candidates = [];
    for (const svg of document.querySelectorAll("svg")) {
      const art = svg.getBoundingClientRect();
      if (art.width < 15 || art.height < 15 ||
          art.width > 90 || art.height > 90 ||
          art.top < -10 || art.top > 112 ||
          art.bottom > 155 ||
          art.left < -10 || art.left > innerWidth * 0.43) continue;
      if (svg.closest("#browser-sidebar-popover, nav[aria-label='Chat history'], [data-message-author-role], [data-testid^='conversation-turn']")) continue;
      const computed = getComputedStyle(svg);
      if (computed.display === "none" || computed.visibility === "hidden") continue;
      const control = svg.closest("button, [role='button'], a[href]");
      if (control && /^(ChatGPT|Share)$/i.test(normalizedText(control))) continue;
      candidates.push({svg, x: art.left, y: art.top});
    }
    // At the header's far left there are exactly two icons. Select by
    // physical position so the pencil and sidebar can freely exchange sides.
    candidates.sort((a, b) => a.x - b.x || a.y - b.y);
    const chosen = new Set(candidates.slice(0, 2).map(item => item.svg));
    restoreMainHeaderLeftIconSizes(chosen);
    const wrappers = new Set();
    for (const svg of chosen) {
      // Even a black SVG will render grey if a surrounding element has
      // opacity:0.5. Unfade only its SMALL icon-sized ancestor wrappers.
      for (let el = svg.parentElement, depth = 0;
           el && depth < 7 && el !== document.body; el = el.parentElement, depth++) {
        const r = el.getBoundingClientRect();
        if (r.width > 120 || r.height > 120 ||
            r.top < -12 || r.top > 115) break;
        wrappers.add(el);
      }
    }
    // Confirmed header buttons retain ink through the persistent selector
    // above even if a later scroll puts another SVG before them in candidates.
    // Never unmark them on partial/ambiguous geometry.
    // v1.09: keep already-confirmed header glyphs black for their entire DOM
    // lifetime. During streaming or return-to-chat scrolling, React briefly
    // shifts/reflows the header. Geometry checks can then yield fewer than
    // two candidates and v1.08 removed the black classes, turning icons grey.
    // A detached glyph cannot render, so React removing old nodes is enough
    // cleanup. New header glyphs are still detected and marked below.
    for (const svg of chosen) svg.classList.add(svgMarker);
    for (const wrapper of wrappers) wrapper.classList.add(wrapperMarker);
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

  // Message streams change hundreds of text/child nodes without changing
  // the header. Never rerun topbar row classification for those updates.
  // However, React replacing an actual header button must be detected before
  // paint, so examine the specific mutated subtree rather than the whole page.
  function mutationChangesHeader(mutations) {
    const header = "header, [role='banner'], #page-header, " +
      "#conversation-header-actions, .cg-ios16-topbar-control, " +
      ".cg-ios16-share-control-stable";
    const content = "[data-message-author-role], " +
      "[data-testid^='conversation-turn'], [role='log']";
    for (const mutation of mutations) {
      const target = mutation.target.nodeType === 1 ?
        mutation.target : mutation.target.parentElement;
      if (!target) continue;
      if (target.closest(content)) continue;
      if (target.closest("#browser-sidebar-popover, " +
        "#stage-popover-sidebar, #stage-slideover-sidebar")) continue;
      if (target.closest(header)) return true;
      if (mutation.type === "childList") {
        for (const node of [...mutation.addedNodes, ...mutation.removedNodes]) {
          if (node.nodeType !== 1) continue;
          if (node.matches(header)) return true;
          if ((target === document.body || target === document.documentElement) &&
              node.querySelector(header)) return true;
        }
      }
    }
    return false;
  }

  // In a Gecko sidebar transition the full-width conversation header can be
  // reparented without the observer classifying it as a HEADER mutation.
  // Recover only the previously working white strip; importantly this does
  // not touch any header button sizes or the independent Share marker.
  function restoreConversationHeaderBackground() {
    if (window.location.pathname === "/" ||
        window.location.pathname === "" || !document.body) return false;
    const panelSelector = "#browser-sidebar-popover, #stage-popover-sidebar, " +
      "#stage-slideover-sidebar, #sidebar-container, #sidebar-header, " +
      "nav[aria-label='Chat history'], aside, [role='dialog'], [aria-modal='true']";
    const controls = Array.from(document.querySelectorAll("button, [role='button'], a"));
    const isRealTopControl = element => {
      if (element.closest(panelSelector)) return false;
      const r = element.getBoundingClientRect();
      return r.width >= 18 && r.height >= 18 && r.top >= -12 &&
        r.top <= 145 && r.right > 0 && r.left < innerWidth;
    };
    // Prefer Share (the persistent chat-header control), never a chat-body
    // Share action. Use one of the already-marked LEFT header controls only
    // if ChatGPT temporarily hides Share.
    const share = controls.find(element => {
      if (!isRealTopControl(element)) return false;
      const label = (element.getAttribute("aria-label") || "").trim().toLowerCase();
      const title = (element.getAttribute("title") || "").trim().toLowerCase();
      const text = normalizedText(element).toLowerCase();
      return text === "share" || label === "share" || title === "share" ||
        label.startsWith("share ") || title.startsWith("share ");
    });
    const left = controls.filter(element =>
      isRealTopControl(element) &&
      (element.classList.contains("cg-ios16-left-header-size-stable") ||
       element.classList.contains("cg-ios16-topbar-control")) &&
      element.getBoundingClientRect().left < innerWidth * 0.45
    );
    const anchor = share || left[0];
    if (!anchor) return false;

    const possible = [];
    for (let node = anchor; node && node !== document.body &&
         node !== document.documentElement; node = node.parentElement) {
      const r = node.getBoundingClientRect();
      if (r.top > 105 || r.bottom < 30 || r.height < 42 ||
          r.height > 160 || r.width < innerWidth * 0.92) continue;
      if (r.left > 16 || r.right < innerWidth - 16) continue;
      possible.push({node, rect:r});
    }
    if (!possible.length) return false;
    possible.sort((a, b) => {
      const aFull = a.rect.width >= innerWidth * 0.96;
      const bFull = b.rect.width >= innerWidth * 0.96;
      if (aFull !== bFull) return aFull ? -1 : 1;
      if (Math.abs(a.rect.width - b.rect.width) > 2)
        return b.rect.width - a.rect.width;
      return a.rect.height - b.rect.height;
    });
    const best = possible[0].node;
    const r = possible[0].rect;
    let lastButtonBottom = anchor.getBoundingClientRect().bottom;
    for (const control of left) {
      lastButtonBottom = Math.max(lastButtonBottom, control.getBoundingClientRect().bottom);
    }
    const cutoff = Math.max(0,
      Math.min(r.height, Math.ceil(lastButtonBottom - r.top)) -
      HEADER_WHITE_BAR_TRIM_PX
    );
    if (cutoff < 24) return false;
    for (const old of document.querySelectorAll(".cg-ios16-solid-topbar")) {
      if (old !== best) {
        old.classList.remove("cg-ios16-solid-topbar");
        old.style.removeProperty("--cg-ios16-topbar-bg");
        old.style.removeProperty("--cg-ios16-topbar-cutoff");
        delete old.dataset.cgIos16SolidTopbar;
      }
    }
    best.style.setProperty("--cg-ios16-topbar-bg", renderedBackgroundColor(share || anchor));
    best.style.setProperty("--cg-ios16-topbar-cutoff", `${cutoff}px`);
    best.classList.add("cg-ios16-solid-topbar");
    best.dataset.cgIos16SolidTopbar = "1";
    return true;
  }

  // A stale .cg-ios16-solid-topbar class can survive React/Gecko's
  // last-chat restore on an old or collapsed header. Only count a strip as
  // restored when it covers the current, visible controls and has a
  // meaningful painted cutoff. This is much cheaper than a full page rescan.
  function hasUsableConversationHeaderBackground() {
    if (window.location.pathname === "/" || window.location.pathname === "")
      return true;
    const header = document.querySelector(".cg-ios16-solid-topbar");
    if (!header || !header.isConnected) return false;
    const rect = header.getBoundingClientRect();
    const cutoff = parseFloat(header.style.getPropertyValue("--cg-ios16-topbar-cutoff"));
    if (rect.top > 105 || rect.bottom < 30 || rect.height < 42 ||
        rect.width < innerWidth * 0.88 || !Number.isFinite(cutoff) ||
        cutoff < 24 || cutoff > rect.height + 4) return false;
    // An obsolete full-width container with a class but no active toolbar
    // must not block a new header from receiving its white background.
    if (!header.querySelector(
      ".cg-ios16-left-header-size-stable, .cg-ios16-share-control-stable, " +
      ".cg-ios16-topbar-control"
    )) return false;
    return true;
  }

  function applyAppPresentation(updateHeader = true) {
    installStyle();
    dismissAppPromotion();
    if (updateHeader) {
      // Header sizing must not rerun for streaming text/tool progress.
      stabilizeTopActionBar();
    }
    // Icon ink is a separate concern: Gecko/React can replace or unmount
    // the left sidebar SVG while the chat is streaming. Detect and mark
    // newly mounted header SVGs on ordinary updates WITHOUT touching the
    // control sizing, Share marker, or header row classification.
    makeTopLeftHeaderIconsBlack();
    // A restored chat may retain an OLD background class on a collapsed
    // toolbar. Check whether the CURRENT visible header has a painted
    // cutoff, rather than testing only whether the class exists anywhere.
    // Keep this recovery independent of Share and header sizing.
    if (!hasUsableConversationHeaderBackground())
      restoreConversationHeaderBackground();
    hideSuggestion();
    hideDisclaimers();
    if (document.body) revealCleanPage();
  }

  let timer = null;
  let pendingHeaderUpdate = false;
  function schedule(updateHeader = true) {
    pendingHeaderUpdate = pendingHeaderUpdate || updateHeader;
    // Do NOT clear/restart the timer on every mutation. During chat restore,
    // batch non-content updates to avoid repeated document-wide SVG scans.
    // A bounded 160ms throttle prevents continuous updates from starving the
    // header without running the full presentation pass 16 times a second.
    if (timer !== null) return;
    timer = setTimeout(() => {
      timer = null;
      const doHeader = pendingHeaderUpdate;
      pendingHeaderUpdate = false;
      if (!document.hidden) applyAppPresentation(doHeader);
    }, 160);
  }

  installStyle();
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => applyAppPresentation(true), { once: true });
  } else {
    applyAppPresentation(true);
  }

  // v1.25: chat streaming and catch-up can generate hundreds of mutations.
  // They do not need any header or styling pass while only message content
  // changed. Header replacements still trigger a normal scheduled refresh.
  function isChatContentMutation(mutation) {
    const node = mutation.target.nodeType === 1 ?
      mutation.target : mutation.target.parentElement;
    return !!node?.closest?.(
      "[data-message-author-role], [data-testid^='conversation-turn'], [role='log']"
    );
  }
  const observer = new MutationObserver((mutations) => {
    if (document.hidden) return;
    const headerChanged = mutationChangesHeader(mutations);
    if (!headerChanged && mutations.every(isChatContentMutation)) return;
    // Preserve synchronous hiding of genuine app promotions, but don't
    // rescan the entire document for every appended streaming text node.
    dismissAppPromotion();
    schedule(headerChanged);
  });
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true,
    attributes: true,
    attributeFilter: ["aria-label", "title", "data-testid", "d", "href", "xlink:href", "viewBox", "x", "y", "x1", "x2", "y1", "y2", "width", "height", "points", "cx", "cy", "r"]
  });
  // Sidebar open/close and iOS lock-screen wake can change toolbar
  // geometry/replace its SVG without producing one of the watched text
  // mutations. Refresh ONLY the ink/opacity classes after the UI settles.
  // Do not call stabilizeTopActionBar here: Share must keep its v1.13 size.
  let inkRecoveryTimers = [];
  let lastRecoveryStarted = 0;
  function recoverHeaderInkAfterTransition() {
    if (document.hidden) return;
    // focus + pageshow + visibilitychange are frequently delivered together
    // on app resume. Treat them as ONE recovery, not three full SVG scans
    // and three overlapping sets of five timers.
    const now = Date.now();
    if (now - lastRecoveryStarted < 250) return;
    lastRecoveryStarted = now;
    for (const timerId of inkRecoveryTimers) clearTimeout(timerId);
    inkRecoveryTimers = [];
    function recoverInkAndWhiteStrip() {
      if (document.hidden) return;
      makeTopLeftHeaderIconsBlack();
      if (!hasUsableConversationHeaderBackground())
        restoreConversationHeaderBackground();
    }
    recoverInkAndWhiteStrip();
    requestAnimationFrame(recoverInkAndWhiteStrip);
    // Retain a late pass for restored chats whose headers mount slowly.
    // Each pass is conditional and does not cause periodic background work.
    for (const delay of [160, 600, 1600, 3200]) {
      inkRecoveryTimers.push(setTimeout(() => {
        if (!document.hidden) recoverInkAndWhiteStrip();
      }, delay));
    }
  }

  function sidebarInteraction(event) {
    const target = event.target?.nodeType === 1 ?
      event.target : event.target?.parentElement;
    if (!target || !target.closest) return false;
    if (target.closest(
      "#browser-sidebar-popover, #stage-popover-sidebar, " +
      "#stage-slideover-sidebar, #sidebar-container"
    )) return true;
    const control = target.closest("button, a, [role='button']");
    if (control) {
      const bounds = control.getBoundingClientRect();
      const identity = [
        control.getAttribute("aria-label"),
        control.getAttribute("title"),
        control.getAttribute("data-testid")
      ].filter(Boolean).join(" ").toLowerCase();
      if (/sidebar|side[ _-]?panel|toggle[ _-]?navigation|new[ _-]?chat/.test(identity))
        return true;
      // The two left header glyphs can swap order and be unlabelled.
      if (bounds.top >= -10 && bounds.bottom <= 165 &&
          bounds.left >= -12 && bounds.right <= innerWidth * 0.43) return true;
    }
    // Tapping the backdrop closes a sidebar without touching its buttons.
    const sidebar = document.getElementById("browser-sidebar-popover");
    return !!sidebar && sidebar.getBoundingClientRect().width > 50;
  }

  document.addEventListener("click", event => {
    if (sidebarInteraction(event)) recoverHeaderInkAfterTransition();
  }, true);
  // Some sidebar views dismiss by a gesture rather than a normal click.
  document.addEventListener("transitionend", event => {
    const target = event.target;
    if (target?.nodeType === 1 && target.closest?.(
      "#browser-sidebar-popover, #stage-popover-sidebar, #stage-slideover-sidebar"
    )) recoverHeaderInkAfterTransition();
  }, true);
  document.addEventListener("keyup", event => {
    if (event.key === "Escape") recoverHeaderInkAfterTransition();
  }, true);

  // When returning from the lock screen, a visibility/focus event can occur
  // before Gecko finishes rebuilding controls. Delayed passes cover that.
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) recoverHeaderInkAfterTransition();
  });
  window.addEventListener("pageshow", recoverHeaderInkAfterTransition);
  window.addEventListener("focus", recoverHeaderInkAfterTransition);

  window.addEventListener("resize", () => {
    schedule(true);
    recoverHeaderInkAfterTransition();
  }, { passive: true });
  window.addEventListener("popstate", () => {
    schedule(true);
    recoverHeaderInkAfterTransition();
  });
})();
