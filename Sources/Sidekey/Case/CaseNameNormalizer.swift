import Foundation

enum CaseNameValidationError: Error, Equatable {
    case empty
    case rawTooLong
    case nonASCII
    case normalizedTooLong
}

enum CaseNameNormalizer {
    static let maxRawLength = 80
    static let maxNormalizedLength = 64

    static func normalizedName(_ raw: String) throws -> String {
        guard raw.count <= maxRawLength else { throw CaseNameValidationError.rawTooLong }
        guard raw.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw CaseNameValidationError.nonASCII
        }

        var parts: [String] = []
        var current = ""

        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isUpper = value >= 65 && value <= 90
            let isLower = value >= 97 && value <= 122

            if isDigit || isUpper || isLower {
                current.append(Character(scalar))
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            parts.append(current)
        }

        let normalized = parts
            .map { $0.uppercased() }
            .joined(separator: "_")

        guard !normalized.isEmpty else { throw CaseNameValidationError.empty }
        guard normalized.count <= maxNormalizedLength else {
            throw CaseNameValidationError.normalizedTooLong
        }
        return normalized
    }

    static func isDuplicate(_ raw: String, existingNames: [String]) throws -> Bool {
        let normalized = try normalizedName(raw)
        return existingNames.contains {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }
}
