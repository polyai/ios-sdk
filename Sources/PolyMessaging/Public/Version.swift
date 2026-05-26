public extension PolyMessaging {
    /// The SDK's released version (SemVer).
    ///
    /// Single source of truth: the `User-Agent` header (`RestApi`) and the
    /// example connect-screen footers read this, and `release-please` bumps the
    /// literal below on each release — **do not edit it by hand**.
    static let version = "0.4.0" // x-release-please-version
}
