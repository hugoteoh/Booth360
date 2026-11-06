# 大屏二维码真实浏览器回归

在此目录运行 `npm ci`、`npm test`。固定 Playwright 1.65.0，使用 Node 自带的测试运行器。

默认优先使用 Windows 的 `C:\Program Files\Google\Chrome\Application\chrome.exe` 或 Linux 的 `/opt/google/chrome/chrome`、`/usr/bin/google-chrome`、`/usr/bin/google-chrome-stable`，浏览器无头运行并使用独立临时 profile；不会连接或修改用户已打开的 Chrome。也可设置 `BOOTH360_CHROME_PATH`（兼容 `CHROME_PATH`）；找不到系统 Chrome 时使用 Playwright Chromium（先执行 `npx playwright install --with-deps chromium`），兼容 Linux CI。真实 H.264 播放断言始终执行，不因浏览器缺少编解码器而跳过。

测试从 `../Booth360/LANControl/WallPageTemplate.swift` 实际提取 HTML，只注入本地节目单接口，不复制待测脚本。全部请求限制为临时本地 HTTP 服务器；二维码图片使用本地 SVG，仅验证下载、解码和恢复状态，不验证扫码识别。FFmpeg 临时生成可播放的 10 秒 H.264 MP4，用真实播放进度与节点身份确认更新二维码不会重建视频。优先读取 `FFMPEG_PATH`，其次使用本机 `D:\AR镜面签\app\resources\bin\ffmpeg.exe`，最后尝试 PATH 的 `ffmpeg`。

测试临时文件写入操作系统临时目录下本次运行创建的 `booth360-wall-test-*` 子目录，结束时只删除该目录。无需真实视频、云配置或密钥。CI 需要可用的 FFmpeg（含 libx264）。

设置面板的稳定修复入口使用实际 `CloudWallPageHTML.swift` 变体，检查当前活动目录下的 `qr-recovery.html` 链接、新窗口隔离，以及 720p 下的滚动与视频连续播放。剪贴板 API 在独立测试页面内模拟成功、等待、拒绝和缺失状态，验证真实按钮处理与手动选择回退；不会读写用户的系统剪贴板。默认局域网风格变体未定义修复链接，入口保持隐藏。
