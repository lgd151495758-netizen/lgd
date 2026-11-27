// Quillmark in-page ink runtime.
// Renders strokes as SVG attached to page elements and keeps them in place while the page
// reflows (expand/collapse, rotation, images loading). Reports stroke positions to the app.
(function () {
  'use strict';
  if (window.__qm) { return; }

  var NS = 'http://www.w3.org/2000/svg';
  var Z_HIGHLIGHT = '2147483000';
  var Z_TAPE = '2147483001';
  var Z_INK = '2147483002';

  // No z-index on the layer: it must not create a stacking context, otherwise the
  // highlighter's multiply blend could not reach the page underneath.
  var layer = document.createElement('div');
  layer.id = '__qm_layer';
  layer.setAttribute('aria-hidden', 'true');
  layer.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;margin:0;padding:0;border:0;' +
    'overflow:visible;pointer-events:none;';

  var strokes = new Map(); // id -> { svg, anchor, el }
  var scheduled = false;
  var lastReport = '';
  var resizeObserver = null;
  var observed = new WeakSet();

  function post(message) {
    try { window.webkit.messageHandlers.qm.postMessage(message); } catch (e) { /* not in the app */ }
  }

  function ensureLayer() {
    if (!layer.isConnected) { document.documentElement.appendChild(layer); }
  }

  function normText(el) {
    return (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
  }

  function cssPath(el) {
    if (!el || el === document.body || el === document.documentElement) { return 'body'; }
    var parts = [];
    while (el && el.nodeType === 1 && el !== document.body && el !== document.documentElement) {
      if (el.id) {
        var idSelector = '#' + CSS.escape(el.id);
        if (document.querySelectorAll(idSelector).length === 1) { parts.unshift(idSelector); return parts.join(' > '); }
      }
      var index = 1;
      var sibling = el;
      while ((sibling = sibling.previousElementSibling)) {
        if (sibling.tagName === el.tagName) { index++; }
      }
      parts.unshift(el.tagName.toLowerCase() + ':nth-of-type(' + index + ')');
      el = el.parentElement;
    }
    parts.unshift('body');
    return parts.join(' > ');
  }

  function resolve(anchor) {
    if (!anchor || anchor.selector === 'body') { return document.body; }
    var el = null;
    try { el = document.querySelector(anchor.selector); } catch (e) { el = null; }
    if (el && (!anchor.fingerprint || normText(el) === anchor.fingerprint)) { return el; }
    if (anchor.fingerprint) {
      var candidates = document.getElementsByTagName(anchor.tag || '*');
      for (var i = 0; i < candidates.length; i++) {
        if (!layer.contains(candidates[i]) && normText(candidates[i]) === anchor.fingerprint) { return candidates[i]; }
      }
    }
    return el;
  }

  function docRect(el) {
    var r = el.getBoundingClientRect();
    return { x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height };
  }

  function isShown(el, rect) {
    if (el === document.body) { return true; }
    if (!el.isConnected || (rect.w === 0 && rect.h === 0)) { return false; }
    return getComputedStyle(el).visibility !== 'hidden';
  }

  function observe(el) {
    if (el && resizeObserver && !observed.has(el)) {
      observed.add(el);
      resizeObserver.observe(el);
    }
  }

  function layout() {
    scheduled = false;
    if (!document.body) { return; }
    ensureLayer();
    var origin = docRect(layer);
    var cache = new Map();
    var report = {};
    strokes.forEach(function (s, id) {
      if (!s.el || !s.el.isConnected) {
        s.el = resolve(s.anchor);
        observe(s.el);
      }
      var info = cache.get(s.el);
      if (!info) {
        if (!s.el) {
          info = { x: 0, y: 0, shown: false };
        } else {
          var r = docRect(s.el);
          info = { x: r.x, y: r.y, shown: isShown(s.el, r) };
        }
        cache.set(s.el, info);
      }
      var nextDisplay = info.shown ? '' : 'none';
      if (s.lastDisplay !== nextDisplay) {
        s.svg.style.display = nextDisplay;
        s.lastDisplay = nextDisplay;
      }
      var nextTransform = 'translate(' + (info.x - origin.x) + 'px,' + (info.y - origin.y) + 'px)';
      if (s.lastTransform !== nextTransform) {
        s.svg.style.transform = nextTransform;
        s.lastTransform = nextTransform;
      }
      report[id] = [info.x, info.y, info.shown ? 1 : 0];
    });
    var json = JSON.stringify(report);
    if (json !== lastReport) {
      lastReport = json;
      post({ type: 'layout', strokes: report });
    }
  }

  function schedule() {
    if (!scheduled) {
      scheduled = true;
      requestAnimationFrame(layout);
    }
  }

  function makeSVG(stroke) {
    var svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('width', '1');
    svg.setAttribute('height', '1');
    var style = 'position:absolute;left:0;top:0;overflow:visible;pointer-events:none;';
    if (stroke.hl) {
      style += 'z-index:' + Z_HIGHLIGHT + ';mix-blend-mode:multiply;opacity:0.6;';
    } else if (stroke.tape) {
      style += 'z-index:' + Z_TAPE + ';';
    } else {
      style += 'z-index:' + Z_INK + ';';
    }
    svg.style.cssText = style;
    if (stroke.fillD && stroke.fillColor) {
      var fillEl = document.createElementNS(NS, 'path');
      fillEl.setAttribute('d', stroke.fillD);
      fillEl.setAttribute('fill', stroke.fillColor);
      fillEl.setAttribute('fill-opacity', '0.18');
      svg.appendChild(fillEl);
    }
    var path = document.createElementNS(NS, 'path');
    path.setAttribute('d', stroke.d);
    path.setAttribute('fill', stroke.color);
    if (stroke.tape) {
      path.style.pointerEvents = 'auto';
      path.style.cursor = 'pointer';
      if (stroke.revealed) {
        path.setAttribute('fill-opacity', '0.14');
        path.setAttribute('stroke', 'rgba(0,0,0,0.28)');
        path.setAttribute('stroke-width', '1.2');
        path.setAttribute('stroke-dasharray', '4 4');
      } else {
        path.setAttribute('fill-opacity', '0.98');
        path.setAttribute('stroke', 'rgba(0,0,0,0.22)');
        path.setAttribute('stroke-width', '1');
        path.setAttribute('stroke-dasharray', '5 3');
      }
      path.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        post({ type: 'toggleTape', id: stroke.id });
      });
    }
    svg.appendChild(path);
    return svg;
  }

  function pickAnchor(x, y) {
    var vx = x - window.scrollX;
    var vy = y - window.scrollY;
    var el = null;
    if (document.elementsFromPoint) {
      var stack = document.elementsFromPoint(vx, vy) || [];
      for (var i = 0; i < stack.length; i++) {
        if (stack[i] !== layer && !layer.contains(stack[i])) {
          el = stack[i];
          break;
        }
      }
    }
    if (!el) {
      el = document.elementFromPoint(vx, vy) || document.body;
    }
    while (el && el !== document.body && el !== document.documentElement) {
      if (el !== layer && !layer.contains(el)) {
        var display = getComputedStyle(el).display;
        var r = el.getBoundingClientRect();
        if (display !== 'inline' && display !== 'contents' && r.width >= 12 && r.height >= 12) { break; }
      }
      el = el.parentElement;
    }
    if (!el || el === document.documentElement) { el = document.body; }
    var rect = docRect(el);
    return {
      selector: cssPath(el),
      fingerprint: el === document.body ? '' : normText(el),
      tag: el.tagName,
      x: rect.x,
      y: rect.y
    };
  }

  window.__qm = {
    apply: function (ops) {
      ensureLayer();
      (ops.remove || []).forEach(function (id) {
        var s = strokes.get(id);
        if (s) { s.svg.remove(); strokes.delete(id); }
      });
      (ops.add || []).forEach(function (stroke) {
        var old = strokes.get(stroke.id);
        if (old) { old.svg.remove(); }
        var svg = makeSVG(stroke);
        layer.appendChild(svg);
        strokes.set(stroke.id, { svg: svg, anchor: stroke.anchor, el: null, lastDisplay: null, lastTransform: null });
      });
      if (ops.order) {
        // Minimal-diff DOM reordering: only insert moved/new SVGs instead of re-appending every stroke.
        var expected = layer.firstChild;
        for (var i = 0; i < ops.order.length; i++) {
          var s = strokes.get(ops.order[i]);
          if (!s) { continue; }
          if (s.svg !== expected) {
            layer.insertBefore(s.svg, expected);
          } else {
            expected = expected.nextSibling;
          }
        }
      }
      layout();
      return strokes.size;
    },
    pickAnchor: pickAnchor,
    positions: function () {
      lastReport = '';
      layout();
      return JSON.parse(lastReport || '{}');
    },
    count: function () { return strokes.size; },
    setImageTapGuard: function (enabled) {
      imageTapGuardEnabled = !!enabled;
      lastGuardTap = { el: null, time: 0, x: 0, y: 0 };
    }
  };

  // Guard zoomable images & large static diagrams against accidental single-tap lightbox pops
  // during iPad lectures, while leaving all buttons, links, accordions, quiz controls, cover
  // tapes, interactive widgets, and open modal close actions 100% single-tap responsive.
  var imageTapGuardEnabled = true;
  var DOUBLE_TAP_MS = 420;
  var DOUBLE_TAP_DIST_SQ = 56 * 56;
  var lastGuardTap = { el: null, time: 0, x: 0, y: 0 };
  var lastGuardHintAt = 0;

  var INTERACTIVE_ANCESTOR_SELECTOR =
    'button, a[href], input, select, textarea, summary, label, option, canvas, video, audio, ' +
    '[role="button"], [role="link"], [role="tab"], [role="switch"], [role="checkbox"], ' +
    '[role="radio"], [role="menuitem"], [role="option"], [role="slider"], [role="combobox"], ' +
    '[data-qm-single-tap="true"]';
  var ZOOM_CLASS_RE = /\b(zoom|lightbox|modal|preview|fig|figure|diagram|img|image|photo|pic|origin|vector|compare|media)/i;
  var CONTROL_CLASS_RE = /\b(btn|button|tab|toggle|collapse|accordion|header|toolbar|nav|menu|opt|option|choice|chip|step|close|dismiss|action)\b/i;

  function elementOf(node) {
    if (!node) { return null; }
    return node.nodeType === 1 ? node : node.parentElement;
  }

  function isInsideOpenOverlay(el) {
    var vw = window.innerWidth || document.documentElement.clientWidth || 0;
    var vh = window.innerHeight || document.documentElement.clientHeight || 0;
    var cur = el;
    while (cur && cur !== document.body && cur !== document.documentElement) {
      var role = cur.getAttribute ? cur.getAttribute('role') : null;
      if (role === 'dialog' || role === 'alertdialog' ||
          (cur.getAttribute && cur.getAttribute('aria-modal') === 'true') ||
          (cur.tagName === 'DIALOG' && cur.hasAttribute('open'))) {
        return true;
      }
      var style = getComputedStyle(cur);
      if (style.position === 'fixed' && vw > 0 && vh > 0) {
        var r = cur.getBoundingClientRect();
        if (r.width >= vw * 0.55 && r.height >= vh * 0.55) {
          return true;
        }
      }
      cur = cur.parentElement;
    }
    return false;
  }

  function hasZoomCues(el) {
    var cur = el;
    for (var depth = 0; cur && depth < 3 && cur !== document.body && cur !== document.documentElement; depth++) {
      var tag = cur.tagName;
      if (tag === 'SECTION' || tag === 'ARTICLE' || tag === 'MAIN') { break; }
      if (cur.hasAttribute && (cur.hasAttribute('onclick') || cur.hasAttribute('data-zoom') || cur.hasAttribute('data-lightbox'))) {
        return true;
      }
      var cursor = getComputedStyle(cur).cursor;
      if (cursor === 'zoom-in' || cursor === 'pointer') {
        return true;
      }
      var cls = typeof cur.className === 'string' ? cur.className : (cur.getAttribute ? (cur.getAttribute('class') || '') : '');
      var id = cur.id || '';
      if (tag === 'FIGURE' || ZOOM_CLASS_RE.test(cls) || ZOOM_CLASS_RE.test(id)) {
        return true;
      }
      cur = cur.parentElement;
    }
    return false;
  }

  function isInteractiveSVGSubcontrol(target, svg) {
    var cur = target;
    while (cur && cur !== svg) {
      if (cur.hasAttribute && (cur.hasAttribute('onclick') || cur.getAttribute('role') === 'button' || cur.hasAttribute('data-interactive'))) {
        return true;
      }
      var cursor = getComputedStyle(cur).cursor;
      if (cursor === 'grab' || cursor === 'grabbing' || cursor === 'move' ||
          cursor === 'ew-resize' || cursor === 'ns-resize' || cursor === 'nwse-resize' || cursor === 'nesw-resize') {
        return true;
      }
      cur = cur.parentElement;
    }
    return false;
  }

  function findGuardedMediaTarget(rawTarget) {
    var el = elementOf(rawTarget);
    if (!el || el === layer || layer.contains(el)) { return null; }
    if (el.closest && el.closest(INTERACTIVE_ANCESTOR_SELECTOR)) { return null; }
    if (isInsideOpenOverlay(el)) { return null; }

    // 1. Direct <img> or <picture> (skip tiny icons < 48px).
    var img = el.tagName === 'IMG' ? el : (el.closest ? el.closest('picture') : null);
    if (img) {
      var ir = img.getBoundingClientRect();
      if (ir.width >= 48 || ir.height >= 48) { return img; }
      return null;
    }

    // 2. Large diagram <svg> (skip KaTeX/MathJax math glyphs, tiny icons, and interactive SVG sub-controls).
    var svg = el.closest ? el.closest('svg') : null;
    if (svg && !layer.contains(svg)) {
      if (svg.closest && svg.closest('.katex, .MathJax, mjx-container')) { return null; }
      var sr = svg.getBoundingClientRect();
      if (sr.width >= 72 && sr.height >= 56 && !isInteractiveSVGSubcontrol(el, svg)) {
        var svgCursor = getComputedStyle(svg).cursor;
        if (svgCursor === 'crosshair' || svgCursor === 'grab' || svgCursor === 'grabbing' || svgCursor === 'move') {
          return null;
        }
        if (hasZoomCues(svg)) {
          return svg;
        }
      }
      return null;
    }

    // 3. Direct figure/image wrapper padding (e.g. <div class="fig-box" onclick="..."> around an <img>/<svg>).
    if (el.tagName !== 'BODY' && el.tagName !== 'HTML') {
      var cls = typeof el.className === 'string' ? el.className : '';
      var id = el.id || '';
      if (!CONTROL_CLASS_RE.test(cls) && !CONTROL_CLASS_RE.test(id) &&
          !el.querySelector(INTERACTIVE_ANCESTOR_SELECTOR)) {
        var media = el.querySelector('img, svg');
        if (media && !layer.contains(media)) {
          var mr = media.getBoundingClientRect();
          var textLen = (el.textContent || '').trim().length;
          var style = getComputedStyle(el);
          if ((mr.width >= 48 || mr.height >= 48) && textLen <= 80 &&
              (el.tagName === 'FIGURE' || style.cursor === 'zoom-in' ||
               (style.cursor === 'pointer' && (ZOOM_CLASS_RE.test(cls) || ZOOM_CLASS_RE.test(id))))) {
            return el;
          }
        }
      }
    }
    return null;
  }

  function handleImageTapGuard(e) {
    if (!imageTapGuardEnabled || e.defaultPrevented) { return; }
    var guarded = findGuardedMediaTarget(e.target);
    if (!guarded) { return; }

    var now = Date.now();
    var x = typeof e.clientX === 'number' ? e.clientX : 0;
    var y = typeof e.clientY === 'number' ? e.clientY : 0;
    var dx = x - lastGuardTap.x;
    var dy = y - lastGuardTap.y;
    var isDoubleTap = (lastGuardTap.el === guarded) &&
      ((now - lastGuardTap.time) <= DOUBLE_TAP_MS) &&
      ((dx * dx + dy * dy) <= DOUBLE_TAP_DIST_SQ);

    if (isDoubleTap) {
      lastGuardTap = { el: null, time: 0, x: 0, y: 0 };
      return;
    }

    lastGuardTap = { el: guarded, time: now, x: x, y: y };
    e.preventDefault();
    e.stopImmediatePropagation();
    if (hasZoomCues(guarded) && (now - lastGuardHintAt) > 1200) {
      lastGuardHintAt = now;
      post({ type: 'imageTapGuarded' });
    }
  }
  window.addEventListener('click', handleImageTapGuard, { capture: true });

  // Re-place ink whenever the page may have moved. Mutations of our own layer are ignored.
  new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i++) {
      var target = records[i].target;
      if (target !== layer && !layer.contains(target)) { schedule(); return; }
    }
  }).observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
  if (window.ResizeObserver) {
    resizeObserver = new ResizeObserver(schedule);
    resizeObserver.observe(document.documentElement);
  }
  window.addEventListener('resize', schedule);
  document.addEventListener('scroll', schedule, true);
  document.addEventListener('load', schedule, true);
  document.addEventListener('transitionend', schedule, true);
  document.addEventListener('animationend', schedule, true);
  document.addEventListener('toggle', schedule, true);

  // Wake smart projection to full 24fps during live finger interaction with canvas/sliders/buttons.
  var lastActivityPost = 0;
  function notifyActivity() {
    var now = Date.now();
    if (now - lastActivityPost > 300) {
      lastActivityPost = now;
      post({ type: 'activity' });
    }
  }
  window.addEventListener('pointerdown', notifyActivity, { passive: true, capture: true });
  window.addEventListener('pointermove', function (e) {
    if (e.buttons || e.pressure > 0) { notifyActivity(); }
  }, { passive: true, capture: true });
  window.addEventListener('input', notifyActivity, { passive: true, capture: true });

  // Prevent WebKit text selection / Scribble from reacting to Apple Pencil touches.
  window.addEventListener('pointerdown', function (e) {
    if (e.pointerType === 'pen') { e.preventDefault(); }
  }, { passive: false, capture: true });
  window.addEventListener('touchstart', function (e) {
    if (e.touches && e.touches.length === 1 && e.touches[0].touchType === 'stylus') { e.preventDefault(); }
  }, { passive: false, capture: true });

  ensureLayer();
  post({ type: 'ready' });
})();
