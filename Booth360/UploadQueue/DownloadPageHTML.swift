import Foundation

/// 嘉宾扫码后的下载落地页（发布到 COS：booth360/<id>/index.html，公开可读）。
/// 设计照搬 Glambot 验证过的方案：
/// - 单屏：视频（≤66vh）+ 大下载按钮永远在首屏，无需下滑
/// - 下载按钮 fetch→blob→<a download> 强制真下载（COS 需配 CORS GET），失败回退直开文件
/// - 微信内 WeixinJSBridgeReady/touchstart 自动取消静音播放
/// - 视频链接 7 天有效，过期显示友好提示（页面本身地址永久）
enum DownloadPageHTML {

    static func html(videoURL: String, title: String, brandName: String) -> String {
        let brand = brandName.isEmpty ? "BOOTH360" : brandName
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          body { min-height:100dvh; background:#0a0a0f; color:#fff;
                 font-family:-apple-system,"Microsoft YaHei",sans-serif;
                 display:flex; flex-direction:column; align-items:center; justify-content:center;
                 padding:14px 16px calc(16px + env(safe-area-inset-bottom)); }
          .brand { color:#888; font-size:12px; letter-spacing:.3em; margin-bottom:12px; }
          .vwrap { width:100%; max-width:560px; display:flex; justify-content:center; }
          video { width:100%; max-height:66vh; background:#000;
                  border:1px solid rgba(255,255,255,.14); object-fit:contain; }
          .btns { width:100%; max-width:560px; margin-top:14px; }
          .btns a { display:flex; align-items:center; justify-content:center; height:50px;
                    background:linear-gradient(135deg,#ff3c78,#ffa028); color:#fff;
                    font-weight:700; font-size:15px; letter-spacing:.15em; text-decoration:none; }
          #videoError { display:none; color:#f4c542; font-size:14px; line-height:1.7;
                        text-align:center; margin-top:16px; max-width:400px; }
        </style>
        </head>
        <body>
        <div class="brand">\(brand)</div>
        <div class="vwrap" id="vwrap">
          <video id="video" src="\(videoURL)" controls autoplay muted loop playsinline preload="metadata"></video>
        </div>
        <p id="videoError">视频链接可能已过期或网络暂时不可用。请稍后重试，或联系现场工作人员重新生成下载链接。</p>
        <div class="btns"><a href="\(videoURL)" download>下载视频</a></div>

        <script>
        (function () {
          var video = document.getElementById("video");
          // 微信等内嵌浏览器：桥接就绪/首次触摸时取消静音
          function unmute() {
            if (!video) return;
            video.muted = false; video.volume = 1;
            var p = video.play && video.play();
            if (p && p.catch) p.catch(function () {});
          }
          document.addEventListener("WeixinJSBridgeReady", unmute, false);
          document.addEventListener("touchstart", unmute, { once: true });
          if (video) {
            video.addEventListener("error", function () {
              document.getElementById("videoError").style.display = "block";
            });
          }
          // 下载按钮：fetch → blob → <a download> 强制真下载；失败回退直开文件
          var button = document.querySelector(".btns a");
          if (button) {
            button.addEventListener("click", function (e) {
              var url = button.getAttribute("href");
              if (!url || !window.fetch || !window.URL || !URL.createObjectURL) return;
              e.preventDefault();
              var original = button.textContent;
              button.textContent = "下载中…"; button.style.opacity = "0.7";
              fetch(url).then(function (r) { return r.blob(); }).then(function (blob) {
                var objectURL = URL.createObjectURL(blob);
                var a = document.createElement("a");
                a.href = objectURL; a.download = "booth360.mp4";
                document.body.appendChild(a); a.click(); a.remove();
                setTimeout(function () { URL.revokeObjectURL(objectURL); }, 6000);
                button.textContent = original; button.style.opacity = "1";
              }).catch(function () {
                button.textContent = original; button.style.opacity = "1";
                window.location.href = url;
              });
            });
          }
        })();
        </script>
        </body>
        </html>
        """
    }
}
