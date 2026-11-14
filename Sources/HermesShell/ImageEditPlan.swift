import Foundation

struct ImageEditPoint: Equatable, Sendable {
    let x: Double
    let y: Double
    init(x: Double, y: Double) {
        self.x = x.isFinite ? min(1, max(0, x)) : 0
        self.y = y.isFinite ? min(1, max(0, y)) : 0
    }
}

struct ImageEditCrop: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    static let full = ImageEditCrop(x: 0, y: 0, width: 1, height: 1)
    var valid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0
            && width >= 0.02 && height >= 0.02 && x + width <= 1.000001 && y + height <= 1.000001
    }
}

enum ImageEditMarkKind: String, Sendable { case pen, arrow, rectangle }
enum ImageEditColor: String, CaseIterable, Sendable { case red, yellow, blue, black }

struct ImageEditMark: Equatable, Sendable {
    let kind: ImageEditMarkKind
    let color: ImageEditColor
    let points: [ImageEditPoint]
}

enum ImageEditStep: Equatable, Sendable {
    case rotateClockwise
    case crop(ImageEditCrop)
    case mark(ImageEditMark)
}

/// Small operation history, never a stack of decoded full-resolution images.
struct ImageEditHistory: Equatable, Sendable {
    static let limit = 40
    private(set) var steps: [ImageEditStep] = []
    var canUndo: Bool { !steps.isEmpty }

    @discardableResult mutating func append(_ step: ImageEditStep) -> Bool {
        guard steps.count < Self.limit else { return false }
        switch step {
        case .crop(let crop): guard crop.valid else { return false }
        case .mark(let mark): guard !mark.points.isEmpty, mark.points.count <= 2048 else { return false }
        case .rotateClockwise: break
        }
        steps.append(step)
        return true
    }
    mutating func undo() { if !steps.isEmpty { steps.removeLast() } }
    mutating func reset() { steps.removeAll() }
}
