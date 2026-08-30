import Foundation

/// Creates a squarified treemap in a normalized unit rectangle.
public enum StorageTreemapLayout {
    public struct Item: Sendable, Equatable {
        public let id: String
        public let bytes: Int64

        public init(id: String, bytes: Int64) {
            self.id = id
            self.bytes = bytes
        }
    }

    public struct Cell: Sendable, Equatable, Identifiable {
        public let id: String
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(id: String, x: Double, y: Double, width: Double, height: Double) {
            self.id = id
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var area: Double { width * height }
    }

    private struct WeightedItem {
        let id: String
        let area: Double
    }

    private struct Rectangle {
        var x = 0.0
        var y = 0.0
        var width = 1.0
        var height = 1.0

        var shortestSide: Double { min(width, height) }
    }

    /// Returns one cell for each item that uses allocated disk space.
    public static func cells(for items: [Item]) -> [Cell] {
        let positive = items
            .filter { $0.bytes > 0 }
            .sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.id < $1.id
            }
        let total = positive.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else { return [] }

        let weighted = positive.map {
            WeightedItem(id: $0.id, area: Double($0.bytes) / total)
        }
        var remaining = Rectangle()
        var row: [WeightedItem] = []
        var cells: [Cell] = []

        for item in weighted {
            let candidate = row + [item]
            if row.isEmpty
                || worstAspectRatio(candidate, side: remaining.shortestSide)
                    <= worstAspectRatio(row, side: remaining.shortestSide) {
                row = candidate
            } else {
                cells.append(contentsOf: layout(row, in: &remaining))
                row = [item]
            }
        }
        cells.append(contentsOf: layout(row, in: &remaining))
        return cells
    }

    private static func worstAspectRatio(_ row: [WeightedItem], side: Double) -> Double {
        guard side > 0,
              let smallest = row.map(\.area).min(),
              let largest = row.map(\.area).max(),
              smallest > 0
        else { return .infinity }

        let sum = row.reduce(0.0) { $0 + $1.area }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(
            sideSquared * largest / sumSquared,
            sumSquared / (sideSquared * smallest)
        )
    }

    private static func layout(
        _ row: [WeightedItem],
        in remaining: inout Rectangle
    ) -> [Cell] {
        guard !row.isEmpty, remaining.width > 0, remaining.height > 0 else { return [] }
        let rowArea = row.reduce(0.0) { $0 + $1.area }
        var cells: [Cell] = []

        if remaining.width >= remaining.height {
            let stripWidth = min(remaining.width, rowArea / remaining.height)
            guard stripWidth > 0 else { return [] }
            var y = remaining.y
            for (index, item) in row.enumerated() {
                let height = index == row.count - 1
                    ? remaining.y + remaining.height - y
                    : item.area / stripWidth
                cells.append(Cell(
                    id: item.id,
                    x: remaining.x,
                    y: y,
                    width: stripWidth,
                    height: max(0, height)
                ))
                y += height
            }
            remaining.x += stripWidth
            remaining.width = max(0, remaining.width - stripWidth)
        } else {
            let stripHeight = min(remaining.height, rowArea / remaining.width)
            guard stripHeight > 0 else { return [] }
            var x = remaining.x
            for (index, item) in row.enumerated() {
                let width = index == row.count - 1
                    ? remaining.x + remaining.width - x
                    : item.area / stripHeight
                cells.append(Cell(
                    id: item.id,
                    x: x,
                    y: remaining.y,
                    width: max(0, width),
                    height: stripHeight
                ))
                x += width
            }
            remaining.y += stripHeight
            remaining.height = max(0, remaining.height - stripHeight)
        }
        return cells
    }
}
