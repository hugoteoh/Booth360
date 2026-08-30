import Foundation

/// 视频总览页（大屏设置面板里的「视频总览」入口打开）：
/// 网格列出当前活动的全部视频（不止大屏的 8 条），每条可直接播放 + 下载。
///
/// variantJS 需要定义：
///   REFRESH_MS                     轮询间隔
///   async fetchGalleryItems()      → [{id, time, videoURL}]（新→旧）
enum GalleryPageTemplate {

    static func page(variantJS: String) -> String {
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Booth360 视频总览</title>
        <style>
          *{box-sizing:border-box} html,body{margin:0}
          body{background:#06080d;color:#f2f5f9;min-height:100vh;
               font-family:system-ui,'PingFang SC','Microsoft YaHei',sans-serif}
          header{position:sticky;top:0;z-index:5;display:flex;align-items:baseline;gap:14px;
                 padding:16px 22px;background:rgba(6,8,13,.92);backdrop-filter:blur(8px);
                 border-bottom:1px solid #171c24}
          header h1{margin:0;font-size:17px;letter-spacing:2px}
          header .sub{color:#8b97a3;font-size:13px}
          #grid{display:grid;gap:16px;padding:18px 22px 40px;
                grid-template-columns:repeat(auto-fill,minmax(190px,1fr))}
          .card{background:#0d1117;border:1px solid #1a212b;border-radius:12px;
                overflow:hidden;display:flex;flex-direction:column}
          .card video{width:100%;aspect-ratio:9/16;object-fit:cover;background:#000;display:block}
          .meta{display:flex;align-items:center;justify-content:space-between;
                gap:8px;padding:10px 12px}
          .meta .time{font-size:12px;color:#8b97a3}
          .dl{background:#fff;color:#000;border:none;border-radius:8px;font:inherit;
              font-size:13px;font-weight:600;padding:7px 14px;cursor:pointer;flex:none;
              -webkit-tap-highlight-color:transparent}
          .dl:active{opacity:.7}
          .dl[disabled]{opacity:.5;cursor:default}
          .empty{padding:80px 20px;text-align:center;color:#8b97a3;font-size:15px}
        </style>
        </head>
        <body>
        <header>
          <h1>视频总览</h1>
          <span class="sub" id="count">加载中…</span>
        </header>
        <div id="grid"></div>
        <div class="empty" id="empty" style="display:none">还没有视频</div>

        <script>
        \(variantJS)
        </script>
        <script>
        const grid = document.getElementById("grid");
        let sig = "";

        function cardHTML(item) {
          // 不直接给 src：滚到视口附近才加载首帧（171 条也秒开）
          return `<div class="card">
            <video data-src="${item.videoURL}" controls muted playsinline preload="none"></video>
            <div class="meta">
              <span class="time">${item.time || ""}</span>
              <button class="dl" data-url="${item.videoURL}" data-name="booth360-${(item.time || item.id).replace(/[^0-9A-Za-z-]/g, "")}.mp4">下载</button>
            </div></div>`;
        }

        // 视口懒加载：进入屏幕前 300px 才加载该条的首帧元数据
        const lazyLoader = new IntersectionObserver((entries) => {
          for (const entry of entries) {
            if (!entry.isIntersecting) continue;
            const v = entry.target;
            if (!v.getAttribute("src")) {
              v.preload = "metadata";
              v.src = v.dataset.src + "#t=0.1";
            }
            lazyLoader.unobserve(v);
          }
        }, { rootMargin: "300px 0px" });

        function observeLazy() {
          // 极老的浏览器不支持 IntersectionObserver 时退回全量加载
          if (!("IntersectionObserver" in window)) {
            grid.querySelectorAll("video:not([src])").forEach(v => {
              v.preload = "metadata"; v.src = v.dataset.src + "#t=0.1";
            });
            return;
          }
          grid.querySelectorAll("video:not([src])").forEach(v => lazyLoader.observe(v));
        }

        // 同一时间只播一条：新的一开播，其他全部暂停
        grid.addEventListener("play", (e) => {
          grid.querySelectorAll("video").forEach(v => {
            if (v !== e.target && !v.paused) v.pause();
          });
        }, true);

        // 下载：fetch → blob → <a download> 强制真下载；失败回退直开文件
        grid.addEventListener("click", (e) => {
          const button = e.target.closest(".dl");
          if (!button || button.disabled) return;
          const url = button.dataset.url;
          if (!window.fetch || !window.URL || !URL.createObjectURL) {
            window.location.href = url; return;
          }
          button.disabled = true;
          const original = button.textContent;
          button.textContent = "下载中…";
          fetch(url).then(r => r.blob()).then(blob => {
            const objectURL = URL.createObjectURL(blob);
            const a = document.createElement("a");
            a.href = objectURL; a.download = button.dataset.name || "booth360.mp4";
            document.body.appendChild(a); a.click(); a.remove();
            setTimeout(() => URL.revokeObjectURL(objectURL), 6000);
            button.textContent = original; button.disabled = false;
          }).catch(() => {
            button.textContent = original; button.disabled = false;
            window.location.href = url;
          });
        });

        async function load() {
          try {
            const items = await fetchGalleryItems();
            document.getElementById("count").textContent = `共 ${items.length} 条`;
            document.getElementById("empty").style.display = items.length ? "none" : "block";
            const s = items.map(x => x.id).join(",");
            if (s !== sig) { sig = s; grid.innerHTML = items.map(cardHTML).join(""); observeLazy(); }
          } catch (e) { /* 网络抖动，下轮再试 */ }
        }
        load();
        setInterval(load, REFRESH_MS);
        </script>
        </body>
        </html>
        """
    }
}

/// 云端版：数据来自同目录 gallery.json（手机每次发布大屏时一并生成，含当前活动全部已上传成品）。
enum CloudGalleryPageHTML {
    static let html = GalleryPageTemplate.page(variantJS: """
    const REFRESH_MS = 30000;
    async function fetchGalleryItems() {
      const response = await fetch(`./gallery.json?ts=${Date.now()}`, { cache: "no-store" });
      const manifest = await response.json();
      return (manifest.items || []).map(item => ({
        id: item.id, time: item.time, videoURL: item.url
      }));
    }
    """)
}

/// 局域网版：数据来自 /api/renders，视频走 /video/<id>。
enum LANGalleryPageHTML {
    static let html = GalleryPageTemplate.page(variantJS: """
    const REFRESH_MS = 10000;
    async function fetchGalleryItems() {
      const data = await (await fetch("/api/renders")).json();
      return data.map(item => ({
        id: item.id, time: item.time, videoURL: `/video/${item.id}`
      }));
    }
    """)
}
