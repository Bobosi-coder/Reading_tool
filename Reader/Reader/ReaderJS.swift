import Foundation

enum ReaderJS {
    /// Injected at document start: our stylesheet + hide the page until it is paginated.
    static func startScript(css: String) -> String {
        let cssJSON = jsonString(css)
        return """
        (function(){
          var s = document.createElement('style');
          s.id = '__reader_style';
          s.textContent = \(cssJSON);
          (document.head || document.documentElement).appendChild(s);
          var h = document.createElement('style');
          h.id = '__reader_hide';
          h.textContent = 'html{visibility:hidden !important}';
          document.documentElement.appendChild(h);
        })();
        """
    }

    /// Injected at document end: pagination, taps, selection.
    static let runtime = #"""
    (function(){
      if (window.reader) return;
      function post(m){ try { window.webkit.messageHandlers.reader.postMessage(m); } catch(e){} }

      var R = {
        page: 0, count: 1, W: 0, ready: false,
        cfg: { margin: 36, top: 48, bottom: 52 },

        ensureStyleLast: function(){
          var s = document.getElementById('__reader_style');
          if (s && document.head) document.head.appendChild(s);
        },

        layout: function(){
          var W = window.innerWidth, H = window.innerHeight, m = R.cfg.margin;
          var cols = W >= 900 ? 2 : 1;
          R.W = W;
          var b = document.body;
          if (!b) return;
          var html = document.documentElement;
          html.style.setProperty('margin', '0', 'important');
          html.style.setProperty('padding', '0', 'important');
          html.style.setProperty('height', H + 'px', 'important');
          var st = b.style;
          st.setProperty('box-sizing', 'border-box', 'important');
          st.setProperty('margin', '0', 'important');
          st.setProperty('padding', R.cfg.top + 'px ' + m + 'px ' + R.cfg.bottom + 'px ' + m + 'px', 'important');
          st.setProperty('height', H + 'px', 'important');
          st.setProperty('max-width', 'none', 'important');
          st.setProperty('width', W + 'px', 'important');
          st.setProperty('column-width', (W / cols - 2 * m) + 'px', 'important');
          st.setProperty('column-gap', (2 * m) + 'px', 'important');
          st.setProperty('column-fill', 'auto', 'important');
          st.setProperty('overflow', 'visible', 'important');
          var imgMax = (H - R.cfg.top - R.cfg.bottom - 4) + 'px';
          var imgs = document.querySelectorAll('img, svg, video');
          for (var i = 0; i < imgs.length; i++) imgs[i].style.setProperty('max-height', imgMax, 'important');
          var sw = Math.max(b.scrollWidth, html.scrollWidth);
          R.count = Math.max(1, Math.ceil((sw - 2) / W));
        },

        goTo: function(p){
          R.page = Math.max(0, Math.min(R.count - 1, p));
          window.scrollTo(R.page * R.W, 0);
          post({ type: 'position', page: R.page, count: R.count });
        },
        next: function(){
          if (R.page < R.count - 1) R.goTo(R.page + 1); else post({ type: 'nextChapter' });
        },
        prev: function(){
          if (R.page > 0) R.goTo(R.page - 1); else post({ type: 'prevChapter' });
        },
        goToProgress: function(p){
          if (p >= 1) { R.goTo(R.count - 1); return; }
          R.goTo(Math.floor(p * R.count + 1e-6));
        },
        goToElement: function(id){
          var el = document.getElementById(id);
          if (!el) { var n = document.getElementsByName(id); el = n && n[0]; }
          if (!el) { R.goTo(0); return; }
          var left = el.getBoundingClientRect().left + window.scrollX;
          R.goTo(Math.floor(left / R.W));
        },
        progress: function(){ return R.count > 0 ? R.page / R.count : 0; },
        relayout: function(){
          var p = R.progress();
          R.layout();
          R.goToProgress(p);
        },
        reveal: function(){
          var h = document.getElementById('__reader_hide');
          if (h) h.remove();
        },
        start: function(target){
          R.ensureStyleLast();
          var go = function(){
            R.layout();
            if (target && target.fragment) R.goToElement(target.fragment);
            else R.goToProgress(target ? target.progress : 0);
            R.ready = true;
            R.reveal();
          };
          go();
          if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(function(){
              if (target && target.fragment) { R.layout(); R.goToElement(target.fragment); }
              else R.relayout();
            });
          }
        },
        applyStyle: function(css){
          var s = document.getElementById('__reader_style');
          if (!s) { s = document.createElement('style'); s.id = '__reader_style'; document.head.appendChild(s); }
          s.textContent = css;
          R.ensureStyleLast();
          R.relayout();
          if (document.fonts && document.fonts.ready) document.fonts.ready.then(function(){ R.relayout(); });
        },
        selectionInfo: function(){
          var sel = window.getSelection();
          var text = sel ? sel.toString().trim() : '';
          var ctx = '';
          if (sel && sel.rangeCount) {
            var n = sel.getRangeAt(0).commonAncestorContainer;
            if (n.nodeType === 3) n = n.parentElement;
            var block = (n && n.closest) ? n.closest('p,li,blockquote,h1,h2,h3,h4,h5,h6,td,dd,dt') : null;
            if (block) {
              var parts = [];
              var p1 = block.previousElementSibling, n1 = block.nextElementSibling;
              if (p1 && p1.innerText) parts.push(p1.innerText);
              parts.push(block.innerText);
              if (n1 && n1.innerText) parts.push(n1.innerText);
              ctx = parts.join('\n');
            } else if (n) {
              ctx = n.innerText || '';
            }
            if (ctx.length > 3000) {
              var i = ctx.indexOf(text.slice(0, 30));
              var start = Math.max(0, (i < 0 ? 0 : i) - 1200);
              ctx = ctx.slice(start, start + 3000);
            }
          }
          return { text: text, context: ctx };
        },
        clearSelection: function(){ var s = window.getSelection(); if (s) s.removeAllRanges(); }
      };
      window.reader = R;

      var hadSelectionAtTouch = false;
      document.addEventListener('touchstart', function(){
        var s = window.getSelection();
        hadSelectionAtTouch = !!(s && !s.isCollapsed);
      }, { passive: true, capture: true });

      document.addEventListener('click', function(e){
        if (!R.ready) return;
        if (e.target && e.target.closest && e.target.closest('a[href]')) return;
        var s = window.getSelection();
        if (hadSelectionAtTouch || (s && !s.isCollapsed)) { hadSelectionAtTouch = false; return; }
        var x = e.clientX, W = window.innerWidth;
        if (x < W * 0.28) R.prev();
        else if (x > W * 0.72) R.next();
        else post({ type: 'toggleChrome' });
      }, true);

      var selTimer = null;
      document.addEventListener('selectionchange', function(){
        clearTimeout(selTimer);
        selTimer = setTimeout(function(){
          var s = window.getSelection();
          post({ type: 'selection', text: s ? s.toString().trim().slice(0, 200) : '' });
        }, 250);
      });

      var resizeTimer = null;
      window.addEventListener('resize', function(){
        if (!R.ready) return;
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(R.relayout, 120);
      });

      // Never stay hidden if Swift fails to call start().
      setTimeout(function(){ if (!R.ready) R.start({ progress: 0 }); }, 2500);
    })();
    """#

    static func jsonString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        // Strip the surrounding [ ].
        return String(arr.dropFirst().dropLast())
    }

    static func styleCSS(settings s: ReaderSettings, fonts: FontManager) -> String {
        let t = s.theme
        let families = [s.latinFont, s.cjkFont].filter { !$0.isEmpty }
        let faces = fonts.fontFaceCSS(families: families)
        let fontRule = s.overridesFont ? """
        html, body, body *:not(pre):not(code):not(kbd):not(samp):not(tt) {
          font-family: \(s.fontFamilyCSS) !important;
        }
        """ : ""
        let indent = s.textIndent ? "2em" : "0"
        let align = s.justify ? "justify" : "start"
        return """
        \(faces)
        html, body {
          background: \(t.background) !important;
          color: \(t.foreground) !important;
          -webkit-text-size-adjust: 100% !important;
        }
        html { font-size: \(Int(s.fontSize))px !important; }
        body {
          font-size: \(Int(s.fontSize))px !important;
          line-height: \(s.lineHeight) !important;
          letter-spacing: \(s.letterSpacing)em !important;
          -webkit-hyphens: auto; hyphens: auto;
          word-wrap: break-word;
        }
        \(fontRule)
        body p, body div, body li, body blockquote, body dd, body span, body td {
          line-height: \(s.lineHeight) !important;
          color: inherit !important;
          background-color: transparent !important;
        }
        body p {
          font-size: 1em !important;
          text-indent: \(indent) !important;
          text-align: \(align) !important;
          margin-top: 0 !important;
          margin-bottom: \(s.paragraphSpacing)em !important;
        }
        h1, h2, h3, h4, h5, h6 { color: inherit !important; line-height: 1.4 !important; text-indent: 0 !important; break-after: avoid; }
        a, a:visited { color: \(t.link) !important; }
        img, svg, video { max-width: 100% !important; height: auto; object-fit: contain; break-inside: avoid; }
        figure, table { break-inside: avoid; }
        pre { white-space: pre-wrap !important; }
        ::selection { background: rgba(255, 196, 0, 0.35); }
        """
    }
}
