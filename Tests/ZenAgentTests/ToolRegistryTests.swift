import Foundation
import Testing

@testable import ZenAgent

@Suite("Stage 2 tool registry and bundled tools")
struct ToolRegistryTests {

    @Test("the registry preserves descriptors and resolves executors")
    func registryResolvesTools() throws {
        let tools: [any ToolExecutable] = [
            CurrentDateTool(
                clock: { Date(timeIntervalSince1970: 1_735_689_600) },
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            ),
            CalculatorTool(),
            DeviceInfoTool(
                snapshot: DeviceInfoSnapshot(
                    osFamily: "iOS",
                    osVersion: "26.0",
                    deviceIdiom: "phone",
                    genericModelClass: "iPhone"
                )
            ),
        ]

        let registry = try ToolRegistry(tools: tools)

        #expect(
            registry.descriptors.map(\.id) == [
                "current_date",
                "calculator",
                "device_info",
            ]
        )
        #expect(registry.descriptor(id: "calculator") == tools[1].descriptor)
        #expect(registry.executor(id: "device_info") != nil)
        #expect(registry.descriptor(id: "missing") == nil)
        #expect(registry.executor(id: "missing") == nil)
    }

    @Test("duplicate descriptor IDs are rejected")
    func duplicateIDsFailInitialization() {
        let first = CalculatorTool()
        let duplicate = Stage2SideEffectTool(
            descriptorID: first.descriptor.id
        )

        do {
            _ = try ToolRegistry(tools: [first, duplicate])
            Issue.record("expected duplicate tool IDs to be rejected")
        } catch let error as ToolRegistryError {
            #expect(error == .duplicateToolID(first.descriptor.id))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("current date uses the injected clock and time zone")
    func currentDateIsDeterministic() async throws {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let tool = CurrentDateTool(
            clock: { Date(timeIntervalSince1970: 1_735_689_600) },
            timeZone: timeZone
        )

        let intent = try tool.prepare(
            callID: "date-call",
            argumentsJSON: "{}"
        )
        #expect(intent.formatVersion == ToolExecutionIntent.currentFormatVersion)
        #expect(intent.toolID == "current_date")
        #expect(intent.descriptorRevision == tool.descriptor.revision)
        #expect(intent.normalizedArgumentsJSON == "{}")
        #expect(intent.targetIdentity == nil)
        #expect(intent.destinationIdentity == nil)

        let result = try await tool.execute(
            intent,
            idempotencyKey: "date-key"
        )
        #expect(result.content.contains("2025-01-01"))
        #expect(result.content.contains(timeZone.identifier))
    }

    @Test("current date rejects arguments")
    func currentDateHasNoArguments() {
        let tool = CurrentDateTool()

        do {
            _ = try tool.prepare(
                callID: "date-call",
                argumentsJSON: "{\"unexpected\":true}"
            )
            Issue.record("expected arguments for current_date to be rejected")
        } catch let error as ToolExecutionError {
            guard case .invalidArguments = error else {
                Issue.record("unexpected tool error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("calculator evaluates only the restricted arithmetic grammar")
    func calculatorEvaluatesArithmetic() async throws {
        let tool = CalculatorTool()
        let intent = try tool.prepare(
            callID: "calculator-call",
            argumentsJSON: "{ \"expression\": \"1 + 2 * 3\" }"
        )

        #expect(
            intent.normalizedArgumentsJSON ==
                "{\"expression\":\"1 + 2 * 3\"}"
        )
        let result = try await tool.execute(
            intent,
            idempotencyKey: "calculator-key"
        )
        #expect(result.content == "7.0")
    }

    @Test("calculator refuses division by zero, invalid tokens, and non-finite results")
    func calculatorRejectsUnsafeOrInvalidExpressions() async throws {
        let tool = CalculatorTool()

        for expression in ["1 / 0", "1 + foo", "2(3)", "1e309"] {
            do {
                let intent = try tool.prepare(
                    callID: "calculator-call",
                    argumentsJSON: "{\"expression\":\"\(expression)\"}"
                )
                _ = try await tool.execute(intent, idempotencyKey: "calculator-key")
                Issue.record("expected expression to fail: \(expression)")
            } catch let error as ToolExecutionError {
                switch expression {
                case "1 / 0":
                    #expect(error == .divisionByZero)
                default:
                    #expect(error == .invalidExpression)
                }
            } catch {
                Issue.record("unexpected error for \(expression): \(error)")
            }
        }
    }

    @Test("device info exposes only the documented whitelist")
    func deviceInfoIsPrivacyBounded() async throws {
        let tool = DeviceInfoTool(
            snapshot: DeviceInfoSnapshot(
                osFamily: "iOS",
                osVersion: "26.0.1",
                deviceIdiom: "tablet",
                genericModelClass: "iPad"
            )
        )
        let intent = try tool.prepare(
            callID: "device-call",
            argumentsJSON: "{}"
        )
        let result = try await tool.execute(
            intent,
            idempotencyKey: "device-key"
        )

        let data = try #require(result.content.data(using: .utf8))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(Set(object.keys) == [
            "osFamily",
            "osVersion",
            "deviceIdiom",
            "genericModelClass",
        ])
        #expect(object["osFamily"] == "iOS")
        #expect(object["osVersion"] == "26.0.1")
        #expect(object["deviceIdiom"] == "tablet")
        #expect(object["genericModelClass"] == "iPad")
        #expect(!result.content.contains("identifierForVendor"))
        #expect(!result.content.contains("advertising"))
        #expect(!result.content.contains("serial"))
        #expect(!result.content.contains("IMEI"))
    }

    @Test("the test-only side-effect tool records its dispatch identity")
    func sideEffectToolRecordsObservation() async throws {
        let ledger = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: ledger)

        #expect(tool.descriptor.sideEffect == .externalWrite)
        #expect(tool.descriptor.approvalRequirement == .required)

        let intent = try tool.prepare(
            callID: "write-call",
            argumentsJSON: "{}"
        )
        _ = try await tool.execute(intent, idempotencyKey: "write-key")

        let observations = await ledger.snapshot()
        #expect(observations == [
            SideEffectObservation(
                toolCallID: "write-call",
                dispatchCount: 1,
                idempotencyKey: "write-key",
                outcome: "succeeded"
            )
        ])
    }
}
