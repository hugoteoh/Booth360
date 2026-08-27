# Booth360 架构设计

## 分层总览

```
┌─────────────────────────────────────────────────────┐
│  Features (SwiftUI)                                 │
│  Capture │ Guest Mode │ Gallery │ Events │ Settings │
├─────────────────────────────────────────────────────┤
│  Engines / Services（与 UI 解耦，可单测）             │
│  CameraEngine        VideoProcessingEngine (P2)     │
│  EventManager (P3)   GalleryManager (P3)            │
│  UploadQueue (P3)    MotionTriggerService (P4)      │
├─────────────────────────────────────────────────────┤
│  Core                                               │
│  FileStorageService │ AppLogger │ SwiftData Models  │
└─────────────────────────────────────────────────────┘
```

规则：
1. **UI 不直接碰 AVFoundation**。所有相机/处理调用都经过引擎层。
2. **引擎不 import SwiftUI**。引擎暴露 `@Observable` 状态 + async 方法，UI 只做绑定。
3. **可测试性**：设备相关逻辑（格式选择、参数钳制）抽成纯函数/纯结构体，单测不需要真机。
4. **源素材不可变**：源视频写入 `SourceClips/` 后只读；处理产物写 `Renders/`；失败可无限重试。

## 模块说明

### CameraEngine（Phase 1 已实现）

职责：AVCaptureSession 生命周期、镜头/格式选择、录制、手动控制、中断恢复。

- `CameraEngine`：`@Observable` 门面。持有专用串行队列 `session queue`，所有 AVFoundation 调用都在该队列执行；对外状态在 MainActor 更新。
  - 输入：`CameraConfiguration`（镜头、分辨率、帧率）
  - 输出：`status`（idle/running/recording/失败）、`lastRecordedClip`
  - 录制：`AVCaptureMovieFileOutput`，`maxRecordedDuration` 实现硬性自动停止
  - 旋转：`AVCaptureDevice.RotationCoordinator`（iOS 17 API），预览与录制各自跟随
  - 中断恢复：监听 `AVCaptureSession.wasInterruptedNotification` / `interruptionEndedNotification` / `runtimeErrorNotification`，可恢复时自动 `startRunning`
- `CameraFormatSelector`：**纯逻辑**。输入设备格式的抽象描述（分辨率/最大帧率/是否 binned），输出最佳格式索引；带降级链（60→30fps）。单元测试覆盖。
- `ManualCameraControls`：ISO、快门、对焦、白平衡的钳制与下发；`ControlClamp` 纯函数钳制逻辑可单测。
- `CameraPreviewView`：`UIViewRepresentable` 包装 `AVCaptureVideoPreviewLayer`。

### VideoProcessingEngine（Phase 2 已实现）

职责：源片 → (变速/倒放/Boomerang/循环) → (Overlay/音乐/裁切) → 成品文件。全离线。

- `TimelineBuilder`：**纯逻辑**。把效果参数展开成时间轴片段列表（源范围 → 目标时长）；倒放通过镜像映射到倒序素材坐标。单测覆盖。
- `CropGeometry`：**纯逻辑**。preferredTransform 归一化 + aspect-fill 居中裁切变换。核心不变量：源中心必映射到输出中心。单测覆盖。
- `ClipReverser`：倒放中间文件生成。先 passthrough 收集全部帧 PTS，再按窗口（1080p 30 帧/窗，更高分辨率自动缩小）从尾到头解码、窗内倒序、复用原 PTS 序列写入 HEVC。峰值内存 ≈ 一个窗口的解码帧。产物缓存在 Caches/ReversedClips/（源片不可变 → 缓存永远有效；系统清掉会自动重建）。
- `CompositionBuilder`：AVMutableComposition 装配（逐段 insert + scaleTimeRange）、原声/音乐轨（音乐循环铺满 + 结尾淡出 + AVAudioMix 音量）、AVMutableVideoComposition（renderSize + 30fps + 裁切变换）、Overlay 用 AVVideoCompositionCoreAnimationTool（注意 isGeometryFlipped，且**只能用于导出**，预览路径不带 Overlay）。
- `VideoProcessingEngine`：@MainActor @Observable 门面。进度（倒放阶段占 45% 权重）、取消（CancelFlag + cancelExport）、AVAssetExportSession 导出（HEVC/H.264 preset，.mp4）。
- 原声规则：仅“原速+正放”允许保留原声（变速会变调、倒放无意义），UI 与引擎双重把关。

### Phase 3/4 模块速览

- **EventManager**：活动 CRUD + 素材文件管理（`Documents/Events/<id>/`）；复制活动连素材目录整体拷贝；当前活动 id 存 UserDefaults。
- **UploadQueue**：以 `RenderedVideo.uploadState` 为持久化队列（none/queued/uploading/done/failed）。串行上传、指数退避（5s→300s）、NWPathMonitor 断网暂停/联网续传、启动时把 uploading 回退 queued 恢复。后端可切换：Mock（本地模拟）/ TencentCOSBackend（COS XML API 预签名 PUT/GET，CryptoKit HMAC-SHA1，无第三方 SDK；SecretKey 在 Keychain）。
- **GuestFlowViewModel**：嘉宾流程状态机（welcome→countdown→recording→processing→result→welcome），复用 CameraEngine + VideoProcessingEngine；源片先落盘再处理；结果页自动返回；PIN 退出在视图层。
- **MotionTriggerService**：`SpinDetector` 纯逻辑（持续超阈 + 冷却）+ CMMotionManager 30Hz；仅 welcome 阶段监听（phase didSet 控制）。
- **LANControlServer**：NWListener :8360 + Bonjour `_booth360._tcp`，手写极简 HTTP（请求行解析 `HTTPRequestParser` 可单测），内嵌浏览器控制台页；POST 动作要求管理员 PIN；通过 `RemoteControlHub` 与嘉宾状态机解耦（服务器不直接持有相机/数据库，能力由 RootView 以 Handlers 闭包注入）。
- **SystemStatusMonitor**：存储（<5GB 警告 / <1GB 禁录）、电量（<20%）、热状态（serious+）——拍摄页与嘉宾欢迎页共用。

### FileStorageService（Phase 1 已实现）

- 目录约定：`Documents/SourceClips/`（源片）、`Documents/Renders/`（成品，P2）、`Documents/Events/`（活动素材，P3）
- 文件名：`clip_yyyyMMdd_HHmmss_<uuid8>.mov`，无覆盖风险
- 提供剩余磁盘空间查询（P3 存储告警会用）
- 录制流程：MovieFileOutput 直接写入 `SourceClips/` 最终路径 → 完成后写 SwiftData 记录（`SourceClip`）→ 若录制失败删除半成品文件

### SwiftData 模型

- `SourceClip`（Phase 1）：id、相对文件名、创建时间、时长、宽高、帧率、镜头、是否收藏。存**相对路径**（沙盒绝对路径每次安装会变）。
- 后续：`EventTemplate`、`RenderedVideo`、`UploadTask`（P2/P3 加入，迁移用 SwiftData 默认轻量迁移）。

### AppLogger

`os.Logger` 薄封装，按子系统分类（camera/storage/processing/ui）。现场排障可用 Mac 控制台 App 过滤 subsystem `com.hugoteoh.booth360`。

## 关键设计决策

| 决策 | 理由 |
|------|------|
| Phase 1 用 `AVCaptureMovieFileOutput` 而非 `AVAssetWriter` | 满足 1080p60 + 自动停止；代码量小、稳定。P2 需要更高帧率/自定义写入时再引入 AVAssetWriter，引擎接口不变 |
| 格式选择用 `activeFormat` 而非 `sessionPreset` | preset 无法精确控制帧率；直接选 format 是支持 60/120/240 fps 的唯一正路 |
| 录制直接落盘最终目录，不经过 tmp | 少一次移动；失败时按回调 error 清理 |
| 状态机集中在 `CaptureViewModel` | Start 防重复点击、倒数中可取消、录制中禁止改参数，全部由状态机保证 |
| XcodeGen 生成工程 | Windows 侧无法维护 .xcodeproj 二进制 plist；project.yml 是纯文本，跨平台可维护 |

## 线程模型

- **session queue**（串行）：configure/start/stop/录制/手动控制下发
- **MainActor**：所有 `@Observable` 状态变更、SwiftData 写入
- 回调（`AVCaptureFileOutputRecordingDelegate`）→ 转发到 session queue 清理 → `Task { @MainActor }` 更新状态

## 错误策略

- `CameraError` 枚举：权限被拒、设备不可用、格式不支持、配置失败、录制失败——每个 case 有面向用户的中文描述
- 所有引擎方法 `throws` 或回传 Result；UI 层统一 alert 呈现
- 录制回调中 `AVError.maximumDurationReached` **按成功处理**（这是自动停止的正常路径）
