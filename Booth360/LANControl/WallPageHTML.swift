import Foundation

/// 大屏展示页（Glambot 式多宫格视频墙）：
/// 最多 8 格（4×2），每格 = 竖版视频循环播放 + 右下角自己的二维码；
/// 新视频从左上角插入，最旧的挤出；二维码在上传完成后自动浮现。
/// 大屏电脑浏览器打开 http://<手机IP>:8360/wall 后按 F11 全屏。
enum WallPageHTML {
    static let html = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Booth360 大屏</title>
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
      .qrbox .pending { font-size: 10px; color: #666; text-align: center; line-height: 1.6; }
      #empty { position: fixed; inset: 0; display: grid; place-items: center;
               color: #555; font-size: 30px; text-align: center; line-height: 2; }
      #gear { position: fixed; top: 12px; left: 14px; color: #2c2c2c; font-size: 22px;
              text-decoration: none; z-index: 9; }
    </style>
    </head>
    <body>
    <a id="gear" href="/" title="控制台">⚙</a>
    <div id="empty">🎥<br>等待第一段 360 视频…</div>
    <div id="grid"></div>

    <script>
    const MAX_CARDS = 8;
    const known = new Map(); // id -> { el, uploaded }

    function cardElement(item) {
      const card = document.createElement("div");
      card.className = "card";
      card.innerHTML = `
        <video src="/video/${item.id}" autoplay muted loop playsinline preload="auto"></video>
        <div class="qrbox">${item.uploaded
          ? `<img src="/qr/${item.id}" alt="QR">`
          : `<div class="pending">☁️<br>${item.state}</div>`}</div>`;
      return card;
    }

    async function refresh() {
      try {
        const data = await (await fetch("/api/renders")).json();
        const items = data.slice(0, MAX_CARDS);
        const grid = document.getElementById("grid");
        document.getElementById("empty").style.display = items.length ? "none" : "grid";

        // 移除已不在列表里的
        for (const [id, entry] of Array.from(known)) {
          if (!items.find(x => x.id === id)) { entry.el.remove(); known.delete(id); }
        }
        // 新视频从最前插入（不重排已存在的卡片，避免视频重载）
        const fresh = items.filter(x => !known.has(x.id));
        for (const item of fresh.reverse()) {
          const el = cardElement(item);
          grid.prepend(el);
          known.set(item.id, { el, uploaded: item.uploaded });
        }
        // 超出上限的从尾部挤出
        while (grid.children.length > MAX_CARDS) {
          const last = grid.lastElementChild;
          for (const [id, entry] of known) if (entry.el === last) known.delete(id);
          last.remove();
        }
        // 上传状态翻转 → 二维码浮现
        for (const item of items) {
          const entry = known.get(item.id);
          if (entry && !entry.uploaded && item.uploaded) {
            entry.uploaded = true;
            entry.el.querySelector(".qrbox").innerHTML = `<img src="/qr/${item.id}" alt="QR">`;
          } else if (entry && !item.uploaded) {
            const pending = entry.el.querySelector(".pending");
            if (pending) pending.innerHTML = `☁️<br>${item.state}`;
          }
        }
      } catch (e) { /* 网络抖动，下轮再试 */ }
    }
    refresh();
    setInterval(refresh, 3000);
    </script>
    </body>
    </html>
    """
}
