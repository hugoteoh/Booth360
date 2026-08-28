import Foundation

/// 云端大屏页面（发布到 COS，任何网络的浏览器可开）——与局域网大屏同款
/// Glambot 式多宫格视频墙；数据来自同目录 wall.json，视频/二维码用其中的链接。
enum CloudWallPageHTML {
    static let html = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Booth360 云端大屏</title>
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body { background: #000; height: 100vh; overflow: hidden;
             font-family: -apple-system, "Microsoft YaHei", sans-serif; }
      #grid { height: 100vh; padding: 40px 52px; display: grid;
              grid-template-columns: repeat(4, 1fr); grid-template-rows: repeat(2, 1fr);
              gap: 30px 44px; align-items: center; justify-items: center; }
      .card { display: flex; align-items: flex-end; gap: 10px;
              height: 100%; max-height: 100%; }
      .card video { height: 100%; max-height: calc((100vh - 110px) / 2);
                    aspect-ratio: 9 / 16; object-fit: cover;
                    background: #101014; border-radius: 4px; }
      .qrbox { width: 92px; height: 92px; background: #fff; border-radius: 6px;
               padding: 5px; display: flex; align-items: center; justify-content: center;
               margin-bottom: 4px; flex: none; }
      .qrbox img { width: 100%; height: 100%; image-rendering: pixelated; }
      #empty { position: fixed; inset: 0; display: grid; place-items: center;
               color: #555; font-size: 30px; text-align: center; line-height: 2; }
    </style>
    </head>
    <body>
    <div id="empty">🎥<br>等待第一段 360 视频…</div>
    <div id="grid"></div>

    <script>
    const MAX_CARDS = 8;
    const known = new Map(); // id -> { el }

    function cardElement(item) {
      const card = document.createElement("div");
      card.className = "card";
      card.innerHTML = `
        <video src="${item.url}" autoplay muted loop playsinline preload="auto"></video>
        <div class="qrbox"><img src="${item.qr}" alt="QR"></div>`;
      return card;
    }

    async function refresh() {
      try {
        const response = await fetch(`./wall.json?ts=${Date.now()}`, { cache: "no-store" });
        const manifest = await response.json();
        const items = (manifest.items || []).slice(0, MAX_CARDS);
        const grid = document.getElementById("grid");
        document.getElementById("empty").style.display = items.length ? "none" : "grid";

        for (const [id, entry] of Array.from(known)) {
          if (!items.find(x => x.id === id)) { entry.el.remove(); known.delete(id); }
        }
        const fresh = items.filter(x => !known.has(x.id));
        for (const item of fresh.reverse()) {
          const el = cardElement(item);
          grid.prepend(el);
          known.set(item.id, { el });
        }
        while (grid.children.length > MAX_CARDS) {
          const last = grid.lastElementChild;
          for (const [id, entry] of known) if (entry.el === last) known.delete(id);
          last.remove();
        }
      } catch (e) { /* 网络抖动，下轮再试 */ }
    }
    refresh();
    setInterval(refresh, 5000);
    </script>
    </body>
    </html>
    """
}
