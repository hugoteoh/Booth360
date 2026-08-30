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
          <button class="dl" id="dlall" style="margin-left:auto" disabled>下载全部 ZIP</button>
        </header>
        <div id="grid"></div>
        <div class="empty" id="empty" style="display:none">还没有视频</div>

        <script>
        \(variantJS)
        </script>
        <script>
        const grid = document.getElementById("grid");
        let sig = "";
        let lastItems = [];
        let zipBusy = false;

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
            lastItems = items;
            document.getElementById("count").textContent = `共 ${items.length} 条`;
            document.getElementById("empty").style.display = items.length ? "none" : "block";
            document.getElementById("dlall").disabled = !items.length || zipBusy;
            const s = items.map(x => x.id).join(",");
            if (s !== sig) { sig = s; grid.innerHTML = items.map(cardHTML).join(""); observeLazy(); }
          } catch (e) { /* 网络抖动，下轮再试 */ }
        }
        load();
        setInterval(load, REFRESH_MS);

        // —— 一键打包下载全部（STORE 型 ZIP，视频本身已压缩无需再压） ——
        // Chrome/Edge 桌面：File System Access API 流式写盘，内存只占一条视频；
        // 其他浏览器：内存拼装后一次性保存（超大时给出提示）。
        const CRC_TABLE = (() => {
          const t = new Uint32Array(256);
          for (let n = 0; n < 256; n++) {
            let c = n;
            for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
            t[n] = c >>> 0;
          }
          return t;
        })();
        function crc32(buf) {
          let c = 0xFFFFFFFF;
          for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
          return (c ^ 0xFFFFFFFF) >>> 0;
        }
        function le16(v) { return [v & 255, (v >>> 8) & 255]; }
        function le32(v) { return [v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255]; }
        function dosDateTime(d) {
          return {
            time: ((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)) & 0xFFFF,
            date: (((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) & 0xFFFF,
          };
        }

        document.getElementById("dlall").addEventListener("click", async () => {
          if (zipBusy || !lastItems.length) return;
          const button = document.getElementById("dlall");
          zipBusy = true; button.disabled = true;
          const items = lastItems.slice();
          const zipName = "booth360-videos.zip";
          try {
            // 输出端：优先流式写盘
            let writable = null;
            const parts = [];
            if (window.showSaveFilePicker) {
              const handle = await showSaveFilePicker({
                suggestedName: zipName,
                types: [{ description: "ZIP", accept: { "application/zip": [".zip"] } }],
              });
              writable = await (await handle).createWritable();
            }
            const writeOut = async (u8) => { if (writable) await writable.write(u8); else parts.push(u8); };

            const encoder = new TextEncoder();
            const now = dosDateTime(new Date());
            const central = [];
            let offset = 0, packed = 0, failed = 0;
            const LIMIT = 3800 * 1024 * 1024; // zip32 安全上限

            for (let i = 0; i < items.length; i++) {
              button.textContent = `打包中 ${i + 1}/${items.length}`;
              let data;
              try {
                data = new Uint8Array(await (await fetch(items[i].videoURL)).arrayBuffer());
              } catch (e) { failed++; continue; }
              if (offset + data.length > LIMIT) { failed += items.length - i; break; }
              const safeTime = (items[i].time || String(i)).replace(/[^0-9A-Za-z-]/g, "");
              const nameBytes = encoder.encode(`booth360-${safeTime}-${i + 1}.mp4`);
              const crc = crc32(data);
              const header = new Uint8Array([
                0x50, 0x4B, 0x03, 0x04, ...le16(20), ...le16(0x0800), ...le16(0),
                ...le16(now.time), ...le16(now.date), ...le32(crc),
                ...le32(data.length), ...le32(data.length),
                ...le16(nameBytes.length), ...le16(0), ...nameBytes,
              ]);
              await writeOut(header); await writeOut(data);
              central.push({ nameBytes, crc, size: data.length, offset });
              offset += header.length + data.length;
              packed++;
            }

            // 中央目录
            let cdSize = 0;
            for (const e of central) {
              const entry = new Uint8Array([
                0x50, 0x4B, 0x01, 0x02, ...le16(20), ...le16(20), ...le16(0x0800), ...le16(0),
                ...le16(now.time), ...le16(now.date), ...le32(e.crc),
                ...le32(e.size), ...le32(e.size), ...le16(e.nameBytes.length),
                ...le16(0), ...le16(0), ...le16(0), ...le16(0), ...le32(0),
                ...le32(e.offset), ...e.nameBytes,
              ]);
              await writeOut(entry); cdSize += entry.length;
            }
            await writeOut(new Uint8Array([
              0x50, 0x4B, 0x05, 0x06, ...le16(0), ...le16(0),
              ...le16(central.length), ...le16(central.length),
              ...le32(cdSize), ...le32(offset), ...le16(0),
            ]));

            if (writable) {
              await writable.close();
            } else {
              const blob = new Blob(parts, { type: "application/zip" });
              const a = document.createElement("a");
              a.href = URL.createObjectURL(blob); a.download = zipName;
              document.body.appendChild(a); a.click(); a.remove();
              setTimeout(() => URL.revokeObjectURL(a.href), 10000);
            }
            button.textContent = failed
              ? `完成 ${packed} 条（${failed} 条失败/超限）` : `完成 ✓ ${packed} 条`;
          } catch (e) {
            // 用户取消保存对话框也会走到这里，恢复即可
            button.textContent = "下载全部 ZIP";
          }
          zipBusy = false; button.disabled = false;
          setTimeout(() => { button.textContent = "下载全部 ZIP"; }, 6000);
        });
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
