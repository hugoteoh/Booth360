# Booth360 AI 试点

iPhone 活动里的「嘉宾可生成 AI 版」默认关闭。开启后，原二维码继续打开微信领取页，普通成片独立可保存。客人选定主题并同意云端处理后，每个视频编号只创建一个任务。首位发起者可查看该任务，关闭活动开关后仍能领到已完成的作品。

## 云端运行

在本目录构建镜像，API 和单个队列进程共用同一个持久卷。把 API 接到 https://booth360.yanyanle.com/booth360/ai-api/，反向代理转发时保留完整路径。

    docker build -t booth360-ai .
    docker volume create booth360-ai-data
    docker run -d --name booth360-ai-api --restart unless-stopped --env-file .env -v booth360-ai-data:/data -p 127.0.0.1:8080:8080 booth360-ai
    docker run -d --name booth360-ai-worker --restart unless-stopped --env-file .env -v booth360-ai-data:/data booth360-ai python run_queue.py run

- API 读取 BOOTH360_WX_APP_ID、BOOTH360_WX_APP_SECRET 和 BOOTH360_AI_SESSION_SECRET。会话签名密钥至少 32 字节。
- 两个进程都用 BOOTH360_COS_BUCKET、BOOTH360_COS_REGION、BOOTH360_COS_SECRET_ID、BOOTH360_COS_SECRET_KEY 访问同一个桶。临时凭据加 BOOTH360_COS_TOKEN。
- 队列读取 ARK_API_KEY、TENCENT_TOKENHUB_API_KEY 及 BOOTH360_AI_SHANGHAI_GUIDE_KEY。运镜参考使用获授权的私有 COS 视频，队列按需签发临时链接。固定背景向右移动的原片可配对应参考及 BOOTH360_AI_GUIDE_DIRECTION=right。
- 默认只开放上海滩。其他主题完成实测后，通过 BOOTH360_AI_THEMES=shanghai,elf,disco 开放。每场上限 20 条，同时待处理上限 6 条，可配置 BOOTH360_AI_EVENT_LIMIT 和 BOOTH360_AI_QUEUE_LIMIT。
- 微信公众平台选用适合这个场景的一次性订阅模板。配置 BOOTH360_WX_TEMPLATE_ID，以及匹配该模板字段的 BOOTH360_WX_TEMPLATE_FIELDS JSON 字典。字段值支持 {theme}、{status}、{time}。把 API 域名加入 request 合法域名，并确认实际 COS 下载域名在 downloadFile 列表。联调按版本设 BOOTH360_WX_PROGRAM_STATE=developer 或 trial，正式环境用 formal。

上海试点主机使用 systemd，程序目录为 /opt/booth360-ai-pilot/app，数据目录为 /var/lib/booth360-ai-pilot，配置文件为 /etc/booth360-ai-pilot/service.env。配置文件仅由主机管理员维护，服务名为 booth360-ai-pilot-api 和 booth360-ai-pilot-worker。该主机的 FFmpeg 使用 BOOTH360_AI_H264_ENCODER=libopenh264。

## 验片与交付

    docker exec booth360-ai-worker python run_queue.py review
    docker exec booth360-ai-worker python run_queue.py approve <任务编号>
    docker exec booth360-ai-worker python run_queue.py reject <任务编号>

播放任务目录里的 candidate.mp4，核对同向运镜、首次正面渐变换装、踩原音乐换景、人物和 Logo。查看同目录 review.json 的分析和音轨核验。卡点估计不准时可在 timing.json 标定，再运行 python run_queue.py revise <任务编号>，利用已生成的素材重合成。通过验片并批准后，小程序提供下载，并尝试发送已订阅的微信消息。真机测试时，从通知回到同一视频编号并保存相册。

运行接口、队列和通知状态的离线联调测试。

    python -m unittest discover -s tests -v
