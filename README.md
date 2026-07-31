# 海外哔哩 (OverseaBili) — bilibili for Apple TV

面向海外用户的第三方 bilibili tvOS 客户端。核心是**应用内自适应 CDN**:
把 [bili-pilot](https://github.com/siwei-yuan/bili-pilot) 的选路算法移植到原生播放管线,
并参考了 [bilibili-accelerator](https://github.com/realzza/bilibili-accelerator) 的镜像域名池与 PCDN 识别规则。

## 功能

- **扫码登录**:官方 web 二维码接口,Cookie 持久化;登录解锁高画质、动态、我的、追番等
- **七个 Tab**:推荐 / 热门(综合 + 13 个分区排行榜)/ 动态(关注 UP 投稿)/ 直播(关注 + 推荐)/
  发现(每周必看、入站必刷、追番追剧、分区精选)/ 我的(历史、稍后再看、收藏夹,含设置入口)/ 搜索
- **详情页**(Cheers 式):大封面、UP 主、数据、简介、播放 / 稍后再看 / 点赞 / 投币 / 收藏、相关推荐
- **播放器**(独立全屏):
  - DASH(fnval=4048)→ sidx 解析 → 本地 HLS 重封装,登录后最高 4K(HEVC 优先,剔除 AV1/杜比)
  - **弹幕**:protobuf 分段接口手写解析,滚动/顶部/底部三种弹道,彩色弹幕,可开关
  - 清晰度切换、倍速(0.5–2×,系统原生)、重新加载(转场条菜单)
  - 下滑信息栏:「线路」CDN 面板(实测速度/固定线路/重新测速)+「高能」弹幕密度曲线
- **直播**:HLS 直连播放,多线路顺序容灾
- 非播放页按**播放/暂停键**刷新当前页;深链 `overseabili://play/BVxxx` 打开详情页

## 自适应 CDN 架构(重点)

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
xcodegen generate
xcodebuild -project OverseaBili.xcodeproj -scheme OverseaBili \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)' build
```

真机(先在 Xcode Devices 里配对 Apple TV):

```bash
xcodebuild -project OverseaBili.xcodeproj -scheme OverseaBili \
  -destination 'platform=tvOS,name=客厅' -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> \
  build/DerivedData/Build/Products/Debug-appletvos/OverseaBili.app
```

调试启动参数:`-playBvid BVxxx`(直达播放器)/ `-detailBvid BVxxx`(直达详情页)/
`-showLogin YES` / `-directPlay YES`(绕过智能选路直连)

## 已知问题

- tvOS **模拟器**播 avc1 渐进式 mp4(durl 兜底路径)画面偏绿(模拟器色度解码怪癖);
  DASH/HLS 主路径(HEVC)颜色正常,真机两条路径都正常
- 番剧/剧集播放借道普通 UGC 管线(取每季第一集 bvid),大会员专享内容可能失败
- 直播暂无弹幕(需要 websocket 协议,后续版本)

## 说明

仅供个人学习使用。视频与账号数据均来自 bilibili 官方接口;CDN 调度只在
授权候选线路间选择,不绕过鉴权。
