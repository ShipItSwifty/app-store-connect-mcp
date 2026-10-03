# Privacy policy

Last updated: October 3, 2026

This policy covers the `app-store-connect-mcp` server and the App Store Connect plugin for
Claude Code. They are published by ShipItSwifty and owned by Arjang Consulting LLC.

## Summary

The software runs on your machine. We operate no server, receive no data from it, and include
no telemetry, analytics, or crash reporting. We cannot see your credentials, apps, builds,
testers, or reports.

## What the software does with your data

- **Credentials.** It reads the key ID, issuer ID, and the `.p8` private key file you select
  (or the equivalent `ASC_*` environment variables) only on your machine. It signs short-lived
  tokens locally. The private key and tokens are held in process memory and are not written to
  disk by the server.
- **App Store Connect data.** It sends authenticated requests to
  `https://api.appstoreconnect.apple.com` and returns the results to the Claude session that
  called the tool. Depending on the tool, this can include app, build, and Xcode Cloud run
  details; build logs and test results; TestFlight testers and feedback (which can include
  names, email addresses, and comments); crash and performance diagnostics; customer reviews;
  and sales and analytics reports.
- **Artifact downloads.** Some tools fetch signed download URLs that Apple returns, such as
  Xcode Cloud logs, to analyze their text. Those URLs are not included in summaries.
- **Writes.** Write tools are off unless you enable them. When enabled, they can start builds,
  change release metadata, submit a version for review, and request analytics reports.
- **Storage.** The server creates no database and does not persist App Store Connect data or
  credentials. Standard error may contain operational logs, such as resource identifiers and
  rate-limit status; they do not include credentials or report contents.

## Third parties

- **Apple** processes the requests above under your agreement with Apple and its
  [privacy policy](https://www.apple.com/legal/privacy/).
- **Anthropic.** Tool results are returned to your Claude session. Anthropic's handling of that
  conversation content follows your Claude account's settings and
  [privacy policy](https://www.anthropic.com/legal/privacy).

We do not sell, share, or receive your data.

## Your choices

Remove the key file or disable the plugin to stop all access. Revoke the API key in App Store
Connect to cut off Apple's side. Use a key with the least access you need, since the data
returned depends on the key's role.

## Changes and contact

Changes are published in this repository with a new date. Questions or requests:
[GitHub issues](https://github.com/ShipItSwifty/app-store-connect-mcp/issues).
