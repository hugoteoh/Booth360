import Foundation

/// 大屏页共享模板 —— 视觉整套照抄用户 AI PhotoBooth 的 Bigscreen wall 模式
/// （bigscreen.html：#06080d 底色、暗角、自适应列数公式、wallIn 入场、wallGlow 呼吸、
///  spotlight 最新一条弹中央再收进墙），卡片换成「循环视频 + 专属二维码」。
///
/// variantJS 需要定义：
///   REFRESH_MS            轮询间隔
///   async fetchItems()    → [{id, videoURL, qrURL(可空), state}]（新→旧）
///   GEAR_HREF             左上角齿轮链接（空字符串 = 隐藏）
enum WallPageTemplate {

    static func page(variantJS: String) -> String {
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Booth360 大屏</title>
        <style>
          *{box-sizing:border-box} html,body{height:100%;margin:0}
          body{background:#06080d;color:#f2f5f9;overflow:hidden;
               font-family:system-ui,'PingFang SC','Microsoft YaHei',sans-serif}
          .vign{position:fixed;inset:0;z-index:4;pointer-events:none;
                background:radial-gradient(140% 140% at 50% 40%,transparent 62%,rgba(0,0,0,.34) 100%)}
          #gear{position:fixed;top:12px;left:14px;color:#26292f;font-size:22px;
                text-decoration:none;z-index:9}
          .wait{position:fixed;inset:0;display:flex;flex-direction:column;align-items:center;
                justify-content:center;gap:1.4vh;text-align:center;
                font-size:clamp(26px,3.4vw,58px);font-weight:800;z-index:5;
                animation:waitpulse 2.8s ease-in-out infinite}
          .wait .ic{font-size:clamp(44px,7vw,120px);line-height:1}
          .wait .en{font-size:clamp(14px,1.5vw,26px);font-weight:600;color:#9aa6b2;letter-spacing:1px}
          @keyframes waitpulse{0%,100%{opacity:.58}50%{opacity:.96}}
          /* wall（照抄 wgrid/wcell 的动效参数） */
          #grid{position:fixed;inset:0;display:grid;gap:clamp(12px,1.3vw,22px);
                padding:clamp(28px,4vh,56px) clamp(36px,4vw,70px);
                justify-content:center;align-content:center;perspective:2200px}
          .wcell{position:relative;display:flex;align-items:flex-end;gap:10px;
                 justify-content:center;min-height:0;
                 animation:wallIn .9s cubic-bezier(.22,.61,.36,1) backwards,
                           wallGlow 9s ease-in-out infinite;
                 animation-delay:calc(var(--i)*70ms),calc(var(--i)*-1.3s);
                 will-change:transform,opacity}
          .wcell video{height:100%;max-height:100%;aspect-ratio:9/16;object-fit:cover;
                       background:#0b0e13;border-radius:3px;
                       box-shadow:0 14px 34px rgba(0,0,0,.5),0 2px 6px rgba(0,0,0,.4)}
          .qrbox{width:clamp(64px,6.4vw,96px);aspect-ratio:1;background:#fff;border-radius:6px;
                 padding:5px;display:flex;align-items:center;justify-content:center;
                 margin-bottom:4px;flex:none;box-shadow:0 8px 22px rgba(0,0,0,.45)}
          .qrbox img{width:100%;height:100%;image-rendering:pixelated;display:block}
          .qrbox .pending{font-size:10px;color:#666;text-align:center;line-height:1.6}
          @keyframes wallIn{from{opacity:0;transform:translateY(26px) scale(.96)}
                            to{opacity:1;transform:none}}
          @keyframes wallGlow{0%,100%{filter:brightness(.95)}50%{filter:brightness(1.06)}}
        </style>
        </head>
        <body>
        <a id="gear" href="#" style="display:none">⚙</a>
        <div class="wait" id="wait"><div class="ic">🎥</div><div>精彩即将开始…</div>
          <div class="en">Waiting for the first video…</div></div>
        <div id="grid"></div>
        <div class="vign"></div>

        <script>
        \(variantJS)
        </script>
        <script>
        const MAX_CARDS = 8;
        const grid = document.getElementById("grid");
        const known = new Map(); // id -> { el, hasQR }
        let cellSeq = 0;

        const gearEl = document.getElementById("gear");
        if (typeof GEAR_HREF === "string" && GEAR_HREF) {
          gearEl.href = GEAR_HREF; gearEl.style.display = "block";
        }

        // 照抄 bigscreen wall 的列数公式：cols = clamp(2..6, ceil(sqrt(n*16/9)))
        function applyCols(n) {
          const cols = Math.max(2, Math.min(6, Math.ceil(Math.sqrt(Math.max(1, n) * 16 / 9))));
          grid.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
          const rows = Math.max(1, Math.ceil(n / cols));
          grid.style.gridTemplateRows = `repeat(${rows}, minmax(0, 1fr))`;
        }

        function qrHTML(item) {
          return item.qrURL
            ? `<img src="${item.qrURL}" alt="QR">`
            : `<div class="pending">☁️<br>${item.state || "上传中"}</div>`;
        }

        function cardEl(item) {
          const el = document.createElement("div");
          el.className = "wcell";
          el.style.setProperty("--i", (cellSeq++) % 12);
          el.innerHTML = `
            <video src="${item.videoURL}" autoplay muted loop playsinline preload="auto"></video>
            <div class="qrbox">${qrHTML(item)}</div>`;
          return el;
        }

        async function refresh() {
          try {
            const items = (await fetchItems()).slice(0, MAX_CARDS);
            document.getElementById("wait").style.display = items.length ? "none" : "flex";

            for (const [id, entry] of Array.from(known)) {
              if (!items.find(x => x.id === id)) { entry.el.remove(); known.delete(id); }
            }
            const fresh = items.filter(x => !known.has(x.id));
            for (const item of fresh.reverse()) {
              const el = cardEl(item);
              grid.prepend(el);
              known.set(item.id, { el, hasQR: !!item.qrURL });
            }
            while (grid.children.length > MAX_CARDS) {
              const last = grid.lastElementChild;
              for (const [id, entry] of known) if (entry.el === last) known.delete(id);
              last.remove();
            }
            // 上传完成 → 二维码浮现
            for (const item of items) {
              const entry = known.get(item.id);
              if (entry && !entry.hasQR) {
                entry.el.querySelector(".qrbox").innerHTML = qrHTML(item);
                entry.hasQR = !!item.qrURL;
              }
            }
            applyCols(grid.children.length);
          } catch (e) { /* 网络抖动，下轮再试 */ }
        }
        refresh();
        setInterval(refresh, REFRESH_MS);
        </script>
        </body>
        </html>
        """
    }
}
