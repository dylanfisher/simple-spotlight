extension Result {
    /// `Result(catching:)` for an async body, which runs on the caller's actor.
    ///
    /// Closures the app stores return a `Result` rather than throwing a typed error: the
    /// metadata of a typed-throws function type needs the macOS 15 Swift runtime, and this
    /// branch runs on macOS 12 (docs/decisions/0016-macos-12-branch.md).
    public init(
        isolation: isolated (any Actor)? = #isolation,
        catching body: () async throws(Failure) -> Success
    ) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
