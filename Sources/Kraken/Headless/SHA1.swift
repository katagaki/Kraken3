import Foundation

enum SHA1 {
    static func digest(_ input: Data) -> Data {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]

        var message = input
        let bitLength = UInt64(input.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        let bytes = [UInt8](message)
        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let o = chunkStart + i * 4
                w[i] = (UInt32(bytes[o]) << 24) | (UInt32(bytes[o + 1]) << 16)
                     | (UInt32(bytes[o + 2]) << 8) | UInt32(bytes[o + 3])
            }
            for i in 16..<80 {
                let value = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (value << 1) | (value >> 31)
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
        }

        var output = Data(capacity: 20)
        for value in h {
            output.append(UInt8((value >> 24) & 0xFF))
            output.append(UInt8((value >> 16) & 0xFF))
            output.append(UInt8((value >> 8) & 0xFF))
            output.append(UInt8(value & 0xFF))
        }
        return output
    }
}
