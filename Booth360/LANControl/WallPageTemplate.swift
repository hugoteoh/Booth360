import Foundation

/// 大屏页共享模板 —— 视觉整套照抄用户 AI PhotoBooth 的 Bigscreen wall 模式
/// （bigscreen.html：#06080d 底色、暗角、自适应列数公式、wallIn 入场、wallGlow 呼吸），
/// 卡片换成「循环视频 + 专属二维码」。
///
/// 三种布局模式（右上角 ⚙ 面板切换，选择存浏览器 localStorage，各大屏独立）：
///   grid      网格：全部平铺（自适应列数）
///   featured  最新主打：最新一条最大在中上，其余小卡在下排
///   cinema    全屏轮播：一次一条近全屏 + 大二维码，定时自动切换
///
/// variantJS 需要定义：
///   REFRESH_MS            轮询间隔
///   async fetchItems()    → [{id, videoURL, qrURL(可空), state}]（新→旧）
///   GEAR_HREF             控制台链接（空字符串 = 面板里不显示该入口）
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
          .wait{position:fixed;inset:0;display:flex;flex-direction:column;align-items:center;
                justify-content:center;gap:1.4vh;text-align:center;
                font-size:clamp(26px,3.4vw,58px);font-weight:800;z-index:5;
                animation:waitpulse 2.8s ease-in-out infinite}
          .wait .ic{font-size:clamp(44px,7vw,120px);line-height:1}
          .wait .en{font-size:clamp(14px,1.5vw,26px);font-weight:600;color:#9aa6b2;letter-spacing:1px}
          @keyframes waitpulse{0%,100%{opacity:.58}50%{opacity:.96}}

          /* 通用卡片（照抄 wgrid/wcell 的动效参数） */
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

          /* 模式一：网格 —— 固定按 8 格（4×2）的卡片尺寸排版：
             视频少时不放大（避免撑爆挤掉二维码），不满一排自动居中 */
          #stage.m-grid{position:fixed;inset:0;display:flex;flex-wrap:wrap;
                gap:clamp(12px,1.3vw,22px);
                padding:clamp(28px,4vh,56px) clamp(36px,4vw,70px);
                justify-content:center;align-content:center;perspective:2200px}
          #stage.m-grid .wcell{height:calc((100% - clamp(12px,1.3vw,22px)) / 2)}

          /* 模式二：最新主打（最大在中上，其余小卡在下） */
          #stage.m-featured{position:fixed;inset:0;display:flex;flex-direction:column;
                gap:clamp(10px,1.6vh,20px);
                padding:clamp(22px,3.2vh,44px) clamp(30px,3.4vw,60px)}
          .feat-hero{flex:1.6;display:flex;justify-content:center;align-items:flex-end;
                gap:12px;min-height:0}
          .feat-hero .wcell{height:100%;min-height:0}
          /* 二维码绝对定位挂在视频右侧：视频本体严格屏幕居中，不被二维码挤偏 */
          .feat-hero .qrbox{width:clamp(84px,8vw,128px);position:absolute;
                left:100%;bottom:8px;margin-left:14px}
          .feat-strip{flex:.45;display:flex;justify-content:space-evenly;align-items:flex-end;
                gap:clamp(10px,1.2vw,20px);min-height:0}
          .feat-strip .wcell{flex:0 1 auto;height:100%}
          .feat-strip .qrbox{width:clamp(64px,6.4vw,96px)}

          /* 模式三：全屏轮播（一次一条 + 大二维码 + 进度条） */
          #stage.m-cinema{position:fixed;inset:0;display:flex;align-items:center;
                justify-content:center;padding:3vh 0}
          .cine{height:100%;display:flex;align-items:center;justify-content:center}
          .cine video{height:min(90vh,100%);aspect-ratio:9/16;object-fit:cover;
                background:#0b0e13;border-radius:6px;
                box-shadow:0 24px 70px rgba(0,0,0,.6),0 4px 12px rgba(0,0,0,.45);
                animation:wallIn .9s cubic-bezier(.22,.61,.36,1) backwards,
                          wallGlow 9s ease-in-out infinite}
          .cine-qr{position:fixed;right:clamp(20px,3.4vw,64px);bottom:clamp(26px,6vh,72px);
                width:clamp(110px,11vw,176px);z-index:6;margin:0}
          .cine-count{position:fixed;left:clamp(20px,3.4vw,64px);bottom:clamp(26px,6vh,72px);
                z-index:6;font-size:clamp(13px,1.2vw,20px);font-weight:700;color:#9aa6b2;
                letter-spacing:2px}
          #cineBar{position:fixed;left:0;bottom:0;height:4px;width:100%;z-index:7;
                background:rgba(255,255,255,.08);display:none}
          #cineBar i{display:block;height:100%;width:0;background:#f2f5f9;opacity:.65}
          @keyframes cineProg{from{width:0}to{width:100%}}

          /* 右上角设置 */
          /* 隐形设置热区：右上角 64px 可点，平时完全不可见，鼠标悬停才微微显形 */
          #gear{position:fixed;top:0;right:0;z-index:9;width:64px;height:64px;
                display:flex;align-items:center;justify-content:center;
                font-size:24px;line-height:1;color:#f2f5f9;opacity:0;
                cursor:pointer;user-select:none;transition:opacity .25s}
          #gear:hover{opacity:.55}
          #panel{position:fixed;inset:0;z-index:20;display:none;align-items:center;
                justify-content:center;background:rgba(0,0,0,.55)}
          #panel.open{display:flex}
          .pbox{width:min(460px,92vw);background:#0d1117;border:1px solid #1d232c;
                border-radius:16px;padding:26px 26px 22px;box-shadow:0 30px 80px rgba(0,0,0,.6)}
          .pbox h3{margin:0 0 16px;font-size:18px;letter-spacing:2px}
          .popt{display:flex;align-items:center;gap:14px;width:100%;text-align:left;
                background:#12161d;border:1px solid #232a34;border-radius:12px;
                padding:13px 16px;margin-bottom:10px;color:#f2f5f9;cursor:pointer;
                font:inherit;font-size:15px}
          .popt small{display:block;color:#8b97a3;font-size:12px;margin-top:2px}
          .popt .ic{font-size:22px;flex:none}
          .popt.active{border-color:#4c8dff;background:#14202f}
          .popt.active::after{content:"✓";margin-left:auto;color:#4c8dff;font-weight:800}
          .psec{margin:18px 0 4px;font-size:13px;color:#8b97a3;letter-spacing:1px}
          .bgrow{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
          .bgsw{width:38px;height:38px;border-radius:50%;border:2px solid #232a34;
                cursor:pointer;flex:none;padding:0}
          .bgsw.active{border-color:#4c8dff;box-shadow:0 0 0 2px rgba(76,141,255,.35)}
          .bgrow input[type=color]{width:38px;height:38px;border-radius:50%;border:2px solid #232a34;
                background:none;padding:0;cursor:pointer}
          .bgimg{display:flex;gap:8px;margin-top:10px}
          .bgimg input{flex:1;background:#12161d;border:1px solid #232a34;border-radius:10px;
                color:#f2f5f9;font:inherit;font-size:13px;padding:9px 12px;min-width:0}
          .bgimg button{background:#232a34;border:none;color:#f2f5f9;font:inherit;font-size:13px;
                padding:9px 16px;border-radius:10px;cursor:pointer;flex:none}
          .pfoot{display:flex;justify-content:space-between;align-items:center;margin-top:14px}
          .pfoot a{color:#8b97a3;font-size:13px;text-decoration:none}
          .pfoot a:hover{color:#f2f5f9}
          .pclose{background:#232a34;border:none;color:#f2f5f9;font:inherit;font-size:14px;
                padding:9px 22px;border-radius:10px;cursor:pointer}
        </style>
        </head>
        <body>
        <div class="wait" id="wait"><div class="ic">🎥</div><div>精彩即将开始…</div>
          <div class="en">Waiting for the first video…</div></div>
        <div id="stage"></div>
        <div id="cineBar"><i></i></div>
        <div class="vign"></div>
        <div id="gear" title="大屏设置">⚙</div>
        <div id="panel">
          <div class="pbox">
            <h3>大屏设置</h3>
            <div class="psec">布局模式</div>
            <div id="popts"></div>
            <div class="psec">性能</div>
            <div id="pperf"></div>
            <div class="psec">背景</div>
            <div class="bgrow" id="bgrow"></div>
            <div class="bgimg">
              <button id="bgupload">上传图片</button>
              <input id="bgurl" type="text" placeholder="或粘贴图片 URL（留空 = 不用图片）">
              <button id="bgapply">应用</button>
              <input id="bgfile" type="file" accept="image/*" style="display:none">
            </div>
            <div class="pfoot">
              <a id="consoleLink" href="#" style="display:none">打开控制台 →</a>
              <button class="pclose" id="pclose">关闭</button>
            </div>
          </div>
        </div>

        <script>
        \(variantJS)
        </script>
        <script>
        const MAX_CARDS = 8;
        const CINE_MS = 12000;
        const MODES = [
          { key: "grid",     ic: "▦", name: "网格",     desc: "全部平铺，自适应列数" },
          { key: "featured", ic: "▣", name: "最新主打", desc: "最新一条最大在中上，其余在下排" },
          { key: "cinema",   ic: "▶", name: "全屏轮播", desc: "一次一条近全屏，自动切换" },
        ];
        const stage = document.getElementById("stage");
        const cineBar = document.getElementById("cineBar");

        let mode = "grid";
        try { const m = localStorage.getItem("booth360.wall.mode");
              if (MODES.some(x => x.key === m)) mode = m; } catch (e) {}

        // 流畅模式：网格只播最新 4 条，其余静态首帧（弱电脑解不动 8 路 1080p 时开）
        let smooth = false;
        try { smooth = localStorage.getItem("booth360.wall.smooth") === "1"; } catch (e) {}

        let items = [];
        let sig = "";           // id+qr 指纹：没变就不动 DOM（视频不重启）
        let cineIdx = 0;
        let cineTimer = null;

        // —— 背景（预设 / 自定义颜色 / 图片 URL，存本机） ——
        const BGS = [
          { key: "obsidian", name: "曜石", css: "#06080d" },
          { key: "black",    name: "纯黑", css: "#000000" },
          { key: "navy",     name: "深蓝",
            css: "radial-gradient(120% 120% at 50% 30%,#0c1830 0%,#050a14 70%)" },
          { key: "violet",   name: "暗紫",
            css: "radial-gradient(120% 120% at 50% 30%,#1a0f2e 0%,#08050f 70%)" },
          { key: "ember",    name: "暗红",
            css: "radial-gradient(120% 120% at 50% 30%,#2a0d12 0%,#0d0507 70%)" },
        ];
        let bg = { type: "preset", key: "obsidian" };
        try { const saved = JSON.parse(localStorage.getItem("booth360.wall.bg") || "null");
              if (saved && saved.type) bg = saved; } catch (e) {}

        function applyBG() {
          if (bg.type === "image" && bg.url) {
            document.body.style.background =
              `#000 url("${bg.url}") center / cover no-repeat fixed`;
          } else if (bg.type === "color" && bg.value) {
            document.body.style.background = bg.value;
          } else {
            const p = BGS.find(x => x.key === bg.key) || BGS[0];
            document.body.style.background = p.css;
          }
        }
        function setBG(next) {
          bg = next;
          try { localStorage.setItem("booth360.wall.bg", JSON.stringify(bg)); } catch (e) {}
          applyBG(); buildBGRow();
        }
        function buildBGRow() {
          const row = document.getElementById("bgrow");
          row.innerHTML = "";
          for (const p of BGS) {
            const b = document.createElement("button");
            b.className = "bgsw" + (bg.type === "preset" && bg.key === p.key ? " active" : "");
            b.style.background = p.css;
            b.title = p.name;
            b.onclick = () => setBG({ type: "preset", key: p.key });
            row.appendChild(b);
          }
          const c = document.createElement("input");
          c.type = "color";
          c.value = bg.type === "color" ? bg.value : "#06080d";
          c.title = "自定义颜色";
          c.oninput = () => setBG({ type: "color", value: c.value });
          row.appendChild(c);
          // 上传的图片是超长 data: 串，不回填输入框，占位提示即可
          const urlInput = document.getElementById("bgurl");
          if (bg.type === "image" && bg.url && !bg.url.startsWith("data:")) {
            urlInput.value = bg.url;
            urlInput.placeholder = "或粘贴图片 URL（留空 = 不用图片）";
          } else {
            urlInput.value = "";
            urlInput.placeholder = bg.type === "image"
              ? "当前使用上传的图片（留空应用 = 恢复默认）"
              : "或粘贴图片 URL（留空 = 不用图片）";
          }
        }
        document.getElementById("bgapply").onclick = () => {
          const url = document.getElementById("bgurl").value.trim();
          setBG(url ? { type: "image", url } : { type: "preset", key: "obsidian" });
        };
        // 本地上传：读文件 → 压到 1920 宽 JPEG → data URL 存 localStorage（不经过服务器）
        document.getElementById("bgupload").onclick = () => {
          document.getElementById("bgfile").click();
        };
        document.getElementById("bgfile").onchange = (e) => {
          const file = e.target.files && e.target.files[0];
          if (!file) return;
          const fr = new FileReader();
          fr.onload = () => {
            const img = new Image();
            img.onload = () => {
              const scale = Math.min(1, 1920 / img.width);
              const c = document.createElement("canvas");
              c.width = Math.round(img.width * scale);
              c.height = Math.round(img.height * scale);
              c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
              setBG({ type: "image", url: c.toDataURL("image/jpeg", 0.82) });
            };
            img.src = fr.result;
          };
          fr.readAsDataURL(file);
          e.target.value = "";
        };
        applyBG();

        // —— 设置面板 ——
        const panel = document.getElementById("panel");
        const popts = document.getElementById("popts");
        function buildPanel() {
          popts.innerHTML = "";
          for (const m of MODES) {
            const b = document.createElement("button");
            b.className = "popt" + (m.key === mode ? " active" : "");
            b.innerHTML = `<span class="ic">${m.ic}</span><span>${m.name}<small>${m.desc}</small></span>`;
            b.onclick = () => { setMode(m.key); };
            popts.appendChild(b);
          }
        }
        function setMode(m) {
          mode = m;
          try { localStorage.setItem("booth360.wall.mode", m); } catch (e) {}
          buildPanel();
          render();
        }
        function buildPerf() {
          const box = document.getElementById("pperf");
          box.innerHTML = "";
          const b = document.createElement("button");
          b.className = "popt" + (smooth ? " active" : "");
          b.innerHTML = `<span class="ic">⚡</span><span>流畅模式` +
            `<small>大屏电脑卡顿时开：网格只播放最新 4 条，其余显示静态首帧</small></span>`;
          b.onclick = () => {
            smooth = !smooth;
            try { localStorage.setItem("booth360.wall.smooth", smooth ? "1" : "0"); } catch (e) {}
            buildPerf();
            if (mode === "grid") gridSync();
          };
          box.appendChild(b);
        }

        document.getElementById("gear").onclick = () => {
          buildPanel(); buildPerf(); buildBGRow(); panel.classList.add("open");
        };
        document.getElementById("pclose").onclick = () => panel.classList.remove("open");
        panel.onclick = (e) => { if (e.target === panel) panel.classList.remove("open"); };
        const consoleLink = document.getElementById("consoleLink");
        if (typeof GEAR_HREF === "string" && GEAR_HREF) {
          consoleLink.href = GEAR_HREF; consoleLink.style.display = "inline";
        }

        // —— 渲染 ——
        function qrHTML(item) {
          return item.qrURL
            ? `<img src="${item.qrURL}" alt="QR">`
            : `<div class="pending">☁️<br>${item.state || "上传中"}</div>`;
        }
        function cardHTML(item, i, play = true) {
          // play=false：只显示首帧不播放（#t=0.1 让浏览器 seek 到首帧），下排小卡用
          const video = play
            ? `<video src="${item.videoURL}" autoplay muted loop playsinline preload="auto"></video>`
            : `<video src="${item.videoURL}#t=0.1" muted playsinline preload="metadata"></video>`;
          return `<div class="wcell" style="--i:${i % 12}">${video}
            <div class="qrbox">${qrHTML(item)}</div></div>`;
        }

        function stopCine() {
          if (cineTimer) { clearInterval(cineTimer); cineTimer = null; }
          cineBar.style.display = "none";
        }

        // —— 网格：增量更新（已有视频不重建、新卡错峰加载，避免 8 路同时解码的卡顿） ——
        const gridKnown = new Map(); // id -> { el, hasQR, playing }

        function gridCardEl(item, i) {
          const el = document.createElement("div");
          el.className = "wcell";
          el.style.setProperty("--i", i % 12);
          el.innerHTML = `<video muted playsinline></video>
            <div class="qrbox">${qrHTML(item)}</div>`;
          return el;
        }

        /// 设置某张卡播放或静态首帧；delayMs 用于错峰，避免多路视频同时开载
        function setCardPlayback(entry, item, shouldPlay, delayMs) {
          entry.playing = shouldPlay;
          const v = entry.el.querySelector("video");
          setTimeout(() => {
            if (entry.playing !== shouldPlay || !v.isConnected) return;
            v.autoplay = shouldPlay; v.loop = shouldPlay;
            v.preload = shouldPlay ? "auto" : "metadata";
            const src = shouldPlay ? item.videoURL : item.videoURL + "#t=0.1";
            if (v.getAttribute("src") !== src) v.src = src;
            if (shouldPlay) {
              // 动态插入的元素一次 play() 可能太早被吞：数据到位后再补一次
              const tryPlay = () => {
                if (entry.playing && v.paused) {
                  const p = v.play(); if (p && p.catch) p.catch(() => {});
                }
              };
              v.addEventListener("loadeddata", tryPlay, { once: true });
              tryPlay();
            } else {
              v.pause();
            }
          }, delayMs || 0);
        }

        // 巡检：应播未播的（起播被吞 / 解码偶发卡停）每 4 秒救一次
        setInterval(() => {
          if (mode !== "grid") return;
          for (const entry of gridKnown.values()) {
            const v = entry.el.querySelector("video");
            if (entry.playing && v.paused && v.readyState >= 2) {
              const p = v.play(); if (p && p.catch) p.catch(() => {});
            }
          }
        }, 4000);

        function gridSync() {
          if (stage.dataset.rendered !== "grid") {
            stage.innerHTML = ""; gridKnown.clear(); stage.dataset.rendered = "grid";
          }
          // 移除已不在节目单里的
          for (const [id, entry] of Array.from(gridKnown)) {
            if (!items.some(x => x.id === id)) { entry.el.remove(); gridKnown.delete(id); }
          }
          // 新增的插到最前（其余卡片完全不动，播放不中断）
          const fresh = items.filter(x => !gridKnown.has(x.id));
          for (const item of fresh.slice().reverse()) {
            const el = gridCardEl(item, gridKnown.size);
            stage.prepend(el);
            gridKnown.set(item.id, { el, hasQR: !!item.qrURL, playing: null });
          }
          // 上传完成 → 二维码原位浮现
          for (const item of items) {
            const entry = gridKnown.get(item.id);
            if (entry && !entry.hasQR && item.qrURL) {
              entry.el.querySelector(".qrbox").innerHTML = qrHTML(item);
              entry.hasQR = true;
            }
          }
          // 播放策略：流畅模式只播最新 4 条；需要变更的卡按 300ms 错峰执行
          const limit = smooth ? 4 : Infinity;
          let stagger = 0;
          items.forEach((item, idx) => {
            const entry = gridKnown.get(item.id);
            if (!entry) return;
            const shouldPlay = idx < limit;
            const loaded = !!entry.el.querySelector("video").getAttribute("src");
            if (!loaded || entry.playing !== shouldPlay) {
              setCardPlayback(entry, item, shouldPlay, stagger);
              stagger += 300;
            }
          });
        }

        function render() {
          stopCine();
          stage.className = "m-" + mode;
          if (mode !== "grid") { gridKnown.clear(); stage.dataset.rendered = mode; }
          if (!items.length) { stage.innerHTML = ""; gridKnown.clear(); return; }

          if (mode === "grid") {
            gridSync();
            return; // 播放由 gridSync 的错峰逻辑负责，不走 nudgePlay

          } else if (mode === "featured") {
            const hero = items[0];
            const rest = items.slice(1, 7);
            stage.innerHTML =
              `<div class="feat-hero">${cardHTML(hero, 0)}</div>` +
              (rest.length
                ? `<div class="feat-strip">${rest.map((x, i) => cardHTML(x, i + 1, false)).join("")}</div>`
                : "");
            // 下排放不下就少放几张（绝不切边）；视频尺寸要等元数据回来才定，多测几轮
            const strip = stage.querySelector(".feat-strip");
            if (strip) {
              const trim = () => {
                while (strip.scrollWidth > strip.clientWidth + 2 && strip.children.length > 1) {
                  strip.lastElementChild.remove();
                }
              };
              trim();
              setTimeout(trim, 600);
              setTimeout(trim, 2000);
            }

          } else {
            renderCine();
            if (items.length > 1) cineTimer = setInterval(() => {
              cineIdx = (cineIdx + 1) % items.length;
              renderCine();
            }, CINE_MS);
          }
          nudgePlay();
        }

        /* 个别浏览器 innerHTML 注入后 autoplay 偶发不触发，补一脚 play() */
        function nudgePlay() {
          stage.querySelectorAll("video[autoplay]").forEach(v => {
            const p = v.play();
            if (p && p.catch) p.catch(() => {});
          });
        }

        function renderCine() {
          if (cineIdx >= items.length) cineIdx = 0;
          const item = items[cineIdx];
          stage.innerHTML = `<div class="cine">
              <video src="${item.videoURL}" autoplay muted loop playsinline preload="auto"></video>
            </div>
            <div class="qrbox cine-qr">${qrHTML(item)}</div>
            <div class="cine-count">${cineIdx + 1} / ${items.length}</div>`;
          if (items.length > 1) {
            cineBar.style.display = "block";
            const bar = cineBar.querySelector("i");
            bar.style.animation = "none";
            void bar.offsetWidth; // 重置进度动画
            bar.style.animation = `cineProg ${CINE_MS}ms linear forwards`;
          } else {
            cineBar.style.display = "none";
          }
          nudgePlay();
        }

        // —— 轮询 ——
        async function refresh() {
          try {
            items = (await fetchItems()).slice(0, MAX_CARDS);
            document.getElementById("wait").style.display = items.length ? "none" : "flex";
            const s = items.map(x => x.id + "|" + (x.qrURL ? 1 : 0)).join(",");
            if (s !== sig) { sig = s; cineIdx = 0; render(); }
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
