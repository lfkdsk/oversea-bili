# 海外哔哩 (OverseaBili) — bilibili for Apple TV

面向海外用户的第三方 bilibili tvOS 客户端。核心是**应用内自适应 CDN**:
把 [bili-pilot](https://github.com/siwei-yuan/bili-pilot) 的选路算法移植到原生播放管线,
并参考了 [bilibili-accelerator](https://github.com/realzza/bilibili-accelerator) 的镜像域名池与 PCDN 识别规则。

## 功能

- **扫码登录**:官方 web 二维码接口,Cookie 持久化;登录即将过期时在「我的」提示重新扫码
- **七个 Tab**:推荐 / 热门(综合 + 13 个分区排行榜)/ 直播(关注 + 推荐 + 分区浏览)/
  发现(番剧与国创时间表、今日更新、每周必看、入站必刷、追番追剧、分区精选)/ 动态(关注 UP 投稿,顶部头像栏可按 UP 过滤)/
  我的(侧栏:观看历史、稍后再看、追番追剧、各收藏夹,含设置入口)/
  搜索(热搜词、输入建议、搜索历史、视频/番剧/影视/UP 主分类,无限翻页)
- **详情页**:大封面、UP 主(可进空间)、关注、数据、简介、播放(显示续播位置)/ 稍后再看 / 点赞 / 投币 / 收藏 / 一键三连、选集、合集清单、相关推荐、评论区
- **UP 空间页**:头像、粉丝与投稿数、签名、关注、合集与系列、投稿视频流(无限翻页)
- **播放清单**:UGC 合集(分节)、UP 主合集与系列、收藏夹、稍后再看"连续播放全部";统一走 medialist 接口游标翻页,从清单进入任意一条,播完按清单连播
- **评论区**:详情页与播放器面板两处入口;热门 / 最新、游标翻页;楼中楼;UP 置顶与标识、等级、点赞、IP 属地;表情图片、评论配图看大图
- **播放器**(独立全屏):
  - DASH(fnval=4048)→ sidx 解析 → 本地 HLS 重封装,登录后最高 **8K / 4K / HDR**
    (HEVC 优先,HDR 轨声明 `VIDEO-RANGE=PQ`;剔除 AV1 与杜比视界——tvOS 不支持这两种容器组合)
  - 音轨:AAC 优先,杜比数字+(EC-3)可用;无损 FLAC 在 fMP4-HLS 下不受支持,自动跳过
  - **弹幕**:点播 protobuf 分段解析 + 直播 wss 长连,滚动/顶部/底部三弹道,彩色,可开关
  - **字幕**:player/v2 字幕转 WebVTT 挂为原生字幕轨(登录后可用)
  - 多 P 选集、清晰度切换、倍速(0.5–2×)、重新加载
  - **续播**:服务端进度(跨设备)优先、本地兜底;播放中每 15 秒上报观看历史
  - **自动连播**:5 秒倒计时后接下一个(下一 P → 清单下一条 → 番剧下一集 → 相关推荐),可取消、可关闭
  - 编码偏好(自动 / HEVC / AVC),当前编码播放失败时自动退回 AVC 重试一次;HDR、杜比音效开关
  - 暂停/缓冲时右上角显示当前线路与实测网速
  - 下滑信息栏面板:「合集·清单」、「评论」、「线路」(实测速度/固定线路/重新测速)、
    「质量」(平均吞吐、峰值、前方缓存、丢帧、卡顿次数、分块重试/失败、线路切换轨迹)、「高能」(弹幕密度曲线)
  - **弹幕防挡**:显示区域(1/4~全屏)、不透明度、字号、滚动速度、同屏条数上限、云屏蔽等级、屏蔽词
- **番剧/剧集**:追番追剧、时间表 → 选集页 → 官方 PGC 播放链路(ep_id);官方接口提示地区限制时经解析服务器取地址(见下)
- **番剧解析**:设置里单独扫码授权后,地区受限的番剧改经 BiliRoaming 兼容的解析服务器播放(大陆 → 港澳 → 台湾依次尝试),番剧 / 影视搜索也合并它的结果。解析服务器只收到 access_key,不会收到网页登录 Cookie;默认服务器可在设置里换
- **直播**:HLS 直连多线路容灾 + 弹幕 + 清晰度切换(杜比/4K/2K/原画/蓝光/超清/高清/流畅)
- 非播放页按**播放/暂停键**刷新当前页;深链 `overseabili://play/BVxxx`

## 自适应 CDN 架构

```
playurl(DASH) → 候选线路(API 主备 + 8 个海外镜像,须 206 探测通过)
     ↓ sidx 解析分段
本地 HLS 播放列表(127.0.0.1 随机端口)← AVPlayer 标准 HTTP 拉流
     ↓ /data-video /data-audio
ChunkEngine:2MB 分块,每块走当前最优线路;失败指数冷却(15s→120s)换路;
            24MB 预取窗口;测速评分 minMbps*0.72+harmonic*0.28-失败×80-TTFB/500;
            PCDN/MCDN(mcdn 域名、IP 直连、非 443 端口等)降权兜底;
            卡顿→恢复性测速(10s→5min 退避);缓冲充足时每 5min 例行复测
            测速成绩按出口地区持久化(6h TTL),下次起播直接按历史排序省掉冷启动探测
```

关键教训:HLS 的媒体分段 **必须是 http(s) URL**,`AVAssetResourceLoader` 自定义协议
只对播放列表生效,分段请求不会回调 loader(报 `CoreMediaErrorDomain -12881`)——
所以数据面用本地回环 HTTP 服务器(Network.framework),而非 ResourceLoader。

## 构建运行

依赖:Xcode(含 tvOS 平台)、[xcodegen](https://github.com/yonaskolb/XcodeGen)

```bash
./scripts/deploy.sh sim         # 模拟器
./scripts/deploy.sh device      # 已配对的 Apple TV
./scripts/deploy.sh testflight  # 归档并上传 App Store Connect
```

调试启动参数:`-playBvid BVxxx`(直达播放器)/ `-detailBvid BVxxx`(直达详情页)/
`-liveRoom <id>`(直达直播间)/ `-seasonId <id>`(直达选集页)/ `-upMid <mid>`(直达 UP 空间)/
`-timeline <1|4>`(直达时间表)/ `-initialTab N` / `-showLogin YES` / `-showRoamLogin YES`(解析服务器授权)/
`-directPlay YES`(绕过智能选路)

## 已知限制

- **Cookie 自动续期未实现**:官方续期流程需要用官方 RSA 公钥生成 CorrespondPath,
  该公钥没有可靠公开来源,不编造密钥。改为检测到即将过期时提示用户重新扫码
- **番剧跨区依赖第三方解析服务器**:海外 PGC playurl 返回 `-10403`,是 B 站按请求 IP 判定的版权地区,
  CDN 优选解决不了(地区判定发生在拿地址之前)。解析服务器是公共服务,可用性不受本项目控制;没有授权或服务器不可用时只提示原因
- 杜比视界(dvh1)剔除:tvOS 对该容器组合要求不同,暂不支持
- 无损 FLAC 音轨:fMP4-HLS 不支持,自动降级 AAC
- tvOS **模拟器**播 avc1 渐进式 mp4(durl 兜底路径)画面偏绿,是模拟器色度解码怪癖;
  DASH/HLS 主路径与真机均正常

## 说明

仅供个人学习使用。视频与账号数据均来自 bilibili 官方 web 接口(与浏览器同源调用);
CDN 调度只在 B 站授权下发的候选线路之间选择,不绕过任何鉴权。
