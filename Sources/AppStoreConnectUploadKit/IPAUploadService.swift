#if os(macOS)
import AppStoreConnectKit
import Foundation
import Logging
import SwiftyShell

/// Coordinates uploading an IPA to App Store Connect / TestFlight.
///
/// Uses `xcrun altool --upload-app` (the standard Apple CLI tool) to upload the
/// binary, then resolves the resulting build id from the ASC REST API. The
/// `/v1/builds` REST endpoint does not support `CREATE`; all actual IPA uploads
/// must go through altool / Transporter.
///
/// **Key file placement:** `altool --apiKey` looks for the p8 key at
/// `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`. If the key isn't
/// already there, this service writes it for the duration of the upload and
/// removes it on completion.
///
/// This type is macOS-only because it shells out to `xcrun altool`.
public struct IPAUploadService: Sendable {
    private let client: AppStoreConnectClient
    private let pollMaxAttempts: Int
    private let pollDelaySeconds: UInt64
    private let logger = Logger(label: "AppStoreConnectUploadKit.IPAUploadService")

    /// Creates an `IPAUploadService` bound to an ASC client.
    ///
    /// - Parameters:
    ///   - client: The ASC client used for app and build lookups.
    ///   - pollMaxAttempts: Maximum number of times to poll ASC for the build after upload. Default: 10.
    ///   - pollDelaySeconds: Seconds between poll attempts. Default: 15.
    public init(
        client: AppStoreConnectClient,
        pollMaxAttempts: Int = 10,
        pollDelaySeconds: UInt64 = 15
    ) {
        self.client = client
        self.pollMaxAttempts = pollMaxAttempts
        self.pollDelaySeconds = pollDelaySeconds
    }

    /// Result of a completed IPA upload.
    public struct Result: Codable, Sendable {
        /// The App Store Connect app id the IPA was uploaded to, if resolved.
        public let appID: String?
        /// The build id assigned by App Store Connect, if resolved.
        public let buildID: String?
        /// The original IPA file name.
        public let fileName: String

        /// Creates an `IPAUploadService.Result`.
        public init(appID: String? = nil, buildID: String? = nil, fileName: String) {
            self.appID = appID
            self.buildID = buildID
            self.fileName = fileName
        }
    }

    /// Uploads an IPA file for the given bundle identifier.
    ///
    /// - Parameters:
    ///   - ipaURL: Local path to the IPA file.
    ///   - bundleID: App bundle identifier used to resolve the ASC app.
    ///   - credentials: App Store Connect API credentials for `altool`.
    ///   - shell: Shell context used to run `unzip`, `plutil`, and `xcrun altool`.
    ///   - resolveBuildID: Whether to resolve the uploaded build id from ASC after `altool` succeeds.
    /// - Returns: The uploaded build metadata.
    public func uploadIPA(
        at ipaURL: URL,
        bundleID: String,
        credentials: ASCCredentials,
        shell: ShellContext,
        resolveBuildID: Bool = true
    ) async throws -> Result {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw ASCError.uploadFailed(
                asset: ipaURL.lastPathComponent,
                reason: "IPA file not found at: \(ipaURL.path)"
            )
        }

        let keyID = credentials.keyID
        let issuerID = credentials.issuerID
        let keyData = credentials.privateKeyData

        logger.info("Uploading IPA '\(ipaURL.lastPathComponent)' for bundle ID '\(bundleID)'")

        // altool looks for the p8 key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
        // Stage it there if it isn't already present. The key grants full ASC API
        // access for the team, so restrict it to the owning user (0700 dir, 0600 file).
        let keyDir = shell.homeDirectory
            .appendingPathComponent(".appstoreconnect/private_keys", isDirectory: true)
        try FileManager.default.createDirectory(
            at: keyDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let standardKeyPath = keyDir.appendingPathComponent("AuthKey_\(keyID).p8")
        let wroteKey = !FileManager.default.fileExists(atPath: standardKeyPath.path)
        if wroteKey {
            logger.debug("Writing p8 key to standard altool location: \(standardKeyPath.path)")
            try keyData.write(to: standardKeyPath, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: standardKeyPath.path
            )
        }
        defer {
            if wroteKey {
                logger.debug("Removing staged p8 key from altool location")
                try? FileManager.default.removeItem(at: standardKeyPath)
            }
        }

        logger.info("Running xcrun altool --upload-app")
        do {
            _ = try await Altool(context: shell)
                .uploadApp(ipaPath: ipaURL.path, platform: "ios", apiKey: keyID, apiIssuer: issuerID)
                .run()
        } catch ShellError.exitFailure(_, let shellOutput) {
            let detail = shellOutput.stderr.isEmpty ? shellOutput.stdout : shellOutput.stderr
            throw ASCError.uploadFailed(
                asset: ipaURL.lastPathComponent,
                reason: "altool upload failed (exit \(shellOutput.exitCode)): \(detail)"
            )
        }

        if !resolveBuildID {
            logger.info("altool upload completed; skipping App Store Connect build lookup")
            return Result(fileName: ipaURL.lastPathComponent)
        }

        logger.info("altool upload completed, locating build in App Store Connect")

        let apps: ASCListResponse<ASCApp> = try await client.get(
            "/v1/apps",
            query: ["filter[bundleId]": bundleID]
        )
        guard let app = apps.data.first else {
            throw ASCError.apiError(
                statusCode: 404,
                body: "App with bundle ID '\(bundleID)' not found in App Store Connect"
            )
        }

        let buildVersion = try await extractBuildVersion(from: ipaURL, shell: shell)
        logger.info("Looking for build version '\(buildVersion)' in App Store Connect (app: \(app.id))")

        let buildID = try await pollForBuild(
            appID: app.id,
            buildVersion: buildVersion,
            maxAttempts: pollMaxAttempts,
            delaySeconds: pollDelaySeconds
        )

        logger.info("Completed IPA upload for build '\(buildID)'")
        return Result(appID: app.id, buildID: buildID, fileName: ipaURL.lastPathComponent)
    }

    // MARK: - Private Helpers

    /// Extracts `CFBundleVersion` from an IPA's embedded `Info.plist` by piping
    /// `unzip -p` into `plutil` through SwiftyShell without shell parsing.
    private func extractBuildVersion(from ipaURL: URL, shell: ShellContext) async throws -> String {
        logger.debug("Extracting CFBundleVersion from IPA")
        do {
            let output = try await Command("unzip")
                .args(["-p", ipaURL.path, "Payload/*.app/Info.plist"])
                .pipe(
                    to: Command("plutil")
                        .args(["-extract", "CFBundleVersion", "raw", "-o", "-", "-"])
                )
                .run(in: shell)
            let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty else {
                throw ASCError.uploadFailed(
                    asset: ipaURL.lastPathComponent,
                    reason: "CFBundleVersion is empty in IPA Info.plist"
                )
            }
            logger.debug("Extracted CFBundleVersion from IPA")
            return version
        } catch ShellError.exitFailure(_, let shellOutput) {
            logger.error("Failed to extract CFBundleVersion from IPA")
            throw ASCError.uploadFailed(
                asset: ipaURL.lastPathComponent,
                reason:
                    "Could not extract CFBundleVersion from IPA (exit \(shellOutput.exitCode)): \(shellOutput.stderr)"
            )
        }
    }

    /// Polls the ASC API until the uploaded build appears, then returns its id.
    private func pollForBuild(
        appID: String,
        buildVersion: String,
        maxAttempts: Int,
        delaySeconds: UInt64
    ) async throws -> String {
        for attempt in 1...maxAttempts {
            logger.debug("Checking for build version '\(buildVersion)' (attempt \(attempt)/\(maxAttempts))")

            let builds: ASCListResponse<ASCBuild> = try await client.get(
                "/v1/builds",
                query: [
                    "filter[app]": appID,
                    "filter[version]": buildVersion,
                    "sort": "-uploadedDate",
                    "limit": "1",
                ]
            )

            if let build = builds.data.first {
                logger.info("Found build '\(build.id)' for version '\(buildVersion)'")
                return build.id
            }

            if attempt < maxAttempts {
                logger.debug("Build not yet visible in ASC, waiting \(delaySeconds)s…")
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }

        throw ASCError.uploadFailed(
            asset: buildVersion,
            reason:
                "Build version '\(buildVersion)' not found in App Store Connect after \(maxAttempts) attempts (\(maxAttempts * Int(delaySeconds))s)"
        )
    }
}

extension ShellContext {
    fileprivate var homeDirectory: URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
#endif
