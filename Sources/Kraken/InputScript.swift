enum InputScript {
    static let source = #"""
    (function () {
      if (window.__kraken) { return; }

      function isEditable(el) {
        if (!el) return false;
        return el.isContentEditable || el.tagName === 'INPUT' ||
               el.tagName === 'TEXTAREA' || el.tagName === 'SELECT';
      }

      function caretAt(x, y) {
        if (document.caretRangeFromPoint) {
          var range = document.caretRangeFromPoint(x, y);
          if (range) return { node: range.startContainer, offset: range.startOffset };
        }
        if (document.caretPositionFromPoint) {
          var position = document.caretPositionFromPoint(x, y);
          if (position) return { node: position.offsetNode, offset: position.offset };
        }
        return null;
      }

      var drag = null;
      var pendingPicker = null;

      function isVisible(el) {
        if (!el.getClientRects().length) return false;
        var style = getComputedStyle(el);
        return style.visibility !== 'hidden' && style.display !== 'none';
      }

      function pickerInfo(el) {
        if (!el || el.disabled || el.readOnly || !isVisible(el)) return null;
        if (el.tagName === 'SELECT') {
          var options = [];
          for (var i = 0; i < el.options.length; i++) {
            var o = el.options[i];
            options.push({ label: o.label || o.text, value: o.value,
                           selected: o.selected, disabled: o.disabled });
          }
          return { kind: 'select', multiple: !!el.multiple, options: options };
        }
        if (el.tagName === 'INPUT') {
          var type = (el.getAttribute('type') || 'text').toLowerCase();
          var native = { date: 1, time: 1, 'datetime-local': 1, month: 1, week: 1, color: 1 };
          if (native[type]) {
            return { kind: type, value: el.value,
                     min: el.min || '', max: el.max || '', step: el.step || '' };
          }
          if (el.list) {
            var items = [];
            for (var j = 0; j < el.list.options.length; j++) {
              items.push({ label: el.list.options[j].label || '',
                           value: el.list.options[j].value });
            }
            return { kind: 'datalist', value: el.value, options: items };
          }
        }
        return null;
      }

      function openPicker(el) {
        var info = pickerInfo(el);
        if (!info) return false;
        pendingPicker = el;
        try { el.focus({ preventScroll: true }); } catch (e) {}
        if (window.__krakenPicker) { window.__krakenPicker(JSON.stringify(info)); }
        return true;
      }

      document.addEventListener('mousedown', function (event) {
        var node = event.target;
        while (node && node.nodeType === 1 && node !== document.body) {
          if (node.tagName === 'SELECT' || node.tagName === 'INPUT') {
            if (openPicker(node)) { event.preventDefault(); }
            return;
          }
          node = node.parentElement;
        }
      }, true);

      window.__kraken = {
        setPicker: function (payload) {
          var el = pendingPicker;
          pendingPicker = null;
          if (!el) return;
          var data = typeof payload === 'string' ? JSON.parse(payload) : payload;
          if (!data || data.cancel) return;
          if (el.tagName === 'SELECT' && el.multiple) {
            var chosen = {};
            (data.values || []).forEach(function (v) { chosen[v] = true; });
            for (var i = 0; i < el.options.length; i++) {
              el.options[i].selected = !!chosen[el.options[i].value];
            }
          } else if (data.value != null) {
            el.value = data.value;
          }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        },

        tap: function (nx, ny) {
          var x = nx * window.innerWidth, y = ny * window.innerHeight;
          var el = document.elementFromPoint(x, y) || document.body;
          var opts = { bubbles: true, cancelable: true, view: window,
                       clientX: x, clientY: y, button: 0, detail: 1 };
          ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function (type) {
            var ev = type.indexOf('pointer') === 0
              ? new PointerEvent(type, opts) : new MouseEvent(type, opts);
            el.dispatchEvent(ev);
          });
          if (isEditable(el)) {
            el.focus();
          } else if (document.activeElement && isEditable(document.activeElement)) {
            document.activeElement.blur();
          }
          if (typeof el.click === 'function') { el.click(); }
        },

        text: function (value) {
          var el = document.activeElement;
          if (!isEditable(el)) return;
          el.focus();
          if (!document.execCommand('insertText', false, value) && 'value' in el) {
            el.value += value;
            el.dispatchEvent(new InputEvent('input',
              { bubbles: true, data: value, inputType: 'insertText' }));
          }
        },

        key: function (key) {
          var el = document.activeElement || document.body;
          var codes = { Enter: 13, Backspace: 8, Tab: 9, Escape: 27,
                        ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39 };
          var code = codes[key] || (key.length === 1 ? key.charCodeAt(0) : 0);
          var opts = { bubbles: true, cancelable: true, key: key, keyCode: code, which: code };
          var allowed = el.dispatchEvent(new KeyboardEvent('keydown', opts));
          if (allowed) {
            if (key === 'Backspace' && isEditable(el)) {
              document.execCommand('delete', false);
            } else if (key === 'Enter') {
              if (el.form && el.tagName === 'INPUT') {
                if (el.form.requestSubmit) { el.form.requestSubmit(); } else { el.form.submit(); }
              } else if (isEditable(el)) {
                document.execCommand('insertText', false, '\n');
              }
            } else if (key.length === 1) {
              window.__kraken.text(key);
            }
          }
          el.dispatchEvent(new KeyboardEvent('keyup', opts));
        },

        dragStart: function (nx, ny) {
          var x = nx * window.innerWidth, y = ny * window.innerHeight;
          var el = document.elementFromPoint(x, y) || document.body;
          var opts = { bubbles: true, cancelable: true, view: window,
                       clientX: x, clientY: y, button: 0, buttons: 1, detail: 1 };
          var prevented = false;
          ['pointerdown', 'mousedown'].forEach(function (type) {
            var ev = type === 'pointerdown'
              ? new PointerEvent(type, opts) : new MouseEvent(type, opts);
            if (!el.dispatchEvent(ev)) prevented = true;
          });
          drag = { el: el, anchor: null };
          if (!prevented && !isEditable(el)) {
            drag.anchor = caretAt(x, y);
          }
        },

        dragMove: function (nx, ny) {
          if (!drag) return;
          var x = nx * window.innerWidth, y = ny * window.innerHeight;
          var el = document.elementFromPoint(x, y) || drag.el;
          var opts = { bubbles: true, cancelable: true, view: window,
                       clientX: x, clientY: y, button: 0, buttons: 1 };
          ['pointermove', 'mousemove'].forEach(function (type) {
            var ev = type === 'pointermove'
              ? new PointerEvent(type, opts) : new MouseEvent(type, opts);
            el.dispatchEvent(ev);
          });
          if (drag.anchor) {
            var focus = caretAt(x, y);
            if (focus) {
              try {
                window.getSelection().setBaseAndExtent(
                  drag.anchor.node, drag.anchor.offset, focus.node, focus.offset);
              } catch (e) {}
            }
          }
        },

        dragEnd: function (nx, ny) {
          if (!drag) return;
          var x = nx * window.innerWidth, y = ny * window.innerHeight;
          var el = document.elementFromPoint(x, y) || drag.el;
          var opts = { bubbles: true, cancelable: true, view: window,
                       clientX: x, clientY: y, button: 0, buttons: 0, detail: 1 };
          ['pointerup', 'mouseup'].forEach(function (type) {
            var ev = type === 'pointerup'
              ? new PointerEvent(type, opts) : new MouseEvent(type, opts);
            el.dispatchEvent(ev);
          });
          drag = null;
        },

        textAt: function (nx, ny) {
          var sel = window.getSelection ? String(window.getSelection()) : '';
          if (sel && sel.trim()) return sel.slice(0, 20000);
          var x = nx * window.innerWidth, y = ny * window.innerHeight;
          var el = document.elementFromPoint(x, y);
          if (!el) return '';
          if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return (el.value || '').slice(0, 20000);
          var block = el.closest && el.closest(
            'p,li,h1,h2,h3,h4,h5,h6,td,th,blockquote,pre,figcaption,dt,dd,label,summary,a,button');
          var text = block ? block.innerText : (el.innerText || el.textContent || '');
          return (text || '').trim().slice(0, 20000);
        }
      };
    })();
    """#
}
