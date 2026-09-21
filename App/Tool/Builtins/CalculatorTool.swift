import Foundation

struct CalculatorTool: ToolExecutable {
    static let toolID = "calculator"

    let descriptor: ToolDescriptor

    init() {
        self.descriptor = ToolDescriptor(
            id: Self.toolID,
            displayName: "Calculator",
            description: "Evaluates a restricted arithmetic expression.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "expression": .object([
                        "type": .string("string"),
                    ]),
                ]),
                "required": .array([.string("expression")]),
                "additionalProperties": .bool(false),
            ]),
            revision: "1",
            sideEffect: .none,
            approvalRequirement: .notRequired
        )
    }

    func prepare(
        callID: String,
        argumentsJSON: String
    ) throws -> ToolExecutionIntent {
        _ = callID
        let object = try ToolArgumentJSON.object(from: argumentsJSON)
        guard object.count == 1, let expression = object["expression"] as? String else {
            throw ToolExecutionError.invalidArguments
        }

        let normalizedArgumentsJSON = try ToolArgumentJSON.normalizedObject([
            "expression": expression,
        ])

        return ToolExecutionIntent(
            formatVersion: ToolExecutionIntent.currentFormatVersion,
            toolID: descriptor.id,
            descriptorRevision: descriptor.revision,
            normalizedArgumentsJSON: normalizedArgumentsJSON,
            targetIdentity: nil,
            destinationIdentity: nil
        )
    }

    func execute(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws -> ToolExecutionResult {
        _ = idempotencyKey
        guard
            intent.formatVersion == ToolExecutionIntent.currentFormatVersion,
            intent.toolID == descriptor.id,
            intent.descriptorRevision == descriptor.revision,
            intent.targetIdentity == nil,
            intent.destinationIdentity == nil
        else {
            throw ToolExecutionError.invalidIntent
        }

        let object = try ToolArgumentJSON.object(from: intent.normalizedArgumentsJSON)
        guard object.count == 1, let expression = object["expression"] as? String else {
            throw ToolExecutionError.invalidIntent
        }

        var parser = ArithmeticParser(expression: expression)
        let value = try parser.parse()
        guard value.isFinite else {
            throw ToolExecutionError.invalidExpression
        }

        return ToolExecutionResult(content: String(value))
    }
}

private struct ArithmeticParser {
    private let characters: [Character]
    private var index: Int = 0

    init(expression: String) {
        self.characters = Array(expression)
    }

    mutating func parse() throws -> Double {
        let value = try parseExpression()
        skipWhitespace()
        guard index == characters.count, value.isFinite else {
            throw ToolExecutionError.invalidExpression
        }
        return value
    }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()

        while true {
            skipWhitespace()
            guard let operation = currentCharacter, operation == "+" || operation == "-" else {
                return value
            }
            index += 1

            let rhs = try parseTerm()
            value = operation == "+" ? value + rhs : value - rhs
            guard value.isFinite else {
                throw ToolExecutionError.invalidExpression
            }
        }
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseUnary()

        while true {
            skipWhitespace()
            guard let operation = currentCharacter, operation == "*" || operation == "/" else {
                return value
            }
            index += 1

            let rhs = try parseUnary()
            if operation == "/" {
                guard rhs != 0 else {
                    throw ToolExecutionError.divisionByZero
                }
                value /= rhs
            } else {
                value *= rhs
            }
            guard value.isFinite else {
                throw ToolExecutionError.invalidExpression
            }
        }
    }

    private mutating func parseUnary() throws -> Double {
        skipWhitespace()
        guard let operation = currentCharacter, operation == "+" || operation == "-" else {
            return try parsePrimary()
        }

        index += 1
        let value = try parseUnary()
        let result = operation == "-" ? -value : value
        guard result.isFinite else {
            throw ToolExecutionError.invalidExpression
        }
        return result
    }

    private mutating func parsePrimary() throws -> Double {
        skipWhitespace()

        if currentCharacter == "(" {
            index += 1
            let value = try parseExpression()
            skipWhitespace()
            guard currentCharacter == ")" else {
                throw ToolExecutionError.invalidExpression
            }
            index += 1
            return value
        }

        guard let character = currentCharacter, character.isASCIIDigit || character == "." else {
            throw ToolExecutionError.invalidExpression
        }
        return try parseNumber()
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        var digitCount = 0

        while let character = currentCharacter, character.isASCIIDigit {
            digitCount += 1
            index += 1
        }

        if currentCharacter == "." {
            index += 1
            while let character = currentCharacter, character.isASCIIDigit {
                digitCount += 1
                index += 1
            }
        }

        guard digitCount > 0 else {
            throw ToolExecutionError.invalidExpression
        }

        let token = String(characters[start..<index])
        guard let value = Double(token), value.isFinite else {
            throw ToolExecutionError.invalidExpression
        }
        return value
    }

    private mutating func skipWhitespace() {
        while let character = currentCharacter, character.isWhitespace {
            index += 1
        }
    }

    private var currentCharacter: Character? {
        guard index < characters.count else { return nil }
        return characters[index]
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else {
            return false
        }
        return scalar.value >= 48 && scalar.value <= 57
    }
}
