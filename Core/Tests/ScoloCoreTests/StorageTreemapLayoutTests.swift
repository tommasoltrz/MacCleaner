import Testing
@testable import ScoloCore

@Suite("Storage treemap layout")
struct StorageTreemapLayoutTests {
    @Test("cells cover the unit rectangle without overlap")
    func coversUnitRectangle() throws {
        let cells = StorageTreemapLayout.cells(for: [
            .init(id: "A", bytes: 8),
            .init(id: "B", bytes: 5),
            .init(id: "C", bytes: 3),
            .init(id: "D", bytes: 2),
            .init(id: "E", bytes: 1)
        ])

        #expect(abs(cells.reduce(0.0) { $0 + $1.area } - 1) < 0.000_000_001)
        for cell in cells {
            #expect(cell.x >= 0)
            #expect(cell.y >= 0)
            #expect(cell.x + cell.width <= 1.000_000_001)
            #expect(cell.y + cell.height <= 1.000_000_001)
        }
        for firstIndex in cells.indices {
            for secondIndex in cells.indices where secondIndex > firstIndex {
                #expect(overlap(cells[firstIndex], cells[secondIndex]) < 0.000_000_001)
            }
        }
    }

    @Test("cell area follows allocated bytes")
    func preservesProportions() throws {
        let cells = StorageTreemapLayout.cells(for: [
            .init(id: "large", bytes: 4),
            .init(id: "medium", bytes: 2),
            .init(id: "small", bytes: 1)
        ])
        let byID = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })

        #expect(abs(try #require(byID["large"]).area - 4.0 / 7.0) < 0.000_000_001)
        #expect(abs(try #require(byID["medium"]).area - 2.0 / 7.0) < 0.000_000_001)
        #expect(abs(try #require(byID["small"]).area - 1.0 / 7.0) < 0.000_000_001)
    }

    @Test("items that use no space are not drawn")
    func omitsZeroSizedItems() {
        let cells = StorageTreemapLayout.cells(for: [
            .init(id: "positive", bytes: 1),
            .init(id: "zero", bytes: 0),
            .init(id: "invalid", bytes: -1)
        ])

        #expect(cells.map(\.id) == ["positive"])
        #expect(cells.first?.area == 1)
    }

    private func overlap(
        _ first: StorageTreemapLayout.Cell,
        _ second: StorageTreemapLayout.Cell
    ) -> Double {
        let width = max(0, min(first.x + first.width, second.x + second.width) - max(first.x, second.x))
        let height = max(0, min(first.y + first.height, second.y + second.height) - max(first.y, second.y))
        return width * height
    }
}
