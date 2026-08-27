# Booth360 需求清单

> 本文档是全量需求，按功能域整理。各阶段实施范围见 IMPLEMENTATION_PLAN.md。

## 0. 总体约束

- iOS 17+，iPhone，SwiftUI + AVFoundation + SwiftData
- 所有基础拍摄和剪辑必须离线运行（无网络也能完整走完 拍摄→处理→保存 流程）
- 模块化架构，各引擎可独立测试与替换
- 代码必须能在 Xcode 真机项目中直接编译，不允许伪代码

## 1. 活动管理（Event Management）

- [ ] 创建、编辑、复制、删除活动
- [ ] 活动配置项：名称、Logo、背景、背景音乐、Overlay、拍摄参数、输出参数
- [ ] 活动模板：保存/套用不同活动模板
- [ ] 活动数据用 SwiftData 持久化

## 2. 相机拍摄（Capture）

- [x] 实时预览（AVCaptureVideoPreviewLayer）
- [x] 镜头选择：广角（Wide）/ 超广角（Ultra Wide）
- [x] 分辨率：1080p、4K（收尾冲刺开放）
- [x] 帧率：30 / 60 / 120 / 240（UI 全开放，设备不支持时自动降级并提示）
- [x] 倒数拍摄（可配置秒数）
- [x] 自动停止录像（可配置录制时长，用 `maxRecordedDuration` 硬性保证）
- [x] 手动锁定：ISO、快门（曝光时长）、对焦（镜头位置）、白平衡（色温/色调）
- [x] 曝光偏移（EV bias，自动曝光模式下）
- [x] 横屏、竖屏拍摄（RotationCoordinator 自动跟随设备方向）
- [x] 录音（源视频带现场声音，成品阶段可开关）

## 3. 360 视频效果（Processing）

- [x] Slow Motion / Fast Motion / Slow–Fast–Slow（变速曲线，Phase 2）
- [x] Reverse（倒放，分窗口重编码 + 缓存，Phase 2）
- [x] Boomerang（正放+倒放，Phase 2）
- [x] 视频循环次数（×1–3，Phase 2）
- [x] Intro / Outro 片段拼接（收尾冲刺；保留片头片尾自带声音，几何各自适配）
- [x] 静态 PNG Overlay（含透明通道，Phase 2）
- [x] 动态 Overlay（带透明通道的 HEVC 视频，第二视频轨叠加，预览/导出都生效；收尾冲刺）
- [x] 背景音乐（音量 + 结尾淡出 + 不足自动循环，Phase 2）
- [x] 原视频声音开关（仅“原速+正放”可用，变速/倒放自动关闭）
- [x] 全部基于 AVFoundation（AVMutableComposition + AVVideoComposition），离线处理

## 4. 输出设置（Export)

- [x] 画幅：9:16、16:9、1:1、4:5（居中裁切，Phase 2）
- [x] 分辨率：720p、1080p、4K（全开放；4K 输出建议配 4K 源片）
- [x] 编码：H.264、HEVC（Phase 2）
- [x] 保存到系统相册（Phase 2）
- [x] 系统分享（ShareLink，Phase 2）

## 5. 嘉宾模式（Guest Mode）

- [x] Welcome 页面（活动 Logo/背景/文案，Phase 3）
- [x] Start 按钮 → 倒数 → 录像 → 处理进度 → 成品预览（Phase 3）
- [x] 重拍、成品页二维码（Phase 3）
- [x] 超时自动返回首页（时长每活动可配，Phase 3）
- [x] 管理员 PIN 退出（隐藏角长按 2 秒，Phase 3）
- [x] 防误触（全屏、隐藏系统条；配合 Guided Access，Phase 3）

## 6. Gallery

- [x] 查看所有源视频与成品（缩略图，Phase 3）
- [x] 重剪 / 重新导出（跳回编辑页，Phase 3）
- [x] 删除、收藏（Phase 3）
- [x] 显示上传状态（实时，Phase 3）

## 7. QR 下载（中国部署 → 腾讯云 COS）

App 在中国现场使用，云端必须用腾讯云，照搬用户 AI PhotoBooth Pro 的已验证模式：

- [ ] 上传成品到腾讯云 COS（参考桶区域 ap-shanghai，对象键 `booth360/<session_id>/<file>.mp4`）
- [ ] 下载链接用 COS 预签名 GET URL（约 7 天有效期），二维码直接编码该 URL
- [ ] `UploadBackend` 协议：`MockBackend`（本地模拟，先行开发）+ `TencentCOSBackend`（URLSession PUT + 本地计算 COS 签名，不引第三方 SDK）
- [ ] COS SecretId/SecretKey/Bucket/Region 由管理员在设置页配置，存 Keychain，绝不硬编码
- [ ] 离线时进入上传队列，联网自动续传；本地记录每条成品的 upload_status
- [ ] 不使用任何在中国不可用的服务（Firebase/GCS/AWS 等）

## 8. 现场稳定性

- [ ] 防重复点击 Start（状态机保证）
- [ ] 存储不足提醒（阈值检测）
- [ ] 低电量提醒
- [ ] 过热提醒（thermal state 监控）
- [ ] 相机被中断（来电/多任务）后自动恢复
- [ ] App 重开后恢复未完成任务
- [ ] 上传失败自动重试（指数退避）
- [ ] 断网可拍摄剪辑
- [x] 源视频永远保留（处理失败不丢素材：源片先落盘、处理产物另存）

## 9. Phase 4

- [x] Motion Trigger（角速度持续超阈自动开拍，冷却防连触；每活动开关）
- [x] Windows 局域网控制（手机内建 HTTP 服务器 :8360 + Bonjour；电脑浏览器控制台：状态/切活动/远程开拍，POST 需 PIN）
- [x] 账号系统（本地运营者档案：名称上欢迎页、联系方式备查；多设备云账号需后端，留待后续版本）
- [x] App Store 上架准备（PrivacyInfo.xcprivacy、本地网络权限文案、APPSTORE.md 清单与审核备注）

> 标 [x] 的条目为 Phase 1 已实现；其余按阶段推进。
