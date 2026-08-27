import Foundation

/// 云端大屏页面（发布到 COS，任何网络的浏览器可开）。
/// 与局域网 /wall 同样的观感；数据来自同目录 wall.json（同源请求，无跨域问题），
/// 视频与二维码用节目单里的预签名 URL。每 5 秒刷新。
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
      body { font-family: -apple-system, "Microsoft YaHei", sans-serif; background: #000;
             color: #fff; height: 100vh; display: flex; overflow: hidden; }
      #stage { flex: 1; display: flex; align-items: center; justify-content: center;
               background: radial-gradient(ellipse at center, #16121f 0%, #000 75%); }
      #player { max-width: 100%; max-height: 100vh; }
      #emptyHint { text-align: center; color: #666; font-size: 28px; line-height: 2; }
      aside { width: 430px; background: #131313; border-left: 1px solid #2c2c2c;
              display: flex; flex-direction: column; align-items: center;
              padding: 40px 28px; gap: 18px; }
      aside h1 { font-size: 30px; font-weight: 800; letter-spacing: 2px; }
      aside .sub { color: #888; font-size: 15px; }
      #qrbox { width: 340px; height: 340px; background: #fff; border-radius: 8px;
               display: flex; align-items: center; justify-content: center; }
      #qrbox img { width: 312px; height: 312px; image-rendering: pixelated; }
      #qrbox .waiting { color: #555; font-size: 17px; text-align: center; line-height: 1.8; }
      #meta { font-size: 18px; color: #aaa; }
      #list { width: 100%; flex: 1; overflow-y: auto; margin-top: 8px; }
      .item { display: flex; justify-content: space-between; align-items: center;
              padding: 12px 14px; border-radius: 10px; cursor: pointer; font-size: 16px; }
      .item:hover { background: #1a1a22; }
      .item.active { background: #26203a; }
      #brand { color: #444; font-size: 13px; letter-spacing: 3px; }
    </style>
    </head>
    <body>
    <div id="stage">
      <div id="emptyHint">🎥<br>等待第一段 360 视频…</div>
      <video id="player" autoplay muted loop playsinline style="display:none"></video>
    </div>
    <aside>
      <h1>扫码下载视频</h1>
      <div class="sub">SCAN TO DOWNLOAD</div>
      <div id="qrbox"><div class="waiting">— 暂无内容 —</div></div>
      <div id="meta"></div>
      <div id="list"></div>
      <div id="brand">BOOTH360 LIVE · CLOUD</div>
    </aside>

    <script>
    let items = [];
    let featuredId = null;
    let userPickAt = 0;

    function feature(id, byUser) {
      const item = items.find(x => x.id === id);
      if (!item) return;
      if (byUser) userPickAt = Date.now();
      if (featuredId !== id) {
        featuredId = id;
        const player = document.getElementById("player");
        document.getElementById("emptyHint").style.display = "none";
        player.style.display = "block";
        player.src = item.url;
        player.load();
        player.play().catch(() => {});
      }
      const qrbox = document.getElementById("qrbox");
      qrbox.innerHTML = `<img src="${item.qr}" alt="QR">`;
      document.getElementById("meta").textContent = `#${item.no} · ${item.time}`;
      renderList();
    }

    function renderList() {
      document.getElementById("list").innerHTML = items.map(item => `
        <div class="item ${item.id === featuredId ? "active" : ""}" onclick="feature('${item.id}', true)">
          <span>#${item.no} · ${item.time}</span>
          <span style="color:#4caf50;font-size:13px">✓ 可下载</span>
        </div>`).join("");
    }

    async function refresh() {
      try {
        const response = await fetch(`./wall.json?ts=${Date.now()}`, { cache: "no-store" });
        const manifest = await response.json();
        const data = manifest.items || [];
        data.forEach((item, index) => { item.no = data.length - index; });
        items = data;
        if (items.length > 0 && Date.now() - userPickAt > 45000 && featuredId !== items[0].id) {
          feature(items[0].id, false);
        } else {
          renderList();
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
