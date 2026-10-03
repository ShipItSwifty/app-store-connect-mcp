# Synchronize metadata and prepare a review submission

Pull localized listing text, edit it locally, and push changes to App Store Connect.

## Overview

``AppStoreReleaseService`` resolves an app by its bundle identifier. Pull metadata
before editing so you can review the existing listing:

```swift
let service = AppStoreReleaseService(client: client)
let pulled = try await service.pullMetadata(
    bundleID: "com.example.app", directory: "./metadata"
)
print(pulled.localesProcessed)
```

Each locale gets a directory containing `name.txt`, `subtitle.txt`,
`description.txt`, `keywords.txt`, `release_notes.txt`, and `promotional_text.txt`
when those values exist. Review the files before pushing: these operations change
the app's real store listing.

```swift
let pushed = try await service.pushMetadata(
    bundleID: "com.example.app", directory: "./metadata",
    resolveVersionString: { "1.4.0" }
)
print(pushed.appStoreVersionID as Any)
```

The version closure runs only when a new App Store version record is needed.
Apple restricts which version-localization fields can change once a version is
in review. A failed write may leave earlier writes applied; inspect the current
metadata before retrying a sequence.

### Submit and inspect review status

```swift
let submitted = try await service.submitForReview(
    bundleID: "com.example.app",
    automaticRelease: true,
    phasedRelease: false,
    resolveVersionString: { "1.4.0" }
)
print(submitted.reviewSubmissionID)
let status = try await AppStoreSubmissionService(client: client).status(bundleID: "com.example.app")
print(status)
```

Submission changes review state and release settings. Ensure the version has the
intended build and required metadata before calling it. Use
``AppStoreSubmissionService`` to inspect version and submission outcomes after
the call.
