import Foundation

enum AnthropicMessagesStream {
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
                        var decoder = AnthropicMessagesStreamDecoder()
                        do {
                            for try await chunk in upstream.body {
                                for element in try parser.consume(chunk) {
                                    switch element {
                                    case .done:
                                        throw ProviderError.streamInterrupted(
                                            deliveredOutput: progress.hasAdvanced,
                                            reason: "the Anthropic Messages stream ended before message_stop"
                                        )

                                    case .event(let event):
                                        guard !event.data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                            continue
                                        }
                                        switch try decoder.consume(event) {
                                        case .ignored:
                                            continue

                                        case .output(let events, let madeProgress):
                                            if madeProgress { progress.advanced() }
                                            for event in events { continuation.yield(event) }

                                        case .completed(let usage, let finishReason):
                                            if let usage { continuation.yield(.usage(usage)) }
                                            continuation.yield(.finish(finishReason))
                                            continuation.finish()
                                            return

                                        case .failed(let code, let message):
                                            throw AnthropicProvider.eventFailure(
                                                code: code,
                                                message: message,
                                                deliveredOutput: progress.hasAdvanced,
                                                redacting: secret
                                            )
                                        }
                                    }
                                }
                            }
                            throw ProviderError.streamInterrupted(
                                deliveredOutput: progress.hasAdvanced,
                                reason: "the Anthropic Messages stream ended without message_stop"
                            )
                        } catch {
                            continuation.finish(throwing: AnthropicProvider.providerError(
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
