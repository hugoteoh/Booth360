import Foundation

/// 云端大屏（发布到 COS，任何网络可开）—— 与局域网大屏同一套 Glambot 风格模板。
/// 数据源：同目录 wall.json（条目均已上传，二维码即刻可见）。
enum CloudWallPageHTML {
    static let html = WallPageTemplate.page(variantJS: """
    const REFRESH_MS = 5000;
    const GEAR_HREF = "";
    const GALLERY_HREF = "./gallery.html";
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
    // 大屏跟随当前活动：每 10 秒查 ../current.json，手机上切了活动这里自动跳转
    (function () {
      const parts = location.pathname.split("/").filter(Boolean);
      const myFolder = parts.length >= 2 ? parts[parts.length - 2] : "";
      if (!myFolder || myFolder === "wall") return; // 根目录跳转壳不参与
      setInterval(async () => {
        try {
          const response = await fetch(`../current.json?ts=${Date.now()}`, { cache: "no-store" });
          const j = await response.json();
          if (j && j.event && j.event !== myFolder) {
            location.replace(`../${j.event}/index.html`);
          }
        } catch (e) {}
      }, 10000);
    })();
    """)
}
