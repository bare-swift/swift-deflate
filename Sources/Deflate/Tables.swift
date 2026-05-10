// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

/// Constant tables from RFC 1951.
enum Tables {
    /// § 3.2.7 — code-length-alphabet permutation order.
    static let codeLengthOrder: [Int] = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    /// § 3.2.5 — length codes 257..285. Entry `[i]` is `(baseLength,
    /// extraBits)` for code `257 + i`. Code 285 has no extras (length 258).
    static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10,        // 257..264
        11, 13, 15, 17,                 // 265..268
        19, 23, 27, 31,                 // 269..272
        35, 43, 51, 59,                 // 273..276
        67, 83, 99, 115,                // 277..280
        131, 163, 195, 227,             // 281..284
        258,                            // 285
    ]

    static let lengthExtra: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1,
        2, 2, 2, 2,
        3, 3, 3, 3,
        4, 4, 4, 4,
        5, 5, 5, 5,
        0,
    ]

    /// § 3.2.5 — distance codes 0..29. Code 30/31 are reserved.
    static let distanceBase: [Int] = [
        1, 2, 3, 4,             // 0..3
        5, 7,                   // 4..5
        9, 13,                  // 6..7
        17, 25,                 // 8..9
        33, 49,                 // 10..11
        65, 97,                 // 12..13
        129, 193,               // 14..15
        257, 385,               // 16..17
        513, 769,               // 18..19
        1025, 1537,             // 20..21
        2049, 3073,             // 22..23
        4097, 6145,             // 24..25
        8193, 12289,            // 26..27
        16385, 24577,           // 28..29
    ]

    static let distanceExtra: [Int] = [
        0, 0, 0, 0,
        1, 1,
        2, 2,
        3, 3,
        4, 4,
        5, 5,
        6, 6,
        7, 7,
        8, 8,
        9, 9,
        10, 10,
        11, 11,
        12, 12,
        13, 13,
    ]

    /// § 3.2.6 — fixed Huffman code lengths for the literal/length
    /// alphabet (288 symbols).
    /// - 000–143: length 8
    /// - 144–255: length 9
    /// - 256–279: length 7
    /// - 280–287: length 8
    static let fixedLitLenLengths: [Int] = {
        var out = [Int](repeating: 0, count: 288)
        for i in 0..<144 { out[i] = 8 }
        for i in 144..<256 { out[i] = 9 }
        for i in 256..<280 { out[i] = 7 }
        for i in 280..<288 { out[i] = 8 }
        return out
    }()

    /// § 3.2.6 — fixed Huffman distance code lengths (all 5 bits).
    static let fixedDistanceLengths: [Int] = [Int](repeating: 5, count: 30)
}
