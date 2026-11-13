import Foundation

enum DiffOp: Hashable {
    case same(String)
    case left(String)
    case right(String)
}

struct DiffRow: Identifiable, Hashable {
    enum Kind { case same, changed, leftOnly, rightOnly }
    let id: Int
    let kind: Kind
    let left: (no: Int, text: String)?
    let right: (no: Int, text: String)?

    static func == (a: DiffRow, b: DiffRow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PairComparison {
    let similarity: Double
    let onlyLeft: Int
    let onlyRight: Int
}

enum LineDiff {
    static func lines(_ text: String) -> [String] {
        var parts = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Longest-common-subsequence line diff.
    static func diff(_ a: [String], _ b: [String]) -> [DiffOp] {
        let n = a.count, m = b.count
        if n == 0 { return b.map(DiffOp.right) }
        if m == 0 { return a.map(DiffOp.left) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var ops: [DiffOp] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { ops.append(.same(a[i])); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { ops.append(.left(a[i])); i += 1 }
            else { ops.append(.right(b[j])); j += 1 }
        }
        while i < n { ops.append(.left(a[i])); i += 1 }
        while j < m { ops.append(.right(b[j])); j += 1 }
        return ops
    }

    /// Rows for a side-by-side view; runs of removals and insertions are paired up.
    static func sideBySide(_ leftText: String, _ rightText: String) -> [DiffRow] {
        let ops = diff(lines(leftText), lines(rightText))
        var rows: [DiffRow] = []
        var ln = 0, rn = 0
        var pendingLeft: [(Int, String)] = []
        var pendingRight: [(Int, String)] = []

        func flush() {
            let count = max(pendingLeft.count, pendingRight.count)
            for k in 0..<count {
                let l = k < pendingLeft.count ? pendingLeft[k] : nil
                let r = k < pendingRight.count ? pendingRight[k] : nil
                let kind: DiffRow.Kind = (l != nil && r != nil) ? .changed : (l != nil ? .leftOnly : .rightOnly)
                rows.append(DiffRow(id: rows.count, kind: kind,
                                    left: l.map { (no: $0.0, text: $0.1) },
                                    right: r.map { (no: $0.0, text: $0.1) }))
            }
            pendingLeft.removeAll()
            pendingRight.removeAll()
        }

        for op in ops {
            switch op {
            case .same(let s):
                flush()
                ln += 1; rn += 1
                rows.append(DiffRow(id: rows.count, kind: .same, left: (no: ln, text: s), right: (no: rn, text: s)))
            case .left(let s):
                ln += 1
                pendingLeft.append((ln, s))
            case .right(let s):
                rn += 1
                pendingRight.append((rn, s))
            }
        }
        flush()
        return rows
    }

    /// Similarity over meaningful (non-blank, trimmed) lines.
    static func compare(_ a: String, _ b: String) -> PairComparison {
        func meaningful(_ s: String) -> [String] {
            lines(s).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let la = meaningful(a), lb = meaningful(b)
        guard !(la.isEmpty && lb.isEmpty) else { return PairComparison(similarity: 1, onlyLeft: 0, onlyRight: 0) }
        let same = diff(la, lb).filter { if case .same = $0 { return true } else { return false } }.count
        return PairComparison(
            similarity: Double(2 * same) / Double(la.count + lb.count),
            onlyLeft: la.count - same,
            onlyRight: lb.count - same)
    }
}
