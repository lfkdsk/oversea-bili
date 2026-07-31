import Foundation

struct SidxSegment {
    let start: Int64
    let end: Int64
    let duration: Double
}

/// 解析 fMP4 的 sidx 分段索引(算法移植自 bili-pilot core.js parseSidx)。
/// `absoluteStart` 是传入 buffer 在整个文件里的起始偏移(即 index_range 的起点)。
enum Sidx {
    static func parseRange(_ text: String?) -> (start: Int64, end: Int64)? {
        guard let text else { return nil }
        let parts = text.split(separator: "-")
        guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]),
              start >= 0, end >= start else { return nil }
        return (start, end)
    }

    static func parse(data: Data, absoluteStart: Int64) -> [SidxSegment]? {
        let bytes = [UInt8](data)

        func u32(_ i: Int) -> UInt64? {
            guard i + 4 <= bytes.count else { return nil }
            return (UInt64(bytes[i]) << 24) | (UInt64(bytes[i + 1]) << 16)
                | (UInt64(bytes[i + 2]) << 8) | UInt64(bytes[i + 3])
        }
        func u64(_ i: Int) -> UInt64? {
            guard let high = u32(i), let low = u32(i + 4) else { return nil }
            return (high << 32) | low
        }
        func u16(_ i: Int) -> Int? {
            guard i + 2 <= bytes.count else { return nil }
            return (Int(bytes[i]) << 8) | Int(bytes[i + 1])
        }

        var offset = 0
        while offset + 8 <= bytes.count {
            guard var size = u32(offset).map({ Int($0) }) else { return nil }
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii) ?? ""
            var headerSize = 8
            if size == 1 {
                guard let big = u64(offset + 8), big < Int.max else { return nil }
                size = Int(big)
                headerSize = 16
            } else if size == 0 {
                size = bytes.count - offset
            }
            guard size >= headerSize, offset + size <= bytes.count else { return nil }
            if type != "sidx" {
                offset += size
                continue
            }

            let fullBox = offset + headerSize
            guard fullBox < bytes.count else { return nil }
            let version = bytes[fullBox]
            guard version == 0 || version == 1, let timescale64 = u32(fullBox + 8), timescale64 > 0 else { return nil }
            let timescale = Double(timescale64)

            var cursor = fullBox + 12
            let earliest: UInt64
            let firstOffset: UInt64
            if version == 0 {
                guard let e = u32(cursor), let f = u32(cursor + 4) else { return nil }
                earliest = e; firstOffset = f
                cursor += 8
            } else {
                guard let e = u64(cursor), let f = u64(cursor + 8) else { return nil }
                earliest = e; firstOffset = f
                cursor += 16
            }
            cursor += 2  // reserved
            guard let referenceCount = u16(cursor) else { return nil }
            cursor += 2

            var byteStart = absoluteStart + Int64(offset + size) + Int64(firstOffset)
            var timeStart = Double(earliest) / timescale
            var segments: [SidxSegment] = []
            for _ in 0..<referenceCount {
                guard cursor + 12 <= offset + size,
                      let typeAndSize = u32(cursor),
                      let subDuration = u32(cursor + 4) else { return nil }
                let referenceType = typeAndSize >> 31
                let referencedSize = Int64(typeAndSize & 0x7FFF_FFFF)
                cursor += 12
                guard referenceType == 0, referencedSize > 0, subDuration > 0 else { return nil }
                let duration = Double(subDuration) / timescale
                segments.append(SidxSegment(start: byteStart, end: byteStart + referencedSize - 1, duration: duration))
                byteStart += referencedSize
                timeStart += duration
            }
            return segments.isEmpty ? nil : segments
        }
        return nil
    }
}
