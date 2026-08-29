import Foundation

/// 局域网大屏（Glambot Bigscreen 风格视频墙）。
/// 数据源：/api/renders；视频走 /video/<id> 分块流；二维码 /qr/<id>。
enum WallPageHTML {
    static let html = WallPageTemplate.page(variantJS: """
    const REFRESH_MS = 3000;
    const GEAR_HREF = "/";
    const GALLERY_HREF = "/gallery";
    async function fetchItems() {
      const data = await (await fetch("/api/renders")).json();
      return data.map(item => ({
        id: item.id,
        videoURL: `/video/${item.id}`,
        qrURL: item.uploaded ? `/qr/${item.id}` : null,
        state: item.state
      }));
    }
    """)
}
