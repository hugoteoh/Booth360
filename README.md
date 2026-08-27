# Booth360 — iPhone 360 Video Booth App

一款用于活动现场的 360 旋转拍摄亭（360 Video Booth）iPhone App。功能方向参考市面上的 360 Booth 类产品，但界面与代码完全原创。

- 平台：iOS 17+（iPhone）
- 技术栈：SwiftUI + AVFoundation + SwiftData
- 开发方式：Windows 上用 Claude Code 编写代码 → 拷贝到 Mac → 用 Xcode 编译并安装到真机
- 核心原则：拍摄与剪辑全部离线可用；模块化架构，便于扩展

## 当前进度

| 阶段 | 状态 | 内容 |
|------|------|------|
| Phase 1 | ✅ 已完成 | 项目结构、相机实时预览、1080p 60FPS 录像、保存源视频、手动曝光/对焦/白平衡、倒数拍摄、自动停止 |
| Phase 2 | ✅ 已完成 | 变速（慢/快/慢-快-慢）、倒放、Boomerang、循环、PNG Overlay、背景音乐、四种画幅居中裁切导出（H.264/HEVC）、预览、存相册、分享 |
| Phase 3 | ✅ 已完成 | 活动管理（模板/复制/素材）、嘉宾模式（Welcome→拍摄→处理→成品→QR，PIN 退出）、Gallery（成品/源片、收藏、重剪、重导出）、腾讯云 COS 上传队列（Mock 可切换、断网续传、指数退避、重启恢复）、稳定性监控（存储/电量/过热） |
| Phase 4 | ✅ 已完成 | Motion Trigger（转台起转自动开拍）、Windows 局域网控制（浏览器控制台 :8360）、运营者档案、上架材料（隐私清单/APPSTORE.md） |
| 收尾冲刺 | ✅ 已完成 | Intro/Outro 拼接、动态视频 Overlay、4K + 120/240FPS 开放、上传进度、启动兜底扫描、App 图标 |

> 部署环境：中国。云端一律使用腾讯云（COS 对象存储 + 预签名 URL），模式照搬用户已验证的 AI PhotoBooth Pro 项目，详见 REQUIREMENTS.md 第 7 节。

## 目录结构

```
Booth360/
├── project.yml                 # XcodeGen 项目定义（在 Mac 上生成 .xcodeproj）
├── README.md                   # 本文件
├── REQUIREMENTS.md             # 完整需求清单
├── ARCHITECTURE.md             # 架构设计
├── IMPLEMENTATION_PLAN.md      # 分阶段实施计划
├── Booth360/                   # App 源码
│   ├── App/                    # App 入口与根视图
│   ├── Core/                   # Logger、FileStorageService、SwiftData 模型
│   ├── CameraEngine/           # 相机引擎（会话、格式选择、手动控制、预览）
│   ├── VideoProcessingEngine/  # 处理引擎（时间轴、倒放、合成、裁切、导出）
│   ├── EventManager/           # 活动 CRUD 与素材文件管理
│   ├── UploadQueue/            # 上传队列 + Mock/腾讯云 COS 后端
│   └── Features/
│       ├── Capture/            # 拍摄界面（预览、倒数、手动控制面板、片段列表）
│       ├── Edit/               # 效果编辑与导出（预览、进度、结果播放）
│       ├── Events/             # 活动列表与活动编辑
│       ├── Guest/              # 嘉宾模式（Welcome/流程/PIN）
│       ├── Gallery/            # 成品与源片段浏览、二维码
│       └── Settings/           # 管理员设置（PIN/COS/系统状态）
└── Booth360Tests/              # 单元测试（纯逻辑，不依赖真机相机）
```

## 没有 Mac？（推荐流程）

本项目**不需要拥有 Mac**：GitHub Actions 云端 Mac 自动编译出 ipa，Windows 用 Sideloadly 装进 iPhone（不上 App Store，自用安装）。完整步骤见 [INSTALL_WITHOUT_MAC.md](INSTALL_WITHOUT_MAC.md)。

## 如何在 Mac 上编译运行（备用，如果哪天有 Mac）

### 方式 A：XcodeGen（推荐）

```bash
# 1. 安装 XcodeGen（只需一次）
brew install xcodegen

# 2. 进入项目目录并生成 Xcode 工程
cd Booth360
xcodegen generate

# 3. 打开工程
open Booth360.xcodeproj
```

然后在 Xcode 里：
1. 选中 `Booth360` target → *Signing & Capabilities* → 选择你的 Apple ID / Team。
2. 顶部设备选择你的 iPhone（首次需在 iPhone 上信任开发者证书：设置 → 通用 → VPN 与设备管理）。
3. `Cmd + R` 编译运行。

### 方式 B：手动创建工程（不装 XcodeGen）

1. Xcode → File → New → Project → iOS App，名称 `Booth360`，Interface 选 SwiftUI，最低 iOS 17.0。
2. 删除模板生成的 `ContentView.swift` 和 `Booth360App.swift`。
3. 把本仓库 `Booth360/` 源码文件夹整个拖进工程（勾选 *Copy items if needed* + *Create groups*）。
4. 在 target 的 Info 里添加：
   - `NSCameraUsageDescription`（相机权限说明）
   - `NSMicrophoneUsageDescription`（麦克风权限说明）
   - `UIFileSharingEnabled` = YES、`LSSupportsOpeningDocumentsInPlace` = YES（方便在“文件”App 里看到录好的视频）
5. 新建 Unit Test target `Booth360Tests`，拖入 `Booth360Tests/` 下的测试文件。

> 注意：相机必须用真机测试。模拟器没有摄像头，App 会显示“相机不可用”占位界面（属正常现象）。

## 录好的视频存在哪里

源视频保存在 App 沙盒 `Documents/SourceClips/` 下（`.mov`）。因为开启了文件共享，可直接在 iPhone 的 **文件 App → 我的 iPhone → Booth360** 中查看，也可在 App 内的“片段列表”页播放和删除。

## 运行测试

Xcode 中 `Cmd + U`，或命令行：

```bash
xcodebuild test -project Booth360.xcodeproj -scheme Booth360 -destination 'platform=iOS Simulator,name=iPhone 15'
```

测试全部是纯逻辑测试（格式选择、文件路径、时间格式化），在模拟器上即可运行，不需要相机。
