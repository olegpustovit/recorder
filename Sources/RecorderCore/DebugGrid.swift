import Foundation

/// Geometry of the optional `render.frames` debug grid: normalized 0–1 lines, origin top-left,
/// the same coordinates zoom `center` and text `position` use. Pure so it can be tested without drawing.
public enum DebugGrid {
    public struct Line: Equatable, Sendable {
        public enum Axis: Sendable { case vertical, horizontal }
        public var axis: Axis
        public var value: Double      // normalized 0–1
        public var label: String      // "0.0" … "1.0"
        public var major: Bool        // 0, 0.5 and 1 are emphasised
    }
    public static let divisions = 10
    public static var lines: [Line] {
        [Line.Axis.vertical, .horizontal].flatMap { axis in
            (0...divisions).map { i in
                let value = Double(i) / Double(divisions)
                return Line(axis: axis, value: value, label: String(format: "%.1f", value), major: i % 5 == 0)
            }
        }
    }
    /// Pixel offset of a normalized value along an axis of `length` pixels (top-left origin; the last line sits on the final pixel).
    public static func pixel(_ value: Double, length: Int) -> Double { min(max(value, 0), 1) * Double(max(length - 1, 0)) }
}
