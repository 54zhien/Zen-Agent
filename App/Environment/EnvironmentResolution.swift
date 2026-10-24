import Foundation

/// Pure scoped selection and bounded expansion; it cannot read credentials.
enum EnvironmentResolution {
    static func select(skillID: String, declaredKeys: [String], available: [EnvironmentItem]) throws -> [EnvironmentItem] {
        guard declaredKeys.count <= 32, Set(declaredKeys).count == declaredKeys.count,
              declaredKeys.allSatisfy(EnvironmentValidation.allowsKey) else { throw EnvironmentError.invalidKey }
        return try declaredKeys.sorted().map { key in
            let scoped = available.filter { $0.key == key && $0.scope == .skill(skillID) }
            let global = available.filter { $0.key == key && $0.scope == .global }
            guard scoped.count <= 1, global.count <= 1 else { throw EnvironmentError.erasedDependency }
            guard let item = scoped.first ?? global.first else { throw EnvironmentError.missingReference }
            guard !item.pendingDeletion else { throw EnvironmentError.erasedDependency }
            return item
        }
    }
    static func interpolate(_ text: String, items: [EnvironmentItem], declaredKeys: [String]) throws -> String {
        guard EnvironmentValidation.allowsPlain(text), declaredKeys.count <= 32,
              Set(declaredKeys).count == declaredKeys.count, items.count <= 32,
              Set(items.map(\.key)).count == items.count,
              Set(items.map(\.key)) == Set(declaredKeys) else { throw EnvironmentError.missingReference }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.value) })
        var expanded: [String: String] = [:]
        func render(_ text: String, stack: Set<String>) throws -> String {
            var result = "", cursor = text.startIndex
            func append(_ piece: String) throws {
                guard result.utf8.count + piece.utf8.count <= EnvironmentValidation.maximumPlainUTF8Bytes else { throw EnvironmentError.invalidValue }
                result += piece
            }
            while let start = text.range(of: "${", range: cursor..<text.endIndex) {
                try append(String(text[cursor..<start.lowerBound]))
                guard let end = text[start.upperBound...].firstIndex(of: "}") else { throw EnvironmentError.invalidValue }
                let key = String(text[start.upperBound..<end])
                guard let value = values[key] else { throw EnvironmentError.missingReference }
                guard !stack.contains(key) else { throw EnvironmentError.cycle }
                guard case .plain(let plain) = value else { throw EnvironmentError.secretInterpolation }
                guard EnvironmentValidation.allowsPlain(plain) else { throw EnvironmentError.invalidValue }
                let resolved: String
                if let cached = expanded[key] { resolved = cached }
                else { resolved = try render(plain, stack: stack.union([key])); expanded[key] = resolved }
                try append(resolved)
                cursor = text.index(after: end)
            }
            try append(String(text[cursor...]))
            return result
        }
        return try render(text, stack: [])
    }
}
