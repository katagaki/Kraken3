import Foundation

#if canImport(CJPEG)
import CJPEG

// libjpeg-turbo via the CJPEG shim; an order of magnitude faster than the
// pure-Swift encoder below, which remains for platforms without libjpeg.
enum JPEGEncoder {

    static func encode(width: Int, height: Int, rgba: [UInt8], quality: Int) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var size = 0
        let buffer = rgba.withUnsafeBufferPointer {
            kraken_jpeg_encode($0.baseAddress, Int32(width), Int32(height),
                               Int32(max(1, min(quality, 100))), &size)
        }
        guard let buffer, size > 0 else {
            if let buffer { kraken_jpeg_free(buffer) }
            return nil
        }
        return Data(bytesNoCopy: buffer, count: size,
                    deallocator: .custom { pointer, _ in
                        kraken_jpeg_free(pointer.assumingMemoryBound(to: UInt8.self))
                    })
    }
}
#else
// Baseline sequential JPEG (4:4:4, standard Annex K tables). Exists so full
// frames can be produced from screencast pixels without Page.captureScreenshot,
// which perturbs the compositor and causes visible relayout flashes.
enum JPEGEncoder {

    private static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
    ]

    private static let lumaQuant: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99
    ]

    private static let chromaQuant: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99
    ]

    private static let dcLumaBits: [Int] = [0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    private static let dcLumaVals: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    private static let dcChromaBits: [Int] = [0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
    private static let dcChromaVals: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

    private static let acLumaBits: [Int] = [0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
    private static let acLumaVals: [Int] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
        0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
        0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
        0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
        0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
        0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
        0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
        0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
        0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
        0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA
    ]

    private static let acChromaBits: [Int] = [0, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
    private static let acChromaVals: [Int] = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41,
        0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
        0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1,
        0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44,
        0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74,
        0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A,
        0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
        0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7,
        0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4,
        0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA
    ]

    private struct HuffTable {
        var codes = [UInt32](repeating: 0, count: 256)
        var sizes = [Int](repeating: 0, count: 256)

        init(bits: [Int], values: [Int]) {
            var code: UInt32 = 0
            var index = 0
            for length in 1...16 {
                for _ in 0..<bits[length] {
                    codes[values[index]] = code
                    sizes[values[index]] = length
                    code += 1
                    index += 1
                }
                code <<= 1
            }
        }
    }

    private struct BitWriter {
        var data = Data()
        var buffer: UInt32 = 0
        var count = 0

        mutating func put(_ code: UInt32, _ size: Int) {
            buffer = (buffer << UInt32(size)) | (code & ((1 << UInt32(size)) - 1))
            count += size
            while count >= 8 {
                let byte = UInt8((buffer >> UInt32(count - 8)) & 0xFF)
                data.append(byte)
                if byte == 0xFF { data.append(0) }
                count -= 8
            }
        }

        mutating func flush() {
            if count > 0 {
                let pad = 8 - count
                put((1 << UInt32(pad)) - 1, pad)
            }
        }
    }

    static func encode(width: Int, height: Int, rgba: [UInt8], quality: Int) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }

        let q = max(1, min(quality, 100))
        let scale = q < 50 ? 5000 / q : 200 - 2 * q
        func scaled(_ table: [Int]) -> [Int] {
            table.map { max(1, min(255, ($0 * scale + 50) / 100)) }
        }
        let quantY = scaled(lumaQuant)
        let quantC = scaled(chromaQuant)

        var jpeg = Data([0xFF, 0xD8])

        jpeg.append(contentsOf: [0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00,
                                 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])

        for (id, table) in [(0, quantY), (1, quantC)] {
            jpeg.append(contentsOf: [0xFF, 0xDB, 0x00, 0x43, UInt8(id)])
            for i in 0..<64 { jpeg.append(UInt8(table[zigzag[i]])) }
        }

        jpeg.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11, 0x08,
                                 UInt8(height >> 8), UInt8(height & 0xFF),
                                 UInt8(width >> 8), UInt8(width & 0xFF), 0x03,
                                 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01])

        for (klass, id, bits, values) in [(0, 0, dcLumaBits, dcLumaVals),
                                          (1, 0, acLumaBits, acLumaVals),
                                          (0, 1, dcChromaBits, dcChromaVals),
                                          (1, 1, acChromaBits, acChromaVals)] {
            let length = 3 + 16 + values.count
            jpeg.append(contentsOf: [0xFF, 0xC4, UInt8(length >> 8), UInt8(length & 0xFF),
                                     UInt8(klass << 4 | id)])
            for i in 1...16 { jpeg.append(UInt8(bits[i])) }
            for value in values { jpeg.append(UInt8(value)) }
        }

        jpeg.append(contentsOf: [0xFF, 0xDA, 0x00, 0x0C, 0x03,
                                 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00])

        let dcY = HuffTable(bits: dcLumaBits, values: dcLumaVals)
        let acY = HuffTable(bits: acLumaBits, values: acLumaVals)
        let dcC = HuffTable(bits: dcChromaBits, values: dcChromaVals)
        let acC = HuffTable(bits: acChromaBits, values: acChromaVals)

        var writer = BitWriter()
        var predY = 0, predCb = 0, predCr = 0
        var blockY = [Float](repeating: 0, count: 64)
        var blockCb = [Float](repeating: 0, count: 64)
        var blockCr = [Float](repeating: 0, count: 64)

        let blocksX = (width + 7) / 8
        let blocksY = (height + 7) / 8

        rgba.withUnsafeBufferPointer { pixels in
            for by in 0..<blocksY {
                for bx in 0..<blocksX {
                    for row in 0..<8 {
                        let sy = min(by * 8 + row, height - 1)
                        for col in 0..<8 {
                            let sx = min(bx * 8 + col, width - 1)
                            let p = (sy * width + sx) * 4
                            let r = Float(pixels[p])
                            let g = Float(pixels[p + 1])
                            let b = Float(pixels[p + 2])
                            let i = row * 8 + col
                            blockY[i] = 0.299 * r + 0.587 * g + 0.114 * b - 128
                            blockCb[i] = -0.168736 * r - 0.331264 * g + 0.5 * b
                            blockCr[i] = 0.5 * r - 0.418688 * g - 0.081312 * b
                        }
                    }
                    predY = encodeBlock(&writer, &blockY, quantY, dcY, acY, predY)
                    predCb = encodeBlock(&writer, &blockCb, quantC, dcC, acC, predCb)
                    predCr = encodeBlock(&writer, &blockCr, quantC, dcC, acC, predCr)
                }
            }
        }
        writer.flush()

        jpeg.append(writer.data)
        jpeg.append(contentsOf: [0xFF, 0xD9])
        return jpeg
    }

    private static func encodeBlock(_ writer: inout BitWriter, _ block: inout [Float],
                                    _ quant: [Int], _ dc: HuffTable, _ ac: HuffTable,
                                    _ predictor: Int) -> Int {
        forwardDCT(&block)

        var coefficients = [Int](repeating: 0, count: 64)
        for i in 0..<64 {
            let value = block[zigzag[i]] / Float(quant[zigzag[i]])
            coefficients[i] = Int(value.rounded())
        }

        let dcValue = coefficients[0]
        let diff = dcValue - predictor
        let dcSize = magnitudeSize(diff)
        writer.put(dc.codes[dcSize], dc.sizes[dcSize])
        if dcSize > 0 { writer.put(magnitudeBits(diff, dcSize), dcSize) }

        var run = 0
        var lastNonZero = 0
        for i in stride(from: 63, through: 1, by: -1) where coefficients[i] != 0 {
            lastNonZero = i
            break
        }
        for i in 1...63 {
            if i > lastNonZero { break }
            let value = coefficients[i]
            if value == 0 {
                run += 1
                continue
            }
            while run >= 16 {
                writer.put(ac.codes[0xF0], ac.sizes[0xF0])
                run -= 16
            }
            let size = magnitudeSize(value)
            let symbol = run << 4 | size
            writer.put(ac.codes[symbol], ac.sizes[symbol])
            writer.put(magnitudeBits(value, size), size)
            run = 0
        }
        if lastNonZero < 63 {
            writer.put(ac.codes[0x00], ac.sizes[0x00])
        }
        return dcValue
    }

    private static func magnitudeSize(_ value: Int) -> Int {
        var magnitude = abs(value)
        var size = 0
        while magnitude > 0 {
            magnitude >>= 1
            size += 1
        }
        return size
    }

    private static func magnitudeBits(_ value: Int, _ size: Int) -> UInt32 {
        value >= 0 ? UInt32(value) : UInt32(value + (1 << size) - 1)
    }

    private static func forwardDCT(_ block: inout [Float]) {
        var temp = [Float](repeating: 0, count: 64)
        for u in 0..<8 {
            for x in 0..<8 {
                var sum: Float = 0
                for i in 0..<8 {
                    sum += block[x * 8 + i] * Self.cosTable[u * 8 + i]
                }
                temp[x * 8 + u] = sum * (u == 0 ? 0.35355339 : 0.5)
            }
        }
        for u in 0..<8 {
            for v in 0..<8 {
                var sum: Float = 0
                for i in 0..<8 {
                    sum += temp[i * 8 + v] * Self.cosTable[u * 8 + i]
                }
                block[u * 8 + v] = sum * (u == 0 ? 0.35355339 : 0.5)
            }
        }
    }

    private static let cosTable: [Float] = {
        var table = [Float](repeating: 0, count: 64)
        for u in 0..<8 {
            for x in 0..<8 {
                table[u * 8 + x] = Float(cos(Double(2 * x + 1) * Double(u) * .pi / 16))
            }
        }
        return table
    }()
}
#endif
