# ``AppStoreConnectUploadKit``

Upload signed IPA files to App Store Connect on macOS and resolve their build IDs.

## Overview

Add `.product(name: "AppStoreConnectUploadKit", package: "app-store-connect-mcp")`
alongside the core library in your target. This library requires macOS 15 or later,
Swift 6.3 or later, and an Xcode installation providing `xcrun altool` and
`PlistBuddy`. Supply an exported, signed IPA and API credentials permitted to upload
the app's builds.

```swift
import AppStoreConnectKit
import AppStoreConnectUploadKit
import Foundation
import SwiftyShell

let credentials = ASCCredentials(keyID: "KEY_ID", issuerID: "ISSUER_ID", privateKeyPEM: pem)
let client = AppStoreConnectClient(credentials: credentials)
let service = IPAUploadService(client: client)
let result = try await service.uploadIPA(
    at: URL(fileURLWithPath: "/path/to/App.ipa"),
    bundleID: "com.example.app",
    credentials: credentials,
    shell: ShellContext()
)
print(result.buildID as Any)
```

The shell argument uses SwiftyShell. If your code imports it directly, also declare
SwiftyShell as a direct package dependency and add its library product to your target.

### Private key lifecycle

For `altool`, the service stages the key at
`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, using a 0700 directory and
a 0600 file. It removes a key it created when the upload method exits, including
normal error paths. An existing key is left untouched and used by `altool`; ensure
it matches the supplied credentials. Process termination can prevent cleanup.
The shell's `HOME` environment value determines the staging home when supplied.

### Build visibility

After upload, the service reads `CFBundleVersion` from the IPA and polls for the
build in App Store Connect. Defaults are ten attempts with fifteen seconds
between attempts. Configure these through ``IPAUploadService/init(client:pollMaxAttempts:pollDelaySeconds:)``.
A returned build ID indicates API visibility, not completed processing or
TestFlight availability.

An upload may have succeeded even if later build lookup times out. Check App
Store Connect before uploading again. Pass `resolveBuildID: false` when you only
need the upload step; the returned app and build IDs are then nil.

## Topics

### Upload orchestration

- ``IPAUploadService``
- ``IPAUploadService/Result``
