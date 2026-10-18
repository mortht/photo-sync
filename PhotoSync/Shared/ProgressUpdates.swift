import PhotoSyncCore

/// Runs `operation`, delivering its progress callbacks to `apply` on the main
/// actor in order. An ordered stream is used because hopping each update onto
/// the main actor separately can reorder them.
@MainActor
func withProgressUpdates<Result: Sendable>(
    _ apply: @escaping @MainActor (TransferProgress) -> Void,
    operation: (_ report: @escaping @Sendable (TransferProgress) -> Void) async throws -> Result
) async throws -> Result {
    let (updates, continuation) = AsyncStream.makeStream(of: TransferProgress.self,
                                                         bufferingPolicy: .bufferingNewest(1))
    let consumer = Task { for await update in updates { apply(update) } }
    defer { continuation.finish() }
    do {
        let result = try await operation { continuation.yield($0) }
        continuation.finish()
        await consumer.value
        return result
    } catch {
        consumer.cancel()
        throw error
    }
}
