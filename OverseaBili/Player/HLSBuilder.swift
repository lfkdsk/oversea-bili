import Foundation

/// 把 bilibili DASH(fMP4 + sidx)重封装成本地 HLS 播放列表。
/// 所有 URI 指向 LocalStreamServer(http://127.0.0.1:port/...)。
enum HLSBuilder {
    static let masterPath = "/master.m3u8"
    static let videoPlaylistPath = "/video.m3u8"
    static let audioPlaylistPath = "/audio.m3u8"
    static let videoDataPath = "/data-video"
    static let audioDataPath = "/data-audio"
    static let mp4Path = "/video.mp4"

    static func base(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    static func master(base: String, video: DashTrack, audio: DashTrack?) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        var codecs = video.codecs ?? "avc1.640028"
        if let audio {
            lines.append(
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"音轨\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(base)\(audioPlaylistPath)\""
            )
            codecs += ",\(audio.codecs ?? "mp4a.40.2")"
        }
        let bandwidth = (video.bandwidth ?? 1_000_000) + (audio?.bandwidth ?? 0)
        var inf = "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"\(codecs)\""
        if let w = video.width, let h = video.height, w > 0, h > 0 {
            inf += ",RESOLUTION=\(w)x\(h)"
        }
        if let fr = video.frameRate, let value = Double(fr), value > 0 {
            inf += ",FRAME-RATE=\(String(format: "%.3f", value))"
        }
        if audio != nil { inf += ",AUDIO=\"aud\"" }
        lines.append(inf)
        lines.append("\(base)\(videoPlaylistPath)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `initEnd`:init + sidx 的末字节(含),MAP 段覆盖 0...initEnd。
    static func media(base: String, dataPath: String, initEnd: Int64, segments: [SidxSegment]) -> String {
        let target = Int(ceil(segments.map(\.duration).max() ?? 6))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, target))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"\(base)\(dataPath)\",BYTERANGE=\"\(initEnd + 1)@0\"",
        ]
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.end - segment.start + 1)@\(segment.start)")
            lines.append("\(base)\(dataPath)")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
