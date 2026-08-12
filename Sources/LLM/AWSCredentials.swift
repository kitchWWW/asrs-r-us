import Foundation

/// Temporary AWS credentials, resolved by asking the AWS CLI rather than
/// reimplementing its credential chain.
///
/// `aws configure export-credentials` understands every way the user might be
/// authenticated -- static keys, SSO, `aws login`, assumed roles -- and hands
/// back a resolved set. Shelling out costs ~200 ms, so the result is cached
/// until shortly before it expires.
struct AWSCredentials: Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
    var expiration: Date?

    /// Treated as expired a minute early, so a request is never signed with
    /// credentials that lapse in flight.
    var isValid: Bool {
        guard let expiration else { return true }
        return expiration.timeIntervalSinceNow > 60
    }
}

enum AWSCredentialError: LocalizedError {
    case cliNotFound
    case sessionExpired(profile: String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "The AWS CLI was not found. Install it, or switch the rewrite engine "
                 + "back to the local model."
        case let .sessionExpired(profile):
            return "Your AWS session for profile “\(profile)” has expired. "
                 + "Run `aws login --profile \(profile)` in a terminal."
        case let .failed(message):
            return "Could not get AWS credentials: \(message)"
        }
    }
}

/// Resolves and caches credentials for one named profile.
actor AWSCredentialProvider {
    private let profile: String
    private var cached: AWSCredentials?

    init(profile: String) {
        self.profile = profile
    }

    /// Where Homebrew and the official installer put the CLI. `Process` does
    /// not consult a login shell's PATH, so the locations are explicit.
    private static let searchPaths = [
        "/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws",
    ]

    func credentials() throws -> AWSCredentials {
        if let cached, cached.isValid { return cached }

        guard let tool = Self.searchPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw AWSCredentialError.cliNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["configure", "export-credentials",
                             "--profile", profile, "--format", "process"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            throw AWSCredentialError.failed(error.localizedDescription)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if errorText.localizedCaseInsensitiveContains("expired")
                || errorText.localizedCaseInsensitiveContains("login") {
                throw AWSCredentialError.sessionExpired(profile: profile)
            }
            throw AWSCredentialError.failed(errorText.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["AccessKeyId"] as? String,
              let secret = json["SecretAccessKey"] as? String
        else { throw AWSCredentialError.failed("unreadable output from `aws configure export-credentials`") }

        var expiration: Date?
        if let text = json["Expiration"] as? String {
            expiration = ISO8601DateFormatter().date(from: text)
                ?? ISO8601DateFormatter.withFractionalSeconds.date(from: text)
        }

        let resolved = AWSCredentials(accessKeyID: key, secretAccessKey: secret,
                                      sessionToken: json["SessionToken"] as? String,
                                      expiration: expiration)
        cached = resolved
        return resolved
    }

    /// Drops the cache so the next request re-resolves. Called after a 403,
    /// which is what an expired session looks like from the service side.
    func invalidate() { cached = nil }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
