# Booth360 实施计划

## Phase 1 — 相机基础（✅ 本次交付）

| # | 任务 | 状态 |
|---|------|------|
| 1.1 | 项目结构 + XcodeGen project.yml + 四份文档 | ✅ |
| 1.2 | AppLogger、FileStorageService、SwiftData `SourceClip` | ✅ |
| 1.3 | CameraEngine：会话、权限、镜头选择（广角/超广角）、格式选择（1080p 30/60） | ✅ |
| 1.4 | 实时预览（含旋转跟随） | ✅ |
| 1.5 | 录像：1080p60、录音、自动停止（3–60 秒可调）、保存到 SourceClips | ✅ |
| 1.6 | 手动控制：ISO、快门、EV、对焦、白平衡（锁定/回自动） | ✅ |
| 1.7 | 倒数页面（3/5/10 秒可调，可取消） | ✅ |
| 1.8 | 片段列表：播放、删除（验证保存结果用，非正式 Gallery） | ✅ |
| 1.9 | 中断恢复（来电/后台）+ 防重复点击状态机 | ✅ |
| 1.10 | 单元测试：格式选择、参数钳制、文件命名/路径 | ✅ |

**Phase 1 验收**：真机上能预览 → 按倒数 → 自动录满设定秒数停止 → 在片段列表和“文件”App 里看到 1080p60 的 .mov。

## Phase 2 — 处理与导出（✅ 已交付）

| # | 任务 | 状态 |
|---|------|------|
| 2.1 | VideoProcessingEngine：合成管线、进度回调、取消 | ✅ |
| 2.2 | 变速：Slow / Fast / Slow–Fast–Slow（scaleTimeRange 分段） | ✅ |
| 2.3 | Reverse（分窗口倒序重编码，Caches 缓存复用） | ✅ |
| 2.4 | Boomerang、循环次数 ×1–3 | ✅ |
| 2.5 | 静态 PNG Overlay（CoreAnimationTool 合成，仅导出路径） | ✅ |
| 2.6 | 背景音乐（循环铺满+淡出+音量）+ 原声开关 | ✅ |
| 2.7 | 导出：9:16/16:9/1:1/4:5 居中裁切，720p/1080p，H.264/HEVC，30fps | ✅ |
| 2.8 | 处理进度 UI + 取消 + 效果预览（无 Overlay）+ 存相册 + 分享 | ✅ |
| 2.9 | 单测：时间轴计算、裁切几何、输出尺寸 | ✅ |

**Phase 2 验收**：片段列表点一条 → 选“慢-快-慢 + Boomerang + 音乐 + Overlay”→ 导出 → 成品在结果页循环播放，可分享/存相册；Renders 目录与 RenderedVideo 表有记录。

## Phase 3 — 活动/嘉宾/Gallery/上传

✅ 已交付：
3.1 EventManager + SwiftData 模板 ✅ → 3.2 活动编辑 UI（Logo/背景/音乐/Overlay 导入）✅ → 3.3 Guest Mode 全流程 + 隐藏角长按 + PIN ✅ → 3.4 Gallery（成品/源片、播放、收藏、删除、重剪重导出、上传状态）✅ → 3.5 QR + UploadQueue：**腾讯云 COS**（COS XML API 预签名 PUT/GET、URLSession 无 SDK、Keychain 存 SecretKey；Mock 后端可切换；断网 NWPathMonitor 自动续传；指数退避 5s→300s；App 重启恢复队列）✅ → 3.6 稳定性（存储 <5GB 提醒 / <1GB 禁录、低电量、过热提醒；防重复 Start；源片先落盘）✅

**Phase 3 验收**：建活动配好素材 → 活动列表点▶进嘉宾模式 → 嘉宾完整走一轮拿到二维码 → 长按左上角 2 秒输 PIN 退出 → Gallery 里能看到源片和成品及上传状态。

## Phase 4 — 进阶（✅ 已交付）

4.1 Motion Trigger ✅（SpinDetector 纯逻辑：角速度模长持续 0.5s 超 1.2rad/s 触发、8s 冷却；CMMotionManager 30Hz；每活动开关，仅 welcome 页监听）
4.2 Windows 局域网控制 ✅（内建 HTTP 服务器 NWListener :8360 + Bonjour `_booth360._tcp`；浏览器控制台页内嵌，无需装软件；GET /api/status、/api/events，POST 带 PIN：activate/open/start；RemoteControlHub 桥接嘉宾状态机）
4.3 账号系统 ✅（本地运营者档案 AccountStore；云端多设备账号需后端，规划后续）
4.4 上架准备 ✅（PrivacyInfo.xcprivacy、NSLocalNetworkUsageDescription/NSBonjourServices、APPSTORE.md：材料清单/审核备注/中国区注意事项/压测清单）

**Phase 4 验收**：活动开启"转台起转自动开拍"→ 嘉宾模式下晃动旋转手机自动开始倒数；设置开"局域网控制"→ Windows 浏览器打开显示的地址 → 看状态、切活动、远程开始拍摄。

## 收尾冲刺（✅ 已交付）

| # | 内容 |
|---|------|
| 5.1 | Intro/Outro 拼接：活动可配片头/片尾视频，保留其自带声音，几何各自适配（分段变换关键帧） |
| 5.2 | 动态视频 Overlay：透明 HEVC .mov 第二视频轨叠加、循环铺满，预览与导出都生效（活动 + 管理员编辑页都支持） |
| 5.3 | 4K 拍摄 + 120/240 FPS UI 开放（自动降级链已有）；导出 4K 开放 |
| 5.4 | 上传进度百分比（URLSession per-task delegate；Mock 也模拟进度），Gallery 与嘉宾成品页显示 |
| 5.5 | 启动兜底扫描 LibraryReconciler：文件在、记录丢 → 自动补录源片/成品 |
| 5.6 | App 图标（1024 生成 + Asset Catalog + 工程接线），EffectSettings 向后兼容解码（旧 JSON 不丢配置） |
| 5.7 | 审计修复：嘉宾退出后不再后台空转处理、活动 ID 读取并发隔离等 |

## 每阶段交付物

每个阶段完成时提供：完成了什么 / 新增文件清单 / 如何运行 / 如何测试 / 当前限制。
