import AsyncOperations

/// Builds session summaries concurrently from a collection of inputs.
public enum SessionSummaryCollector {
    public static func collect<Item: Sendable>(
        _ items: [Item],
        build: @escaping @Sendable (Item) throws -> SessionSummary
    ) async -> [SessionSummary] {
        await items.asyncCompactMap(numberOfConcurrentTasks: 10) { item in
            try? build(item)
        }
    }
}
