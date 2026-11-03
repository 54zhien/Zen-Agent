import Foundation

enum GLMChatCompletionStream {
    static func events(
        from upstream: HTTPStream,
        timeouts: StreamTimeoutPolicy,
        redacting secret: SecretValue
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let progress = StreamProgress()

        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in upstream.cancel() }

            Task {
                await StreamDeadline.run(
                    progress: progress,
                    first: timeouts.firstEvent,
                    subsequent: timeouts.betweenEvents,
                    checkInterval: timeouts.checkInterval,
                    onTimeout: { elapsed in
                        continuation.finish(throwing: ProviderError.streamProgressTimeout(
                            phase: elapsed.hadAdvanced ? .betweenEvents : .awaitingFirstEvent,
                            after: elapsed.after
                        ))
                    },
                    reading: {
                        var parser = SSEParser()
                        var decoder = GLMChatCompletionStreamDecoder()
                        do {
                            for try await chunk in upstream.body {
                                for element in try parser.consume(chunk) {
                                    switch element {
                                    case .done:
                                        for event in try decoder.finish() {
                                            continuation.yield(event)
                                        }
                                        continuation.finish()
                                        return
                                    case .event(let event):
                                        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !payload.isEmpty else { continue }
                                        let output = try decoder.consume(payload)
                                        if output.madeProgress { progress.advanced() }
                                        for event in output.events {
                                            continuation.yield(event)
                                        }
                                    }
                                }
                            }
                            try parser.finish()
                            for event in try decoder.finish() {
                                continuation.yield(event)
                            }
                            continuation.finish()
                        } catch let error as SSEParserError {
                            continuation.finish(throwing: GLMProvider.providerError(
                                from: error,
                                deliveredOutput: progress.hasAdvanced,
                                redacting: secret
                            ))
                        } catch {
                            continuation.finish(throwing: GLMProvider.providerError(
                                from: error,
                                deliveredOutput: progress.hasAdvanced,
                                redacting: secret
                            ))
                        }
                    }
                )
            }
        }
    }
}