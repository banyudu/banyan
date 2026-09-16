//
//  ContentFingerprint.swift
//  SwiftTerm
//
//  A cheap, allocation-free fingerprint over rendered cell content. The render
//  caches need to answer "would this row draw differently?" on every repaint of
//  every rewritten row, which is far too hot for Swift's `Hasher` — folding an
//  `Attribute` through the synthesized `Hashable` conformance costs more than the
//  rest of the row put together.
//

import Foundation

/// FNV-1a, 64-bit. Chosen for a short dependency-free implementation with good
/// avalanche on the small integers this folds; the fingerprint is compared only
/// within a single process run and is never persisted.
@usableFromInline
struct ContentFingerprint {
    @usableFromInline
    var value: UInt64 = 0xcbf2_9ce4_8422_2325

    @inline(__always)
    init() {}

    @inline(__always)
    mutating func combine(_ byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 0x1000_0000_01b3
    }

    @inline(__always)
    mutating func combine(_ word: UInt32) {
        combine(UInt8(truncatingIfNeeded: word))
        combine(UInt8(truncatingIfNeeded: word >> 8))
        combine(UInt8(truncatingIfNeeded: word >> 16))
        combine(UInt8(truncatingIfNeeded: word >> 24))
    }

    @inline(__always)
    mutating func combine(_ word: UInt16) {
        combine(UInt8(truncatingIfNeeded: word))
        combine(UInt8(truncatingIfNeeded: word >> 8))
    }
}

extension Attribute.Color {
    /// Packs a color into 26 significant bits: a 2-bit tag plus its payload.
    @inline(__always)
    var fingerprintCode: UInt32 {
        switch self {
        case .defaultColor:
            return 0
        case .defaultInvertedColor:
            return 1
        case .ansi256(let code):
            return 0x0200_0000 | UInt32(code)
        case .trueColor(let red, let green, let blue):
            return 0x0300_0000 | (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
        }
    }
}

extension Attribute {
    @inline(__always)
    func fold(into fingerprint: inout ContentFingerprint) {
        fingerprint.combine(fg.fingerprintCode)
        fingerprint.combine(bg.fingerprintCode)
        fingerprint.combine(style.rawValue)
        fingerprint.combine(underlineStyle.rawValue)
        // nil and an explicit color must not collide, so tag the presence bit.
        fingerprint.combine(underlineColor.map { $0.fingerprintCode | 0x8000_0000 } ?? 0)
    }
}

extension CharData {
    @inline(__always)
    func fold(into fingerprint: inout ContentFingerprint) {
        fingerprint.combine(UInt32(bitPattern: code))
        fingerprint.combine(UInt8(bitPattern: width))
        fingerprint.combine(payload.code)
        attribute.fold(into: &fingerprint)
    }
}
