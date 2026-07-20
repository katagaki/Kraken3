import Foundation

let controlPageHTML = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>Kraken</title>
<style>
  :root {
    --cds-background: #161616;
    --cds-layer: #262626;
    --cds-layer-active: #525252;
    --cds-layer-hover: #333333;
    --cds-field: #262626;
    --cds-field-02: #393939;
    --cds-border-subtle: #393939;
    --cds-border-strong: #6f6f6f;
    --cds-text-primary: #f4f4f4;
    --cds-text-secondary: #c6c6c6;
    --cds-text-helper: #8d8d8d;
    --cds-icon-disabled: #525252;
    --cds-interactive: #0f62fe;
    --cds-interactive-active: #002d9c;
    --cds-focus: #ffffff;
    --cds-overlay: rgba(22,22,22,0.7);
  }
  * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body {
    height: 100%;
    background: var(--cds-background);
    color: var(--cds-text-primary);
    font-family: -apple-system, system-ui, sans-serif;
    overflow: hidden;
    overscroll-behavior: none;
    user-select: none;
    -webkit-user-select: none;
    -webkit-touch-callout: none;
  }
  input, textarea {
    user-select: text;
    -webkit-user-select: text;
  }
  #app { display: flex; flex-direction: column; height: 100%; }

  #topbar {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 4px 8px;
    padding-bottom: calc(4px + env(safe-area-inset-bottom));
    background: var(--cds-background);
    border-top: 1px solid var(--cds-border-subtle);
  }
  #topbar button {
    background: transparent;
    border: none;
    border-radius: 0;
    color: var(--cds-text-primary);
    width: 40px;
    height: 40px;
    flex-shrink: 0;
  }
  #topbar button:active { background: var(--cds-layer-active); }
  #topbar button:disabled { color: var(--cds-icon-disabled); }
  #topbar button svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
    display: block;
    margin: auto;
  }
  #url {
    flex: 1;
    min-width: 0;
    height: 40px;
    border: none;
    border-bottom: 1px solid var(--cds-border-strong);
    border-radius: 0;
    background: var(--cds-field);
    color: var(--cds-text-primary);
    font-family: inherit;
    font-size: 16px;
    padding: 0 16px;
    outline: none;
    margin: 0 6px;
  }
  #url:focus {
    outline: 2px solid var(--cds-focus);
    outline-offset: -2px;
  }
  #url::placeholder { color: var(--cds-text-helper); }
  #progress {
    height: 3px;
    background: var(--cds-interactive);
    width: 0;
    transition: width 0.2s;
  }

  #tabbar {
    display: flex;
    align-items: stretch;
    padding-top: env(safe-area-inset-top);
    background: var(--cds-layer);
    border-bottom: 1px solid var(--cds-border-subtle);
  }
  #tabs {
    flex: 1;
    display: flex;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    scrollbar-width: none;
  }
  #tabs::-webkit-scrollbar { display: none; }
  .tab {
    display: flex;
    align-items: center;
    gap: 4px;
    min-width: 110px;
    max-width: 150px;
    height: 36px;
    padding: 0 4px 0 12px;
    flex-shrink: 0;
    font-size: 13px;
    color: var(--cds-text-secondary);
    background: var(--cds-layer);
    border-right: 1px solid var(--cds-border-subtle);
    border-top: 2px solid transparent;
  }
  .tab.active {
    background: var(--cds-background);
    color: var(--cds-text-primary);
    border-top-color: var(--cds-interactive);
  }
  .tab-title {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .tab-close {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .tab-close:active { background: var(--cds-layer-active); }
  .tab-close svg { width: 14px; height: 14px; fill: currentColor; }
  #btnNewTab {
    width: 40px;
    flex-shrink: 0;
    background: transparent;
    border: none;
    border-radius: 0;
    color: var(--cds-text-primary);
  }
  #btnNewTab:active { background: var(--cds-layer-active); }
  #btnNewTab svg { width: 16px; height: 16px; fill: currentColor; display: block; margin: auto; }

  #screenWrap {
    flex: 1;
    position: relative;
    overflow: hidden;
    background: var(--cds-background);
    touch-action: none;
  }
  #screen {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
    transform-origin: 0 0;
    will-change: transform;
    pointer-events: none;
    user-select: none;
    -webkit-user-select: none;
  }
  #overlay { position: absolute; inset: 0; touch-action: none; }
  #status {
    position: absolute;
    top: 12px;
    left: 50%;
    transform: translateX(-50%);
    background: var(--cds-layer);
    border-left: 3px solid var(--cds-interactive);
    padding: 8px 16px;
    font-size: 13px;
    color: var(--cds-text-secondary);
    display: none;
    white-space: nowrap;
    max-width: 85%;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  #dragHint {
    position: absolute;
    top: 12px;
    left: 50%;
    transform: translateX(-50%);
    background: var(--cds-layer);
    border-left: 3px solid #42be65;
    padding: 8px 16px;
    font-size: 13px;
    color: var(--cds-text-secondary);
    display: none;
    white-space: nowrap;
  }

  #keyboardInput {
    position: fixed;
    bottom: 0;
    left: 0;
    width: 1px;
    height: 1px;
    opacity: 0.01;
    border: none;
  }

  #dlPanel, #pastePanel {
    position: absolute;
    inset: 0;
    background: var(--cds-overlay);
    display: none;
  }
  #dlPanel { z-index: 10; }
  #pastePanel { z-index: 11; }
  #dlPanel.open, #pastePanel.open { display: block; }
  #dlSheet, #pasteSheet {
    position: absolute;
    left: 0; right: 0; bottom: 0;
    background: var(--cds-layer);
    border-top: 1px solid var(--cds-border-subtle);
    padding: 16px;
  }
  #dlSheet {
    max-height: 70%;
    overflow-y: auto;
  }
  #dlSheet h2, #pasteSheet h2 {
    font-size: 16px;
    font-weight: 600;
    color: var(--cds-text-primary);
    margin-bottom: 12px;
  }
  .dl-item {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 0;
    border-bottom: 1px solid var(--cds-border-subtle);
  }
  .dl-info { flex: 1; min-width: 0; }
  .dl-name {
    font-size: 14px;
    color: var(--cds-text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .dl-meta { font-size: 12px; color: var(--cds-text-helper); margin-top: 2px; }
  .dl-bar {
    height: 4px;
    background: var(--cds-field-02);
    margin-top: 8px;
    overflow: hidden;
  }
  .dl-bar > div { height: 100%; background: var(--cds-interactive); }
  .dl-item a, .dl-item button {
    flex-shrink: 0;
    background: transparent;
    border: none;
    border-radius: 0;
    color: var(--cds-text-primary);
    width: 40px; height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    text-decoration: none;
  }
  .dl-item a:active, .dl-item button:active { background: var(--cds-layer-active); }
  .dl-item svg { width: 18px; height: 18px; fill: currentColor; }
  .dl-empty { color: var(--cds-text-helper); font-size: 14px; padding: 12px 0; }

  #pasteText {
    width: 100%;
    height: 96px;
    border: none;
    border-bottom: 1px solid var(--cds-border-strong);
    border-radius: 0;
    background: var(--cds-field-02);
    color: var(--cds-text-primary);
    font-family: inherit;
    font-size: 16px;
    padding: 10px 16px;
    outline: none;
    resize: none;
  }
  #pasteText:focus {
    outline: 2px solid var(--cds-focus);
    outline-offset: -2px;
  }
  #pasteText::placeholder { color: var(--cds-text-helper); }
  #pasteSend {
    margin-top: 16px;
    width: 100%;
    height: 48px;
    border: none;
    border-radius: 0;
    background: var(--cds-interactive);
    color: #ffffff;
    font-family: inherit;
    font-size: 14px;
    font-weight: 400;
    text-align: left;
    padding: 0 16px;
  }
  #pasteSend:active { background: var(--cds-interactive-active); }
  #pasteHint { font-size: 12px; color: var(--cds-text-helper); margin-top: 8px; }

  #disconnected {
    position: absolute;
    inset: 0;
    display: none;
    align-items: center;
    justify-content: center;
    background: var(--cds-overlay);
    z-index: 20;
  }
  #disconnected span {
    background: var(--cds-layer);
    border-left: 3px solid #fa4d56;
    padding: 12px 16px;
    font-size: 14px;
    color: var(--cds-text-primary);
  }
</style>
</head>
<body>
<div id="app">
  <div id="tabbar">
    <div id="tabs"></div>
    <button id="btnNewTab" title="New tab"><svg viewBox="0 0 32 32"><path d="M17 15 17 8 15 8 15 15 8 15 8 17 15 17 15 24 17 24 17 17 24 17 24 15z"/></svg></button>
  </div>
  <div id="progress"></div>
  <div id="screenWrap">
    <img id="screen" alt="">
    <div id="overlay"></div>
    <div id="status"></div>
    <div id="dragHint">Drag mode</div>
    <div id="disconnected"><span>Reconnecting&hellip;</span></div>
    <div id="pastePanel">
      <div id="pasteSheet">
        <h2>Paste into browser</h2>
        <textarea id="pasteText" placeholder="Paste text here" autocapitalize="none"
                  autocorrect="off" autocomplete="off" spellcheck="false"></textarea>
        <button id="pasteSend">Send to focused field</button>
        <div id="pasteHint">Text is typed into whatever field is focused in the remote browser.</div>
      </div>
    </div>
    <div id="dlPanel">
      <div id="dlSheet">
        <h2>Downloads</h2>
        <div id="dlList"><div class="dl-empty">No downloads yet</div></div>
      </div>
    </div>
  </div>
  <div id="topbar">
    <button id="btnBack" title="Back"><svg viewBox="0 0 32 32"><path d="M14 26 15.41 24.59 7.83 17 28 17 28 15 7.83 15 15.41 7.41 14 6 4 16 14 26z"/></svg></button>
    <button id="btnForward" title="Forward"><svg viewBox="0 0 32 32"><path d="M18 6 16.57 7.393 24.15 15 4 15 4 17 24.15 17 16.57 24.573 18 26 28 16 18 6z"/></svg></button>
    <button id="btnReload" title="Reload"><svg viewBox="0 0 32 32"><path d="M12,10H6.78A11,11,0,0,1,27,16h2A13,13,0,0,0,6,7.68V4H4v8h8Z"/><path d="M20,22h5.22A11,11,0,0,1,5,16H3a13,13,0,0,0,23,8.32V28h2V20H20Z"/></svg></button>
    <input id="url" type="text" inputmode="url" autocapitalize="none" autocorrect="off"
           autocomplete="off" spellcheck="false" placeholder="Search or enter address">
    <button id="btnPaste" title="Paste"><svg viewBox="0 0 32 32"><path d="M26,20H17.83l2.58-2.59L19,16l-5,5,5,5,1.41-1.41L17.83,22H26v8h2V22A2,2,0,0,0,26,20Z"/><path d="M23.71,9.29l-7-7A1,1,0,0,0,16,2H6A2,2,0,0,0,4,4V28a2,2,0,0,0,2,2h8V28H6V4h8v6a2,2,0,0,0,2,2h6v2h2V10A1,1,0,0,0,23.71,9.29ZM16,4.41,21.59,10H16Z"/></svg></button>
    <button id="btnKeyboard" title="Keyboard"><svg viewBox="0 0 32 32"><path d="M28,26H4a2,2,0,0,1-2-2V10A2,2,0,0,1,4,8H28a2,2,0,0,1,2,2V24A2,2,0,0,1,28,26ZM4,10V24H28V10Z"/><path d="M10 20H21V22H10z"/><path d="M6 12H8V14H6z"/><path d="M10 12H12V14H10z"/><path d="M14 12H16V14H14z"/><path d="M18 12H20V14H18z"/><path d="M6 20H8V22H6z"/><path d="M6 16H8V18H6z"/><path d="M10 16H12V18H10z"/><path d="M14 16H16V18H14z"/><path d="M22 12H26V14H22z"/><path d="M22 16H26V18H22z"/><path d="M18 16H20V18H18z"/><path d="M23 20H26V22H23z"/></svg></button>
    <button id="btnDownloads" title="Downloads"><svg viewBox="0 0 32 32"><path d="M26,24v4H6V24H4v4H4a2,2,0,0,0,2,2H26a2,2,0,0,0,2-2h0V24Z"/><path d="M26 14 24.59 12.59 17 20.17 17 2 15 2 15 20.17 7.41 12.59 6 14 16 24 26 14z"/></svg></button>
  </div>
</div>
<input id="keyboardInput" type="text" autocapitalize="none" autocorrect="off"
       autocomplete="off" spellcheck="false" aria-hidden="true">

<script>
(function () {
  'use strict';

  var wsURL = 'ws://' + location.hostname + ':8081/';
  var ws = null;
  var screenEl = document.getElementById('screen');
  var overlay = document.getElementById('overlay');
  var urlField = document.getElementById('url');
  var statusEl = document.getElementById('status');
  var dragHintEl = document.getElementById('dragHint');
  var progressEl = document.getElementById('progress');
  var disconnectedEl = document.getElementById('disconnected');
  var keyboardInput = document.getElementById('keyboardInput');
  var dlPanel = document.getElementById('dlPanel');
  var dlList = document.getElementById('dlList');
  var frameURL = null;
  var urlFocused = false;

  function send(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(obj));
    }
  }

  var lastViewport = '';
  function sendViewport() {
    var wrap = document.getElementById('screenWrap');
    var width = Math.round(wrap.clientWidth);
    var height = Math.round(wrap.clientHeight);
    if (!width || !height) return;
    var key = width + 'x' + height;
    if (key !== lastViewport) {
      zoom = 1; panX = 0; panY = 0;
      applyTransform();
    }
    lastViewport = key;
    send({ type: 'viewport', width: width, height: height,
           dpr: window.devicePixelRatio || 1 });
  }

  var resizeTimer = null;
  function queueViewport() {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(sendViewport, 250);
  }
  window.addEventListener('resize', queueViewport);
  window.addEventListener('orientationchange', queueViewport);
  if (window.ResizeObserver) {
    new ResizeObserver(queueViewport).observe(document.getElementById('screenWrap'));
  }

  function connect() {
    ws = new WebSocket(wsURL);
    ws.binaryType = 'blob';
    ws.onopen = function () {
      disconnectedEl.style.display = 'none';
      sendViewport();
    };
    ws.onclose = function () {
      disconnectedEl.style.display = 'flex';
      setTimeout(connect, 1500);
    };
    ws.onmessage = function (event) {
      if (event.data instanceof Blob) {
        var next = URL.createObjectURL(event.data);
        screenEl.onload = function () {
          if (frameURL) URL.revokeObjectURL(frameURL);
          frameURL = next;
          updateFitMode();
        };
        screenEl.src = next;
        return;
      }
      var msg;
      try { msg = JSON.parse(event.data); } catch (e) { return; }
      if (msg.type === 'state') handleState(msg);
      else if (msg.type === 'downloads') renderDownloads(msg.items || []);
    };
  }

  var closeIconSVG = '<svg viewBox="0 0 32 32"><path d="M17.4141 16 24 9.4141 22.5859 8 16 14.5859 9.4143 8 8 9.4141 14.5859 16 8 22.5859 9.4143 24 16 17.4141 22.5859 24 24 22.5859 17.4141 16z"></path></svg>';

  function renderTabs(tabs) {
    var container = document.getElementById('tabs');
    container.innerHTML = '';
    (tabs || []).forEach(function (tab) {
      var el = document.createElement('div');
      el.className = 'tab' + (tab.active ? ' active' : '');

      var title = document.createElement('span');
      title.className = 'tab-title';
      title.textContent = tab.title || tab.url || 'New tab';
      el.appendChild(title);

      var close = document.createElement('span');
      close.className = 'tab-close';
      close.innerHTML = closeIconSVG;
      close.addEventListener('click', function (event) {
        event.stopPropagation();
        send({ type: 'closetab', id: tab.id });
      });
      el.appendChild(close);

      el.addEventListener('click', function () {
        if (!tab.active) send({ type: 'switchtab', id: tab.id });
      });
      container.appendChild(el);
      if (tab.active) el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    });
  }

  document.getElementById('btnNewTab').addEventListener('click', function () {
    send({ type: 'newtab' });
  });

  function handleState(msg) {
    renderTabs(msg.tabs);
    if (!urlFocused) urlField.value = msg.url || '';
    document.getElementById('btnBack').disabled = !msg.canGoBack;
    document.getElementById('btnForward').disabled = !msg.canGoForward;
    if (msg.loading) {
      progressEl.style.width = Math.round((msg.progress || 0) * 100) + '%';
      statusEl.textContent = 'Loading ' + (msg.title || msg.url || '');
      statusEl.style.display = 'block';
    } else {
      progressEl.style.width = '0';
      statusEl.style.display = 'none';
      document.title = msg.title ? msg.title + ' - Kraken' : 'Kraken';
    }
  }

  // Rounded integer dimensions rarely match exactly; fill to avoid letterbox hairlines.
  var screenFillMode = false;
  function updateFitMode() {
    var box = screenEl.getBoundingClientRect();
    var nw = screenEl.naturalWidth, nh = screenEl.naturalHeight;
    if (!nw || !nh || !box.width || !box.height) return;
    var ratioDiff = Math.abs((nw / nh) / (box.width / box.height) - 1);
    screenFillMode = ratioDiff < 0.02;
    screenEl.style.objectFit = screenFillMode ? 'fill' : 'contain';
  }

  function contentRect() {
    var box = screenEl.getBoundingClientRect();
    var nw = screenEl.naturalWidth, nh = screenEl.naturalHeight;
    if (!nw || !nh) return null;
    if (screenFillMode) {
      return { x: box.left, y: box.top, w: box.width, h: box.height };
    }
    var scale = Math.min(box.width / nw, box.height / nh);
    var w = nw * scale, h = nh * scale;
    return {
      x: box.left + (box.width - w) / 2,
      y: box.top + (box.height - h) / 2,
      w: w, h: h
    };
  }

  function normalized(clientX, clientY) {
    var rect = contentRect();
    if (!rect) return null;
    var nx = (clientX - rect.x) / rect.w;
    var ny = (clientY - rect.y) / rect.h;
    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return null;
    return { x: nx, y: ny };
  }

  var zoom = 1, panX = 0, panY = 0;
  var pinch = null;

  function applyTransform() {
    screenEl.style.transform = 'translate(' + panX + 'px,' + panY + 'px) scale(' + zoom + ')';
  }

  function clampPan() {
    var box = overlay.getBoundingClientRect();
    panX = Math.min(0, Math.max(box.width * (1 - zoom), panX));
    panY = Math.min(0, Math.max(box.height * (1 - zoom), panY));
  }

  function touchDist(event) {
    var a = event.touches[0], b = event.touches[1];
    return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
  }

  var touch = null;
  var lastTap = { time: 0, x: 0, y: 0 };

  function cancelTouch() {
    if (!touch) return;
    if (touch.dragging) {
      var point = normalized(touch.lastX, touch.lastY);
      send({ type: 'dragend', x: point ? point.x : 0.5, y: point ? point.y : 0.5 });
      dragHintEl.style.display = 'none';
    }
    touch = null;
  }

  overlay.addEventListener('touchstart', function (event) {
    event.preventDefault();
    if (event.touches.length === 2) {
      cancelTouch();  // a pinch is not a tap or drag
      pinch = { startDist: touchDist(event), startZoom: zoom,
                startMidX: (event.touches[0].clientX + event.touches[1].clientX) / 2,
                startMidY: (event.touches[0].clientY + event.touches[1].clientY) / 2,
                startPanX: panX, startPanY: panY };
      return;
    }
    if (event.touches.length !== 1) { cancelTouch(); return; }
    var t = event.touches[0];
    var current = { startX: t.clientX, startY: t.clientY, lastX: t.clientX, lastY: t.clientY,
                    startTime: Date.now(), moved: false, dragging: false, lastDragSend: 0 };
    touch = current;
    // A second touch right after a tap starts a click-drag instead of a scroll.
    var isDoubleTap = (Date.now() - lastTap.time) < 300 &&
                      Math.abs(t.clientX - lastTap.x) < 30 &&
                      Math.abs(t.clientY - lastTap.y) < 30;
    if (isDoubleTap) {
      var point = normalized(t.clientX, t.clientY);
      if (point) {
        current.dragging = true;
        dragHintEl.style.display = 'block';
        send({ type: 'dragstart', x: point.x, y: point.y });
      }
    }
  }, { passive: false });

  overlay.addEventListener('touchmove', function (event) {
    event.preventDefault();
    if (pinch && event.touches.length === 2) {
      var box = overlay.getBoundingClientRect();
      var midX = (event.touches[0].clientX + event.touches[1].clientX) / 2 - box.left;
      var midY = (event.touches[0].clientY + event.touches[1].clientY) / 2 - box.top;
      zoom = Math.min(4, Math.max(1, pinch.startZoom * touchDist(event) / pinch.startDist));
      var contentX = (pinch.startMidX - box.left - pinch.startPanX) / pinch.startZoom;
      var contentY = (pinch.startMidY - box.top - pinch.startPanY) / pinch.startZoom;
      panX = midX - contentX * zoom;
      panY = midY - contentY * zoom;
      clampPan();
      applyTransform();
      return;
    }
    if (!touch || event.touches.length !== 1) return;
    var t = event.touches[0];
    var dx = t.clientX - touch.lastX;
    var dy = t.clientY - touch.lastY;
    if (touch.dragging) {
      touch.lastX = t.clientX;
      touch.lastY = t.clientY;
      var now = Date.now();
      if (now - touch.lastDragSend > 40) {
        var dragPoint = normalized(t.clientX, t.clientY);
        if (dragPoint) send({ type: 'dragmove', x: dragPoint.x, y: dragPoint.y });
        touch.lastDragSend = now;
      }
      return;
    }
    if (Math.abs(t.clientX - touch.startX) > 8 || Math.abs(t.clientY - touch.startY) > 8) {
      touch.moved = true;
    }
    if (touch.moved) {
      if (zoom > 1) {
        panX += dx;
        panY += dy;
        clampPan();
        applyTransform();
      } else {
        var rect = contentRect();
        if (rect) {
          // Natural scrolling: finger down moves page up.
          var at = normalized(touch.startX, touch.startY);
          send({ type: 'scroll', dx: -dx / rect.w, dy: -dy / rect.h,
                 x: at ? at.x : -1, y: at ? at.y : -1 });
        }
      }
      touch.lastX = t.clientX;
      touch.lastY = t.clientY;
    }
  }, { passive: false });

  overlay.addEventListener('touchend', function (event) {
    event.preventDefault();
    if (pinch && event.touches.length < 2) {
      pinch = null;
      if (zoom < 1.05) {  // snap back to unzoomed
        zoom = 1; panX = 0; panY = 0;
        applyTransform();
      }
      return;
    }
    if (!touch) return;
    if (touch.dragging) {
      cancelTouch();
      return;
    }
    var wasTap = !touch.moved && (Date.now() - touch.startTime) < 600;
    if (wasTap) {
      var point = normalized(touch.startX, touch.startY);
      if (point) {
        send({ type: 'tap', x: point.x, y: point.y });
        lastTap = { time: Date.now(), x: touch.startX, y: touch.startY };
      }
    }
    touch = null;
  }, { passive: false });

  overlay.addEventListener('touchcancel', function () {
    cancelTouch();
    pinch = null;
  });

  overlay.addEventListener('click', function (event) {
    var point = normalized(event.clientX, event.clientY);
    if (point) send({ type: 'tap', x: point.x, y: point.y });
  });
  overlay.addEventListener('wheel', function (event) {
    event.preventDefault();
    var rect = contentRect();
    var at = normalized(event.clientX, event.clientY);
    if (rect) send({ type: 'scroll', dx: event.deltaX / rect.w, dy: event.deltaY / rect.h,
                     x: at ? at.x : -1, y: at ? at.y : -1 });
  }, { passive: false });

  document.getElementById('btnBack').addEventListener('click', function () { send({ type: 'back' }); });
  document.getElementById('btnForward').addEventListener('click', function () { send({ type: 'forward' }); });
  document.getElementById('btnReload').addEventListener('click', function () { send({ type: 'reload' }); });

  urlField.addEventListener('focus', function () { urlFocused = true; urlField.select(); });
  urlField.addEventListener('blur', function () { urlFocused = false; });
  urlField.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') {
      send({ type: 'navigate', url: urlField.value });
      urlField.blur();
    }
  });

  document.getElementById('btnKeyboard').addEventListener('click', function () {
    if (document.activeElement === keyboardInput) {
      keyboardInput.blur();
    } else {
      keyboardInput.focus();
    }
  });

  keyboardInput.addEventListener('keydown', function (event) {
    var special = ['Enter', 'Backspace', 'Tab', 'Escape',
                   'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'];
    if (special.indexOf(event.key) !== -1) {
      event.preventDefault();
      send({ type: 'key', key: event.key });
    }
  });

  keyboardInput.addEventListener('input', function (event) {
    if (event.data) {
      send({ type: 'text', value: event.data });
    } else if (event.inputType === 'deleteContentBackward') {
      send({ type: 'key', key: 'Backspace' });
    }
    keyboardInput.value = '';
  });

  var pastePanel = document.getElementById('pastePanel');
  var pasteText = document.getElementById('pasteText');

  document.getElementById('btnPaste').addEventListener('click', function () {
    // Clipboard API needs https; fall back to a paste sheet over plain http.
    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard.readText().then(function (value) {
        if (value) send({ type: 'text', value: value });
      }).catch(openPasteSheet);
    } else {
      openPasteSheet();
    }
  });

  function openPasteSheet() {
    pastePanel.classList.add('open');
    setTimeout(function () { pasteText.focus(); }, 50);
  }

  document.getElementById('pasteSend').addEventListener('click', function () {
    if (pasteText.value) send({ type: 'text', value: pasteText.value });
    pasteText.value = '';
    pastePanel.classList.remove('open');
  });
  pastePanel.addEventListener('click', function (event) {
    if (event.target === pastePanel) pastePanel.classList.remove('open');
  });

  document.getElementById('btnDownloads').addEventListener('click', function () {
    dlPanel.classList.toggle('open');
  });
  dlPanel.addEventListener('click', function (event) {
    if (event.target === dlPanel) dlPanel.classList.remove('open');
  });

  function formatSize(bytes) {
    if (!bytes || bytes < 0) return '';
    var units = ['B', 'KB', 'MB', 'GB'];
    var i = 0, n = bytes;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return n.toFixed(n >= 10 || i === 0 ? 0 : 1) + ' ' + units[i];
  }

  function renderDownloads(items) {
    dlList.innerHTML = '';
    if (!items.length) {
      dlList.innerHTML = '<div class="dl-empty">No downloads yet</div>';
      return;
    }
    items.forEach(function (item) {
      var row = document.createElement('div');
      row.className = 'dl-item';

      var info = document.createElement('div');
      info.className = 'dl-info';
      var name = document.createElement('div');
      name.className = 'dl-name';
      name.textContent = item.name;
      info.appendChild(name);
      var meta = document.createElement('div');
      meta.className = 'dl-meta';
      if (item.failed) {
        meta.textContent = 'Failed';
      } else if (item.done) {
        meta.textContent = formatSize(item.size);
      } else {
        meta.textContent = formatSize(item.received) +
          (item.size > 0 ? ' of ' + formatSize(item.size) : '') + ' - downloading';
        var bar = document.createElement('div');
        bar.className = 'dl-bar';
        var fill = document.createElement('div');
        fill.style.width = Math.round((item.progress || 0) * 100) + '%';
        bar.appendChild(fill);
        info.appendChild(bar);
      }
      info.insertBefore(name, info.firstChild);
      row.appendChild(info);

      if (item.done) {
        var link = document.createElement('a');
        link.href = '/files/' + encodeURIComponent(item.name);
        link.innerHTML = '<svg viewBox="0 0 32 32"><path d="M26,24v4H6V24H4v4H4a2,2,0,0,0,2,2H26a2,2,0,0,0,2-2h0V24Z"/><path d="M26 14 24.59 12.59 17 20.17 17 2 15 2 15 20.17 7.41 12.59 6 14 16 24 26 14z"/></svg>';
        link.setAttribute('download', item.name);
        row.appendChild(link);

        var del = document.createElement('button');
        del.innerHTML = '<svg viewBox="0 0 32 32"><path d="M12 12H14V24H12z"/><path d="M18 12H20V24H18z"/><path d="M4,6V8H6V28a2,2,0,0,0,2,2H24a2,2,0,0,0,2-2V8h2V6ZM8,28V8H24V28Z"/><path d="M12 2H20V4H12z"/></svg>';
        del.addEventListener('click', function () {
          fetch('/files/' + encodeURIComponent(item.name), { method: 'DELETE' });
        });
        row.appendChild(del);
      }
      dlList.appendChild(row);
    });
  }

  connect();
})();
</script>
</body>
</html>
"""#
