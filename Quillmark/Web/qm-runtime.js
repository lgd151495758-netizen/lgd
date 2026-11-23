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
    count: function () { return strokes.size; }
  };

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
