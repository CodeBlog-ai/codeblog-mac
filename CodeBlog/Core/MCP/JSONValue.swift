import Foundation

enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(any value: Any) throws {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [String: Any]:
            var mapped: [String: JSONValue] = [:]
            mapped.reserveCapacity(value.count)
            for (key, inner) in value {
                mapped[key] = try JSONValue(any: inner)
            }
            self = .object(mapped)
        case let value as [Any]:
            self = .array(try value.map { try JSONValue(any: $0) })
        case _ as NSNull:
            self = .null
        default:
            throw JSONValueError.unsupportedType(String(describing: type(of: value)))
        }
    }

    var foundationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.foundationValue }
        case .array(let value):
            return value.map { $0.foundationValue }
        case .null:
            return NSNull()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }
}

enum JSONValueError: LocalizedError {
    case unsupportedType(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return "Unsupported JSON type: \(name)"
        }
    }
}

