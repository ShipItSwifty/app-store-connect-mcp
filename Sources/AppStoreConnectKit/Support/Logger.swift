import Logging

extension Logger {
    /// Creates a `Logger` labelled `"<subsystem>.<TypeName>"`.
    ///
    /// Internal helper so this package doesn't export a `Logger` extension that
    /// would collide with an identically-named one in a consuming module.
    ///
    /// - Parameters:
    ///   - subsystem: The subsystem identifier, e.g. `"AppStoreConnectKit"`.
    ///   - type: The type to use as the log category.
    static func forType<T>(subsystem: String, _ type: T.Type) -> Logger {
        Logger(label: "\(subsystem).\(String(describing: T.self))")
    }
}
