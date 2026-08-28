import Foundation

/// 云端大屏（发布到 COS，任何网络可开）—— 与局域网大屏同一套 Glambot 风格模板。
/// 数据源：同目录 wall.json（条目均已上传，二维码即刻可见）。
enum CloudWallPageHTML {
    static let html = WallPageTemplate.page(variantJS: """
    const REFRESH_MS = 5000;
    const GEAR_HREF = "";
    async function fetchItems() {
      const response = await fetch(`./wall.json?ts=${Date.now()}`, { cache: "no-store" });
      const manifest = await response.json();
      return (manifest.items || []).map(item => ({
        id: item.id,
        videoURL: item.url,
        qrURL: item.qr,
        state: ""
      }));
    }
    """)
}
