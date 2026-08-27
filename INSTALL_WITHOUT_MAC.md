# 不用 Mac：Windows 开发 → iPhone 安装 完整指南

> 适用场景：App 只装到自己/团队的 iPhone 上用，**不上 App Store**。
> 原理：iOS App 必须由 macOS 上的 Xcode 编译（苹果硬性限制），但我们让 **GitHub 免费的云端 Mac** 干这件事；
> Windows 只负责写代码和安装。全程不需要拥有任何 Mac。

## 流程总览

```
Windows（写代码，Claude Code）
   │  git push
   ▼
GitHub Actions（免费云端 Mac，自动编译 ≈ 5–10 分钟）
   │  产出 Booth360-unsigned.ipa
   ▼
Windows 下载 ipa → Sideloadly（免费工具）签名
   │  USB 数据线
   ▼
你的 iPhone（iOS 17+）
```

## 一次性准备（约 20 分钟）

### 1. 电脑端装两个软件

| 软件 | 下载 | 作用 |
|------|------|------|
| iTunes（苹果官网版，不要微软商店版） | https://www.apple.com/itunes/download/win64 | 提供 iPhone 的 USB 驱动 |
| Sideloadly | https://sideloadly.io | 把 ipa 签名并装进 iPhone |

装完 iTunes 后用 USB 线连一次 iPhone，手机上点「信任此电脑」。

### 2. Apple ID

- **免费 Apple ID 即可**（就是你 iPhone 上登录的那个，或者随便注册一个）。
- 免费账号限制：签名 **7 天有效**（到期后重新用 Sideloadly 装一次即可，2 分钟），同时最多 3 个自签 App。
- 如果这是拿去活动现场商用的机器，强烈建议花 **$99/年买 Apple Developer Program**：同样用 Sideloadly 安装，但签名 **1 年有效**，还能装到最多 100 台设备。依然不需要 Mac。

### 3. GitHub 仓库

已经建好：私有仓库 `hugoteoh/Booth360`，每次 push 自动触发云端编译。

## 每次安装 / 更新 App 的步骤

1. **拿到 ipa**（三选一，推荐前两种）：
   - **一键脚本**：双击运行项目里的 `scripts\update-app.ps1`，最新 ipa 自动下载到 `ipa\` 文件夹；
   - **Releases 页**：打开 https://github.com/hugoteoh/Booth360/releases → "Booth360 最新构建" → 下载 `Booth360-unsigned.ipa`（每次云端编译成功都会自动更新这里）；
   - 备用：仓库页 → **Actions** → 最新一次 "iOS Build" → 底部 **Artifacts** 下载（zip 需解压）。
2. **打开 Sideloadly**，USB 连接 iPhone：
   - 左上角设备栏应显示你的 iPhone（不显示 = iTunes 驱动没装好）。
   - 把 `.ipa` 文件拖进 Sideloadly 窗口。
   - Apple account 栏输入你的 Apple ID → 点 **Start** → 弹窗输密码（有两步验证会让你输验证码）。
   - 等 1–2 分钟显示 Done。
3. **iPhone 上首次信任**（只需一次）：
   - 设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任你的 Apple ID。
   - 设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启手机 →确认开启。
     （看不到"开发者模式"入口？先做完第 2 步安装，再回来看就有了。）
4. 桌面上出现 Booth360，打开即用 🎉

之后每次我改完代码 push，你只要重复第 1、2 步（信任和开发者模式不用再做）。

## 免费账号的 7 天续签

- 到期表现：图标还在，点开闪退。
- 解决：USB 连电脑，Sideloadly 重装一遍（数据不丢，活动/素材/视频都保留）。
- 嫌麻烦可以装 **AltServer**（Windows 版）：手机和电脑同一 Wi-Fi 时自动帮你续签，适合长期使用；或者直接上 $99 账号一年免操心。

## 常见问题

| 现象 | 解决 |
|------|------|
| GitHub Actions 编译红叉 | 点进去看日志，把报错整段发给 Claude 修（我们没有 Mac，云端日志就是我们的编译器输出） |
| Sideloadly 看不到设备 | 装苹果官网版 iTunes；换原装数据线；手机上重新点信任 |
| 安装时报 `Provisioning` 错误 | Apple ID 在 https://appleid.apple.com 生成 App 专用密码再登录；或换个网络（个别宽带连苹果签名服务器不稳） |
| 打开 App 提示"不受信任的开发者" | 上面第 3 步的信任没做 |
| 7 天后闪退 | 正常现象（免费账号），重新 Sideloadly 装一次 |
| Actions 页面打不开 / 下载慢 | 国内网络问题，换时段或挂加速器；只影响下载 ipa，不影响 App 使用（App 本身完全离线） |

## 为什么不能直接在 Windows 编译？

苹果只把 iOS SDK（SwiftUI/AVFoundation 这些框架）随 macOS 版 Xcode 发布，且授权条款限定只能在 Apple 硬件上编译。所以"云端 Mac 代劳 + Windows 安装"是不买 Mac 的唯一正路。我们用的 GitHub Actions 免费额度（私有仓库每月 2000 分钟 ≈ 200 分钟 Mac 时长，一次编译约 8 分钟，够每月二十多次构建；公开仓库完全免费无限制）。
