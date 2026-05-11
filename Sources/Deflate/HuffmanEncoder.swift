// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

/// Constructs canonical Huffman codes from symbol frequencies.
/// Implements the "package-merge" length-limiting algorithm (Larmore &
/// Hirschberg, 1990) so the resulting code-length array never exceeds
/// `maxBits`.
enum HuffmanEncoder {
    private struct Item {
        var weight: Int
        var symbols: [Int]
    }

    /// Build code lengths for an alphabet given symbol frequencies.
    /// Symbols with frequency 0 get length 0 (excluded from the code).
    /// The output array has `frequencies.count` entries; lengths are
    /// guaranteed ≤ `maxBits`.
    static func buildLengths(frequencies: [Int], maxBits: Int) -> [Int] {
        var lengths = [Int](repeating: 0, count: frequencies.count)
        var active: [(freq: Int, sym: Int)] = []
        for (sym, f) in frequencies.enumerated() where f > 0 {
            active.append((f, sym))
        }
        switch active.count {
        case 0:
            return lengths
        case 1:
            lengths[active[0].sym] = 1
            return lengths
        default:
            break
        }

        let leafSorted: [Item] = active
            .sorted { $0.freq < $1.freq }
            .map { Item(weight: $0.freq, symbols: [$0.sym]) }
        var lastList = leafSorted

        for _ in 1..<maxBits {
            var packaged: [Item] = []
            var i = 0
            while i + 1 < lastList.count {
                packaged.append(Item(
                    weight: lastList[i].weight + lastList[i + 1].weight,
                    symbols: lastList[i].symbols + lastList[i + 1].symbols
                ))
                i += 2
            }
            lastList = mergeSorted(leafSorted, packaged)
        }

        let pick = 2 * (active.count - 1)
        let chosen = Array(lastList.prefix(pick))
        var lenCount = [Int: Int]()
        for item in chosen {
            for sym in item.symbols {
                lenCount[sym, default: 0] += 1
            }
        }
        for (sym, l) in lenCount {
            lengths[sym] = l
        }
        return lengths
    }

    private static func mergeSorted(_ a: [Item], _ b: [Item]) -> [Item] {
        var out: [Item] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i].weight <= b[j].weight {
                out.append(a[i]); i += 1
            } else {
                out.append(b[j]); j += 1
            }
        }
        while i < a.count { out.append(a[i]); i += 1 }
        while j < b.count { out.append(b[j]); j += 1 }
        return out
    }

    /// Generate canonical codes (RFC 1951 § 3.2.2) from a code-length
    /// array. Output is parallel to the input — entry `[i]` is the
    /// MSB-first code for symbol `i`, or 0 if `lengths[i] == 0`.
    static func canonicalCodes(lengths: [Int]) -> [UInt32] {
        var codes = [UInt32](repeating: 0, count: lengths.count)
        guard let maxLen = lengths.max(), maxLen > 0 else { return codes }
        var blCount = [Int](repeating: 0, count: maxLen + 1)
        for l in lengths { blCount[l] += 1 }
        var nextCode = [UInt32](repeating: 0, count: maxLen + 1)
        var code: UInt32 = 0
        blCount[0] = 0
        for bits in 1...maxLen {
            code = (code + UInt32(blCount[bits - 1])) << 1
            nextCode[bits] = code
        }
        for n in 0..<lengths.count {
            let len = lengths[n]
            if len != 0 {
                codes[n] = nextCode[len]
                nextCode[len] += 1
            }
        }
        return codes
    }
}
