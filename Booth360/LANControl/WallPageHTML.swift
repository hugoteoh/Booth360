import Foundation

/// 大屏展示页（格莱美式现场大屏）：
/// 大屏电脑/电视浏览器打开 http://<手机IP>:8360/wall 并全屏（F11）。
/// 最新成品自动上屏循环播放（视频走局域网、不等云端），旁边是下载二维码；
/// 上传一完成二维码自动出现。点右侧历史条目可手动切换展示。
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
      body { font-family: -apple-system, "Microsoft YaHei", sans-serif; background: #000;
             color: #fff; height: 100vh; display: flex; overflow: hidden; }
      #stage { flex: 1; display: flex; align-items: center; justify-content: center;
               background: radial-gradient(ellipse at center, #16121f 0%, #000 75%); }
      #player { max-width: 100%; max-height: 100vh; }
      #emptyHint { text-align: center; color: #666; font-size: 28px; line-height: 2; }
      aside { width: 430px; background: #0d0d12; border-left: 1px solid #222;
              display: flex; flex-direction: column; align-items: center;
              padding: 40px 28px; gap: 18px; }
      aside h1 { font-size: 30px; font-weight: 800; letter-spacing: 2px; }
      aside .sub { color: #888; font-size: 15px; }
      #qrbox { width: 300px; height: 300px; background: #fff; border-radius: 20px;
               display: flex; align-items: center; justify-content: center; }
      #qrbox img { width: 272px; height: 272px; image-rendering: pixelated; }
      #qrbox .waiting { color: #555; font-size: 17px; text-align: center; line-height: 1.8; }
      #meta { font-size: 18px; color: #aaa; }
      #list { width: 100%; flex: 1; overflow-y: auto; margin-top: 8px; }
      .item { display: flex; justify-content: space-between; align-items: center;
              padding: 12px 14px; border-radius: 10px; cursor: pointer; font-size: 16px; }
      .item:hover { background: #1a1a22; }
      .item.active { background: #26203a; }
      .item .state-done { color: #4caf50; font-size: 13px; }
      .item .state-wait { color: #b8860b; font-size: 13px; }
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
      <div id="brand">BOOTH360 LIVE</div>
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
        player.src = `/video/${id}`;
        player.load();
        player.play().catch(() => {});
      }
      updateSide();
      renderList();
    }

    function updateSide() {
      const item = items.find(x => x.id === featuredId);
      const qrbox = document.getElementById("qrbox");
      const meta = document.getElementById("meta");
      if (!item) { qrbox.innerHTML = `<div class="waiting">— 暂无内容 —</div>`; meta.textContent = ""; return; }
      if (item.uploaded) {
        qrbox.innerHTML = `<img src="/qr/${item.id}?v=1" alt="QR">`;
      } else {
        qrbox.innerHTML = `<div class="waiting">☁️ 视频上传中<br>二维码马上出现…</div>`;
      }
      meta.textContent = `#${item.no} · ${item.time}`;
    }

    function renderList() {
      const list = document.getElementById("list");
      list.innerHTML = items.map(item => `
        <div class="item ${item.id === featuredId ? "active" : ""}" onclick="feature('${item.id}', true)">
          <span>#${item.no} · ${item.time}</span>
          <span class="${item.uploaded ? "state-done" : "state-wait"}">${item.uploaded ? "✓ 可下载" : "上传中"}</span>
        </div>`).join("");
    }

    async function refresh() {
      try {
        const data = await (await fetch("/api/renders")).json();
        data.forEach((item, index) => { item.no = data.length - index; });
        const prevFeatured = items.find(x => x.id === featuredId);
        items = data;
        // 新视频自动上屏（除非 45 秒内有人手动点选）
        if (items.length > 0 && Date.now() - userPickAt > 45000 && featuredId !== items[0].id) {
          feature(items[0].id, false);
        } else {
          // 上传状态可能刚翻转，刷新二维码区域
          const nowFeatured = items.find(x => x.id === featuredId);
          if (nowFeatured && (!prevFeatured || prevFeatured.uploaded !== nowFeatured.uploaded)) updateSide();
          renderList();
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
