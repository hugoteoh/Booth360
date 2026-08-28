import Foundation

/// 内嵌的浏览器控制台页面。Windows/Mac 同一 Wi-Fi 下浏览器打开
/// http://<手机IP>:8360 即可控制，无需安装任何软件。
enum ControlPageHTML {
    static let html = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Booth360 控制台</title>
    <style>
      body { font-family: -apple-system, "Microsoft YaHei", sans-serif; background:#111; color:#eee;
             max-width: 560px; margin: 0 auto; padding: 24px 16px; }
      h1 { font-size: 22px; } h2 { font-size: 15px; color:#aaa; margin-top: 28px; }
      button { font-size: 16px; padding: 10px 18px; margin: 4px 6px 4px 0; border: 0;
               border-radius: 10px; background:#333; color:#fff; cursor: pointer; }
      button.primary { background:#e33; font-weight: 700; }
      button:disabled { opacity:.4; }
      input { font-size: 16px; padding: 8px 10px; border-radius: 8px; border: 1px solid #444;
              background:#222; color:#fff; width: 110px; }
      #status { background:#1c1c1e; border-radius: 12px; padding: 14px; font-size: 14px;
                line-height: 1.7; white-space: pre-wrap; }
      .event { display:flex; justify-content: space-between; align-items:center;
               background:#1c1c1e; border-radius: 10px; padding: 10px 14px; margin: 6px 0; }
      .tag { color:#4caf50; font-size: 12px; margin-left: 8px; }
      #msg { color:#ffb300; min-height: 20px; font-size: 14px; }
    </style>
    </head>
    <body>
    <h1>🎥 Booth360 控制台</h1>
    <div>管理员 PIN：<input id="pin" type="password" placeholder="1234"></div>
    <div id="msg"></div>

    <h2>状态</h2>
    <div id="status">加载中…</div>

    <h2>控制</h2>
    <button class="primary" onclick="post('/api/guest/start')">▶ 开始拍摄</button>
    <button onclick="post('/api/guest/open')">打开嘉宾模式</button>
    <button onclick="window.open('/wall', '_blank')">🖥 打开大屏展示页</button>

    <h2>活动</h2>
    <div id="events">加载中…</div>

    <script>
    const pinInput = document.getElementById('pin');
    pinInput.value = localStorage.getItem('booth360pin') || '';
    pinInput.addEventListener('input', () => localStorage.setItem('booth360pin', pinInput.value));

    function msg(text) {
      document.getElementById('msg').textContent = text;
      if (text) setTimeout(() => msg(''), 4000);
    }

    async function post(path, extra) {
      try {
        const url = path + '?pin=' + encodeURIComponent(pinInput.value) + (extra || '');
        const res = await fetch(url, { method: 'POST' });
        const data = await res.json();
        if (!data.ok) msg(data.message || '操作失败'); else msg('✓ 已执行');
        refresh();
      } catch (e) { msg('网络错误：' + e); }
    }

    async function refresh() {
      try {
        const status = await (await fetch('/api/status')).json();
        document.getElementById('status').textContent =
          '拍摄状态：' + status.guestPhase + (status.guestActive ? '（嘉宾模式）' : '') + '\\n' +
          '当前活动：' + (status.activeEvent || '未设置') + '\\n' +
          '剩余存储：' + status.storageGB + ' GB · 电量：' + status.battery + '\\n' +
          '上传队列：待传 ' + status.uploadsPending + ' · 失败 ' + status.uploadsFailed;
        const events = await (await fetch('/api/events')).json();
        document.getElementById('events').innerHTML = events.map(e =>
          '<div class="event"><span>' + e.name + (e.active ? '<span class="tag">当前</span>' : '') +
          '</span><button onclick="post(\\'/api/events/activate\\', \\'&id=' + e.id + '\\')">设为当前</button></div>'
        ).join('') || '暂无活动';
      } catch (e) {
        document.getElementById('status').textContent = '连接中断，重试中…';
      }
    }
    refresh();
    setInterval(refresh, 2000);
    </script>
    </body>
    </html>
    """
}
