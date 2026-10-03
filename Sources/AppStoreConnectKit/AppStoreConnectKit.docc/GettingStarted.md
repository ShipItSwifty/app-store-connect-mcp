# Configure credentials and requests

Create a client from an App Store Connect API key and choose how requests retry.

## Overview

Add the library product to your Swift package:

```swift
.package(url: "https://github.com/ShipItSwifty/app-store-connect-mcp.git", from: "0.2.1")
```

Your target needs `.product(name: "AppStoreConnectKit", package: "app-store-connect-mcp")`.
The package requires Swift 6.3 or later and supports macOS 15 or later and Linux.

Set `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY_PATH` to the matching `.p8`
file. Alternatively, provide the PEM contents through `ASC_PRIVATE_KEY`.
When both are set, the PEM value takes precedence.

```swift
import AppStoreConnectKit

guard let credentials = ASCCredentials.fromEnvironment() else {
    fatalError("Set the API key ID, issuer ID, and private key.")
}
let client = AppStoreConnectClient(credentials: credentials)
let apps = try await client.apps(limit: 20)
```

Missing values or an unreadable key file make ``ASCCredentials/fromEnvironment(_:)``
return `nil`. Invalid key contents fail when the client first signs a request.
Use a Team key with Developer, App Manager, or Admin access for Xcode Cloud.
Reporting access depends on the endpoint and the key's role.

### Retries and pagination

The client retries throttled requests (`429`) and transient server failures on
`GET`. It does not replay writes after `5xx` responses because Apple may already
have applied them. To disable transient retries:

```swift
let client = AppStoreConnectClient(credentials: credentials, retryPolicy: .disabled)
```

``RateLimiter`` separately delays requests when the hourly quota is nearly used;
disabling transient retries does not disable this throttling.

Typed list methods collect pages up to their `limit`. A non-nil `links.next` means
more resources exist. Generic `get` retrieves one page; `getAll` walks pages.
Use `getRaw` to retrieve payloads without a typed model.
