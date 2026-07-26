import Foundation
import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk).
///
/// Plain slice-and-dice produces slivers that are impossible to hover or read;
/// squarifying keeps rectangles close to square, which is what makes a treemap
/// worth looking at.
public enum Treemap {
    public struct Tile: Identifiable {
        public var id: String { node.id }
        public let node: SpaceNode
        public let rect: CGRect
        public let fraction: Double
    }

    public static func layout(_ nodes: [SpaceNode], in bounds: CGRect) -> [Tile] {
        let positive = nodes.filter { $0.bytes > 0 }
        guard !positive.isEmpty, bounds.width > 1, bounds.height > 1 else { return [] }

        let total = positive.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return [] }

        let area = Double(bounds.width * bounds.height)
        let scale = area / Double(total)
        var remaining = positive.sorted { $0.bytes > $1.bytes }
        var container = bounds
        var tiles: [Tile] = []

        while !remaining.isEmpty {
            var row: [SpaceNode] = []
            var rowArea = 0.0
            let shortSide = Double(min(container.width, container.height))
            guard shortSide > 0 else { break }

            // Grow the row while it improves the worst aspect ratio.
            while let next = remaining.first {
                let nextArea = Double(next.bytes) * scale
                let candidateArea = rowArea + nextArea
                let candidate = row.map { Double($0.bytes) * scale } + [nextArea]

                if row.isEmpty || worstRatio(candidate, length: shortSide, total: candidateArea)
                    <= worstRatio(row.map { Double($0.bytes) * scale }, length: shortSide, total: rowArea) {
                    row.append(next)
                    rowArea = candidateArea
                    remaining.removeFirst()
                } else {
                    break
                }
            }

            guard !row.isEmpty else { break }
            let (placed, rest) = place(row, rowArea: rowArea, in: container, scale: scale, total: total)
            tiles.append(contentsOf: placed)
            container = rest
            if container.width <= 1 || container.height <= 1 { break }
        }

        return tiles
    }

    private static func worstRatio(_ areas: [Double], length: Double, total: Double) -> Double {
        guard !areas.isEmpty, total > 0, length > 0 else { return .greatestFiniteMagnitude }
        let maxArea = areas.max() ?? 0
        let minArea = areas.min() ?? 0
        guard minArea > 0 else { return .greatestFiniteMagnitude }
        let lengthSquared = length * length
        let totalSquared = total * total
        return max(
            (lengthSquared * maxArea) / totalSquared,
            totalSquared / (lengthSquared * minArea)
        )
    }

    private static func place(
        _ row: [SpaceNode],
        rowArea: Double,
        in container: CGRect,
        scale: Double,
        total: Int64
    ) -> ([Tile], CGRect) {
        var tiles: [Tile] = []
        let horizontal = container.width >= container.height

        if horizontal {
            let width = CGFloat(rowArea / Double(container.height))
            var y = container.minY
            for node in row {
                let nodeArea = Double(node.bytes) * scale
                let height = CGFloat(nodeArea / Double(width))
                tiles.append(
                    Tile(
                        node: node,
                        rect: CGRect(x: container.minX, y: y, width: width, height: height),
                        fraction: Double(node.bytes) / Double(total)
                    )
                )
                y += height
            }
            let rest = CGRect(
                x: container.minX + width,
                y: container.minY,
                width: max(0, container.width - width),
                height: container.height
            )
            return (tiles, rest)
        }

        let height = CGFloat(rowArea / Double(container.width))
        var x = container.minX
        for node in row {
            let nodeArea = Double(node.bytes) * scale
            let width = CGFloat(nodeArea / Double(height))
            tiles.append(
                Tile(
                    node: node,
                    rect: CGRect(x: x, y: container.minY, width: width, height: height),
                    fraction: Double(node.bytes) / Double(total)
                )
            )
            x += width
        }
        let rest = CGRect(
            x: container.minX,
            y: container.minY + height,
            width: container.width,
            height: max(0, container.height - height)
        )
        return (tiles, rest)
    }
}
