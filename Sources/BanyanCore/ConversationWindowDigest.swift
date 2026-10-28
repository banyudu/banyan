import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-256 for bounded conversation snapshots. The portable implementation is
/// kept here so the core target also builds on Linux without a new dependency.
enum ConversationWindowDigest {
    static func hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let bytes = Array(SHA256.hash(data: data))
        #else
        let bytes = portable(data)
        #endif
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// FIPS 180-4 SHA-256, exercised against standard vectors on every platform.
    static func portable(_ data: Data) -> [UInt8] {
        let constants: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var bytes = Array(data)
        let bitCount = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bitCount >> shift)) }
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32 - count)) }
        var words = [UInt32](repeating: 0, count: 64)
        for start in stride(from: 0, to: bytes.count, by: 64) {
            for index in 0..<16 {
                let position = start + index * 4
                words[index] = UInt32(bytes[position]) << 24 | UInt32(bytes[position + 1]) << 16 |
                    UInt32(bytes[position + 2]) << 8 | UInt32(bytes[position + 3])
            }
            for index in 16..<64 {
                let a = words[index - 15], b = words[index - 2]
                let s0 = rotate(a, 7) ^ rotate(a, 18) ^ (a >> 3)
                let s1 = rotate(b, 17) ^ rotate(b, 19) ^ (b >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let first = h &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let second = s0 &+ majority
                h = g; g = f; f = e; e = d &+ first
                d = c; c = b; b = a; a = first &+ second
            }
            state[0] = state[0] &+ a; state[1] = state[1] &+ b
            state[2] = state[2] &+ c; state[3] = state[3] &+ d
            state[4] = state[4] &+ e; state[5] = state[5] &+ f
            state[6] = state[6] &+ g; state[7] = state[7] &+ h
        }
        return state.flatMap { value in
            [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
             UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
    }
}
