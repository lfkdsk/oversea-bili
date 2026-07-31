# 海外哔哩 (OverseaBili) — bilibili for Apple TV

面向海外用户的第三方 bilibili tvOS 客户端。核心是**应用内自适应 CDN**:
把 [bili-pilot](https://github.com/siwei-yuan/bili-pilot) 的选路算法移植到原生播放管线,
并参考了 [bilibili-accelerator](https://github.com/realzza/bilibili-accelerator) 的镜像域名池与 PCDN 识别规则。

## 功能

- **扫码登录**:官方 web 二维码接口,Cookie 持久化;登录即将过期时在「我的」提示重新扫码
- **七个 Tab**:推荐 / 热门(综合 + 13 个分区排行榜)/ 直播(关注 + 推荐)/
  发现(每周必看、入站必刷、追番追剧、分区精选)/ 动态(关注 UP 投稿,顶部头像栏可按 UP 过滤)/
  我的(侧栏:观看历史、稍后再看、各收藏夹,含设置入口)/ 搜索
- **详情页**:大封面、UP 主(可进空间)、关注、数据、简介、播放 / 稍后再看 / 点赞 / 投币 / 收藏 / 一键三连、相关推荐
- **UP 空间页**:头像、粉丝数、投稿视频流(无限翻页)
- **播放器**(独立全屏):
  - DASH(fnval=4048)→ sidx 解析 → 本地 HLS 重封装,登录后最高 4K(HEVC 优先,剔除 AV1/杜比)
  - **弹幕**:点播 protobuf 分段解析 + 直播 wss 长连,滚动/顶部/底部三弹道,彩色,可开关
  - **字幕**:player/v2 字幕转 WebVTT 挂为原生字幕轨(登录后可用)
  - 多 P 选集、清晰度切换、倍速(0.5–2×)、重新加载
  - **续播**:服务端进度(跨设备)优先、本地兜底;播放中每 15 秒上报观看历史
  - **自动连播**:播完接下一 P 或相关推荐第一个
  - 暂停/缓冲时右上角显示当前线路与实测网速
  - 下滑信息栏:「线路」CDN 面板(实测速度/固定线路/重新测速)+「高能」弹幕密度曲线
- **番剧/剧集**:追番追剧列表 → 选集页 → 播放
- **直播**:HLS 直连多线路容灾 + 弹幕
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
`-liveRoom <id>`(直达直播间)/ `-initialTab N` / `-showLogin YES` / `-directPlay YES`(绕过智能选路)

## 已知限制

- **Cookie 自动续期未实现**:官方续期流程需要用官方 RSA 公钥生成 CorrespondPath,
  该公钥没有可靠公开来源,不编造密钥。改为检测到即将过期时提示用户重新扫码
- 番剧走 UGC 播放链路(每集 bvid),大会员专享内容可能失败;正规 PGC 链路(ep_id)未接
- HDR / 杜比视界 / 8K:DASH 里有,当前主动剔除(HLS 重封装需正确色彩标注)
- 无损 FLAC 音轨:fMP4-HLS 不支持
- 直播暂无清晰度切换 UI(接口已返回 accept_qn)
- tvOS **模拟器**播 avc1 渐进式 mp4(durl 兜底路径)画面偏绿,是模拟器色度解码怪癖;
  DASH/HLS 主路径与真机均正常

## 说明

仅供个人学习使用。视频与账号数据均来自 bilibili 官方 web 接口(与浏览器同源调用);
CDN 调度只在 B 站授权下发的候选线路之间选择,不绕过任何鉴权。
