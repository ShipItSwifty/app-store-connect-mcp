import Foundation
import Testing

@testable import AppStoreConnectKit

/// Exercises the public memberwise initializers of the wire models. `ModelCodableTests`
/// covers the synthesized `Codable` path; these cover the hand-written `init`s that
/// callers (and `ASCResponse` construction in tests/tools) actually use.
@Suite("Model initializers")
struct ModelInitTests {
    @Test("App / Build / BetaGroup / BetaTester initializers populate attributes")
    func appModels() {
        let app = ASCApp(id: "a", attributes: .init(bundleId: "com.x", name: "X", primaryLocale: "en-US", isOrEverWasMadeForKids: false))
        #expect(app.attributes?.bundleId == "com.x")

        let build = ASCBuild(
            id: "b", attributes: .init(version: "42", processingState: "VALID", expired: false, uploadedDate: "2026-01-01"))
        #expect(build.attributes?.version == "42")

        let group = ASCBetaGroup(
            id: "g",
            attributes: .init(name: "QA", publicLink: "https://testflight.apple.com/join/abc", isInternalGroup: true))
        #expect(group.attributes?.name == "QA")
        #expect(group.attributes?.publicLink == "https://testflight.apple.com/join/abc")

        let tester = ASCBetaTester(id: "t", attributes: .init(firstName: "A", lastName: "B", email: "a@b.c", inviteType: "EMAIL"))
        #expect(tester.attributes?.email == "a@b.c")
    }

    @Test("App Store / TestFlight read-model initializers populate attributes")
    func appStoreModels() {
        let version = ASCAppStoreVersion(
            id: "v1",
            attributes: .init(
                versionString: "1.4.0",
                platform: "IOS",
                appVersionState: "REJECTED",
                releaseType: "AFTER_APPROVAL",
                earliestReleaseDate: nil,
                downloadable: false,
                copyright: "2026 Example",
                createdDate: "2026-01-01"
            )
        )
        #expect(version.state == "REJECTED")

        // The legacy field is the fallback, not the preference.
        let legacy = ASCAppStoreVersion(id: "v0", attributes: .init(appStoreState: "READY_FOR_SALE"))
        #expect(legacy.state == "READY_FOR_SALE")
        #expect(ASCAppStoreVersion(id: "v-").state == nil)

        let localization = ASCAppStoreVersionLocalization(
            id: "l1",
            attributes: .init(
                locale: "en-US",
                description: "d",
                keywords: "k",
                whatsNew: "n",
                promotionalText: "p",
                marketingUrl: "https://example.com",
                supportUrl: "https://example.com/support"
            )
        )
        #expect(localization.attributes?.whatsNew == "n")

        let betaDetail = ASCBuildBetaDetail(
            id: "d1",
            attributes: .init(
                internalBuildState: "READY_FOR_TESTING",
                externalBuildState: "IN_BETA_REVIEW",
                autoNotifyEnabled: true
            )
        )
        #expect(betaDetail.attributes?.externalBuildState == "IN_BETA_REVIEW")

        let whatToTest = ASCBetaBuildLocalization(id: "bl1", attributes: .init(locale: "en-US", whatsNew: "Try login"))
        #expect(whatToTest.attributes?.whatsNew == "Try login")

        let review = ASCCustomerReview(
            id: "r1",
            attributes: .init(
                rating: 2,
                title: "Meh",
                body: "Slow",
                reviewerNickname: "someone",
                territory: "USA",
                createdDate: "2026-01-01"
            )
        )
        #expect(review.attributes?.rating == 2)

        let feedback = ASCBetaFeedback(
            id: "f1",
            attributes: .init(
                comment: "Crashes",
                email: "a@b.c",
                createdDate: "2026-01-01",
                deviceModel: "iPhone14,3",
                osVersion: "18.2",
                locale: "en-US",
                timeZone: "America/New_York",
                appPlatform: "IOS",
                devicePlatform: "IOS",
                deviceFamily: "IPHONE",
                architecture: "arm64e",
                buildBundleId: "com.example.app",
                appUptimeInMilliseconds: 1200,
                batteryPercentage: 42,
                diskBytesAvailable: 1024,
                diskBytesTotal: 4096,
                connectionType: "WIFI",
                screenshots: [.init(url: "https://example.com/a.png", fileName: "a.png", fileSize: 9)]
            )
        )
        #expect(feedback.attributes?.screenshots?.first?.fileName == "a.png")
        #expect(feedback.attributes?.batteryPercentage == 42)
    }

    @Test("Response envelopes and pagination links initialize")
    func envelopes() {
        let links = PagedLinks(self: "s", next: "n", first: "f")
        let list = ASCListResponse<ASCApp>(data: [ASCApp(id: "a")], links: links)
        #expect(list.links?.next == "n")
        #expect(list.data.count == 1)

        let single = ASCResponse<ASCApp>(data: ASCApp(id: "a"))
        #expect(single.data.id == "a")
    }

    @Test("CI models initialize with nested attribute types")
    func ciModels() {
        let product = CIProduct(id: "p", attributes: .init(name: "App", productType: "APP", createdDate: "2026-01-01"))
        #expect(product.attributes?.productType == "APP")

        let workflow = CIWorkflow(
            id: "w",
            attributes: .init(name: "Build", description: "d", isEnabled: true, isLockedForEditing: false, lastModifiedDate: "x")
        )
        #expect(workflow.attributes?.isEnabled == true)

        let commit = CIBuildRun.Attributes.SourceCommit(commitSha: "abc", message: "m", webUrl: "http://x")
        let run = CIBuildRun(
            id: "r", attributes: .init(number: 1, completionStatus: "FAILED", sourceCommit: commit, isPullRequestBuild: true))
        #expect(run.attributes?.sourceCommit?.commitSha == "abc")

        let counts = CIBuildAction.Attributes.IssueCounts(analyzerWarnings: 1, errors: 2, testFailures: 3, warnings: 4)
        let action = CIBuildAction(
            id: "act", attributes: .init(name: "Build", actionType: "BUILD", completionStatus: "FAILED", issueCounts: counts))
        #expect(action.attributes?.issueCounts?.testFailures == 3)

        let fileSource = CIIssue.Attributes.FileSource(path: "F.swift", lineNumber: 9)
        let issue = CIIssue(id: "i", attributes: .init(issueType: "ERROR", message: "boom", fileSource: fileSource, category: "COMPILER"))
        #expect(issue.attributes?.fileSource?.lineNumber == 9)

        let dest = CITestResult.Attributes.DestinationTestResult(deviceName: "iPhone", osVersion: "17", status: "FAILURE", duration: 1.5)
        let test = CITestResult(
            id: "t", attributes: .init(className: "C", name: "n", status: "FAILURE", fileSource: fileSource, destinationTestResults: [dest])
        )
        #expect(test.attributes?.destinationTestResults?.first?.deviceName == "iPhone")

        let artifact = CIArtifact(id: "ar", attributes: .init(fileType: "LOG", fileName: "l.log", fileSize: 10, downloadUrl: "http://x"))
        #expect(artifact.attributes?.fileSize == 10)
    }

    @Test("NoContentResponse initializes")
    func noContent() {
        _ = NoContentResponse()
    }
}
