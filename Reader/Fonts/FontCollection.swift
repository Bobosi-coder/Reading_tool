import Foundation

/// Splits a TrueType/OpenType collection (.ttc/.otc) into standalone font files.
enum FontCollection {
    struct Face {
        let data: Data
        let isCFF: Bool
    }

    enum SplitError: LocalizedError {
        case notACollection, malformed
        var errorDescription: String? { "无法解析这个字体集合文件（.ttc）" }
    }

    static func split(_ ttc: Data) throws -> [Face] {
        let bytes = [UInt8](ttc)
        func u32(_ o: Int) throws -> UInt32 {
            guard o + 4 <= bytes.count else { throw SplitError.malformed }
            return UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        func u16(_ o: Int) throws -> UInt16 {
            guard o + 2 <= bytes.count else { throw SplitError.malformed }
            return UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1])
        }

        guard bytes.count > 12, Array(bytes[0..<4]) == Array("ttcf".utf8) else { throw SplitError.notACollection }
        let numFonts = Int(try u32(8))
        guard numFonts > 0, numFonts < 1000 else { throw SplitError.malformed }

        var faces: [Face] = []
        for f in 0..<numFonts {
            let dir = Int(try u32(12 + 4 * f))
            let sfntVersion = try u32(dir)
            let numTables = Int(try u16(dir + 4))
            guard numTables > 0, numTables < 200 else { throw SplitError.malformed }

            struct Table { let tag: UInt32, checksum: UInt32, offset: Int, length: Int }
            var tables: [Table] = []
            for t in 0..<numTables {
                let r = dir + 12 + 16 * t
                let table = Table(tag: try u32(r), checksum: try u32(r + 4), offset: Int(try u32(r + 8)), length: Int(try u32(r + 12)))
                guard table.offset + table.length <= bytes.count else { throw SplitError.malformed }
                tables.append(table)
            }

            var out = Data()
            func put32(_ v: UInt32) { out.append(contentsOf: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
            func put16(_ v: UInt16) { out.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }

            // Offset table: copy version, numTables, searchRange, entrySelector, rangeShift.
            put32(sfntVersion)
            put16(UInt16(numTables))
            put16(try u16(dir + 6))
            put16(try u16(dir + 8))
            put16(try u16(dir + 10))

            var offset = 12 + 16 * numTables
            for t in tables {
                put32(t.tag)
                put32(t.checksum)
                put32(UInt32(offset))
                put32(UInt32(t.length))
                offset += (t.length + 3) & ~3
            }
            for t in tables {
                out.append(contentsOf: bytes[t.offset ..< t.offset + t.length])
                let pad = ((t.length + 3) & ~3) - t.length
                if pad > 0 { out.append(contentsOf: [UInt8](repeating: 0, count: pad)) }
            }
            faces.append(Face(data: out, isCFF: sfntVersion == 0x4F54_544F)) // 'OTTO'
        }
        return faces
    }
}
