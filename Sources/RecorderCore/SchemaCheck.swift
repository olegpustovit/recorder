import Foundation

/// A tool-argument problem found by `schemaViolation`; `range` separates out-of-range numbers/lengths from wrong shapes.
public struct SchemaViolation: Equatable, Sendable {
    public var message: String
    public var range = false
}

/// Checks `value` against the JSON-Schema subset the MCP tools declare (type, enum, minimum, maximum, minLength, maxItems,
/// items, properties, required, additionalProperties), so the schema is the one source of limits. `oneOf` is skipped:
/// op and time unions are checked by the op decoder.
public func schemaViolation(_ value: Any, _ schema: [String: Any], path: String = "arguments") -> SchemaViolation? {
    guard schema["oneOf"] == nil else { return nil }
    func number(_ raw: Any?) -> Double? { (raw as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue } }
    let type = schema["type"] as? String
    switch type {
    case "string":
        guard let text = value as? String else { return .init(message: "\(path) must be a string") }
        if let minimum = schema["minLength"] as? Int, text.count < minimum { return .init(message: "\(path) must not be empty", range: true) }
    case "boolean":
        guard (value as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else { return .init(message: "\(path) must be a boolean") }
    case "number", "integer":
        guard let n = number(value), n.isFinite, type == "number" || n.rounded() == n else {
            return .init(message: "\(path) must be \(type == "integer" ? "an integer" : "a finite number")")
        }
        if let low = number(schema["minimum"]), n < low { return .init(message: "\(path) must be at least \(low)", range: true) }
        if let high = number(schema["maximum"]), n > high { return .init(message: "\(path) must be at most \(high)", range: true) }
    case "array":
        guard let items = value as? [Any] else { return .init(message: "\(path) must be an array") }
        if let most = schema["maxItems"] as? Int, items.count > most { return .init(message: "\(path) takes at most \(most) items", range: true) }
        if let itemSchema = schema["items"] as? [String: Any] {
            for (index, item) in items.enumerated() { if let found = schemaViolation(item, itemSchema, path: "\(path)[\(index)]") { return found } }
        }
    case "object":
        guard let fields = value as? [String: Any] else { return .init(message: "\(path) must be an object") }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for (key, field) in fields.sorted(by: { $0.key < $1.key }) {
            if let sub = properties[key] as? [String: Any] { if let found = schemaViolation(field, sub, path: "\(path).\(key)") { return found } }
            else if schema["additionalProperties"] as? Bool == false { return .init(message: "\(path).\(key) is not a known field") }
        }
        if let missing = (schema["required"] as? [String])?.first(where: { fields[$0] == nil }) { return .init(message: "\(path).\(missing) is required") }
    default: break
    }
    if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { ($0 as AnyObject).isEqual(value) }) {
        return .init(message: "\(path) must be one of \(allowed.map { "\($0)" }.joined(separator: ", "))", range: !(value is String))
    }
    return nil
}
