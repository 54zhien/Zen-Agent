#if DEBUG
import Foundation

struct Stage10ManualMeasurementCapture: Sendable {
    let startedAt: Date?
    let sourceCommit: String?
    let providerHTTP429Responses: [[String: String]]
}

enum Stage10ManualMeasurementStorage {
    static let startedAtKey = "stage10.manualMeasurement.startedAt"
    static let sourceCommitKey = "stage10.manualMeasurement.sourceCommit"
    static let rateLimitResponsesKey = "stage10.manualMeasurement.providerHTTP429Responses"

    static func beginManualMeasurementLaunch(sourceCommit: String?, at: Date = Date()) {
        let defaults = UserDefaults.standard
        defaults.set(at, forKey: startedAtKey)
        if let sourceCommit, !sourceCommit.isEmpty {
            defaults.set(sourceCommit, forKey: sourceCommitKey)
        } else {
            defaults.removeObject(forKey: sourceCommitKey)
        }
        defaults.removeObject(forKey: rateLimitResponsesKey)
    }
}

actor Stage10ManualMeasurementRecorder {
    static let shared = Stage10ManualMeasurementRecorder()

    func record(_ response: HTTPResponse, at: Date = Date()) {
        guard response.status == 429 else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var observation = ["observedAt": formatter.string(from: at)]
        if let retryAfter = response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
        })?.value {
            observation["retryAfterHeader"] = retryAfter
        }

        var observations = UserDefaults.standard.array(
            forKey: Stage10ManualMeasurementStorage.rateLimitResponsesKey
        ) as? [[String: String]] ?? []
        observations.append(observation)
        UserDefaults.standard.set(
            observations,
            forKey: Stage10ManualMeasurementStorage.rateLimitResponsesKey
        )
    }

    func capture() -> Stage10ManualMeasurementCapture {
        Stage10ManualMeasurementCapture(
            startedAt: UserDefaults.standard.object(
                forKey: Stage10ManualMeasurementStorage.startedAtKey
            ) as? Date,
            sourceCommit: UserDefaults.standard.string(
                forKey: Stage10ManualMeasurementStorage.sourceCommitKey
            ),
            providerHTTP429Responses: UserDefaults.standard.array(
                forKey: Stage10ManualMeasurementStorage.rateLimitResponsesKey
            ) as? [[String: String]] ?? []
        )
    }
}

struct Stage10ManualMeasurementTransport: HTTPTransport {
    private let underlying: any HTTPTransport
    private let recorder = Stage10ManualMeasurementRecorder.shared

    init(underlying: any HTTPTransport) {
        self.underlying = underlying
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await underlying.send(request)
        await recorder.record(response)
        return response
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        do {
            return try await underlying.stream(request)
        } catch {
            if let transportError = error as? HTTPTransportError {
                switch transportError {
                case .httpStatus(let response), .errorBodyTimeout(let response, _):
                    await recorder.record(response)
                default:
                    break
                }
            }
            throw error
        }
    }
}
#endif
