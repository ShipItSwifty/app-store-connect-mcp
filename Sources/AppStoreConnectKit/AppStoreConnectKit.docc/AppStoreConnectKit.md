# ``AppStoreConnectKit``

A Swift client for the App Store Connect API, including the Xcode Cloud (`ci*`)
resource family.

## Overview

``AppStoreConnectClient`` is an actor that owns the parts of talking to App Store
Connect that are easy to get wrong: minting and caching the ES256 JWT, backing off
before Apple's hourly rate limit throttles you, and walking paged list endpoints.
On top of its generic ``AppStoreConnectClient/get(_:query:)`` it exposes typed
helpers for the resources this package covers.

```swift
import AppStoreConnectKit

let client = AppStoreConnectClient(
    credentials: ASCCredentials(keyID: "…", issuerID: "…", privateKeyPEM: pem)
)

// What broke in the most recent red build for this app?
let latest = try await client.ciLatestFailureReport(appID: "1234567890")
```

### Credentials

``ASCCredentials`` wraps the key id, issuer id, and raw `.p8` contents, and can read
all three from the conventional environment variables via
``ASCCredentials/fromEnvironment(_:)``.

The API key needs a role that can read Xcode Cloud — a Team key with **Developer**,
**App Manager**, or **Admin** access. A key scoped only to Finance, Sales, Customer
Support, or Marketing gets `403 FORBIDDEN` on the `ci*` endpoints even though App
Store metadata calls succeed.

### Pagination

List endpoints return one page at a time. The typed helpers use
``AppStoreConnectClient/getAll(_:query:limit:)``, which follows `links.next` until
the collection is exhausted or `limit` resources have been collected. A non-nil
`links.next` on the returned envelope means `limit` cut the walk short.

## Topics

### Client and credentials

- ``AppStoreConnectClient``
- ``ASCCredentials``
- ``ASCError``
- ``JWTGenerator``
- ``RateLimiter``
- ``RateLimitStatus``

### Xcode Cloud diagnostics

- ``CIFailureReport``
- ``CIFailureReportWithLogs``
- ``CILatestFailure``
- ``CITestPlanSummary``
- ``CILogParser``
- ``CILogAnalysis``
- ``CILogFinding``

### App Store release and review

- ``AppStoreReleaseService``
- ``AppStoreSubmissionService``

### Wire models

- ``ASCResponse``
- ``ASCListResponse``
- ``PagedLinks``
- ``ASCApp``
- ``ASCBuild``
- ``CIProduct``
- ``CIWorkflow``
- ``CIBuildRun``
- ``CIBuildAction``
- ``CIIssue``
- ``CITestResult``
- ``CIArtifact``

### Supporting types

- ``RetryPolicy``
- ``UploadReservation``
- ``UploadOperation``
- ``UploadCommit``
- ``EmptyBodyResponse``
- ``NoContentResponse``
