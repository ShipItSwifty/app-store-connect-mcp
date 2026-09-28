---
name: app-store-connect
description: Investigate App Store Connect with the app-store-connect MCP server — failed Xcode Cloud builds, App Review rejections or stuck submissions, TestFlight builds testers can't see, crashes and hangs, signing expiry, and release health. Use when the user asks why a CI build failed, why a version was rejected or is stuck, why testers can't install a build, what is crashing in production, or for any App Store Connect / Xcode Cloud / TestFlight status question.
---

# App Store Connect investigations

The `app-store-connect` MCP server exposes App Store Connect as read-only tools named
`asc_*` (in Claude Code: `mcp__app-store-connect__asc_*`). The server normalizes Apple's
data; **you** do the reasoning. Aim for the fewest calls that answer the question —
every call spends the key's hourly rate limit.

## Before you start

- If no `asc_*` tools are available, the server isn't registered. Point the user at
  `scripts/install-mcp.sh` or the README's "Register with a client" section; don't
  improvise API calls with curl.
- A `403 FORBIDDEN` on `asc_ci_*` tools while app tools work means the key lacks an
  Xcode Cloud role — it needs a **Team key** with Developer, App Manager, or Admin.
  `asc_sales_report` is different: it needs Finance or Sales access (or Admin).
- A `401` usually means a wrong key id / issuer id pairing or an unreadable `.p8`.
- Every app-scoped tool takes `bundle_id` **or** `app_id`. Prefer `app_id` once you
  have it (the bundle id costs a lookup each call). `asc_ci_latest_failure` takes only
  `app_id`, so resolve with `asc_list_apps` first when you only have a bundle id.

## Playbooks

The server ships the same playbooks as MCP prompts (`triage_ci_failure`,
`diagnose_review`, `testflight_availability`, `investigate_crashes`, `release_health`),
so hosts without skills get them too. Follow these unless the user asks for something
narrower.

### "Why did CI fail?"

1. `asc_ci_latest_failure` (`app_id`, `product_id`, or `workflow_id`). `found: false`
   means nothing is red — say so and stop.
2. `asc_ci_failure_report_with_logs` on the returned `build_run_id` for parsed
   compiler / linker / signing / test findings with file and line.
3. Read, don't re-fetch. The report already holds every failed action's issues, failed
   tests, and artifact URLs. Only drop to `asc_ci_get_issues` / `asc_ci_get_test_results`
   for an action the report didn't cover.

Interpretation:
- The first error per file is usually the cause; the rest are cascades.
- `durationSeconds` near 7200 is Xcode Cloud's 120-minute timeout, not a code bug.
- Signing errors → `asc_signing_assets` for expired or `INVALID` certs/profiles.
- Tests missing or the wrong plan ran → `asc_ci_list_test_plans`.
- `CANCELED` actions in the report are siblings Xcode Cloud stopped when one broke;
  they still carry useful issues. A *run* canceled by hand is not a failure.
- `skippedArtifacts` (xcresult) can't be parsed here; mention them only if the logs are
  inconclusive.

### "Why is my version rejected / stuck in review?"

1. `asc_submission_status` with the bundle id — version state, submission state,
   per-item outcomes, and whether the developer must act.
2. If rejected: `asc_list_app_infos` (the app-level listing is reviewed separately and
   can be `METADATA_REJECTED` alone), `asc_review_details` (demo account, notes),
   `asc_get_version_metadata` (the listing text that was reviewed).
3. No build attached / can't submit: `asc_list_builds` — look for `processingState`
   ≠ `VALID`, `buildAudienceType: INTERNAL_ONLY`, or `usesNonExemptEncryption: null`
   (unanswered export compliance blocks submission).

Apple's rejection message itself lives in the Resolution Center and is not exposed by
the API — say so rather than inventing one.

### "Why can't testers see the build?"

1. `asc_testflight_build_status` (optionally `version` = build number).
2. `processingState` not `VALID`, or `usesNonExemptEncryption: null` → that's the
   blocker. External testers additionally need beta review (`WAITING_FOR_BETA_REVIEW`,
   `IN_BETA_REVIEW`, `REJECTED`).
3. `asc_list_beta_groups` for group setup (auto-add builds, public link); only then
   `asc_list_beta_testers` for a suspicious group.

Answer internal and external availability separately.

### "What's crashing or hanging?"

1. **Crashes** come from TestFlight: `asc_list_beta_feedback` with `kind: crash`, then
   `asc_get_beta_crash_log` for the most recent or most repeated submissions. Crash
   logs from App Store users are not in the API (Xcode Organizer only) — say so if
   that's what the user needs.
2. **Hangs, slow launches, excessive disk writes**: `asc_list_diagnostic_signatures`
   (`diagnostic_type`: `HANGS`, `LAUNCHES`, or `DISK_WRITES`; omit for all) — ranked by
   `weight`, with regression insights. Then `asc_get_diagnostic_logs` for the top two
   or three. Frames are already reduced to the ones Apple blames; symbolicated app
   frames with file:line are the lead.
3. `asc_perf_power_metrics` for launch / hang / memory regressions by release.

Say when stacks are unsymbolicated rather than guessing at a cause.

### Release health

`asc_list_app_store_versions` → `asc_submission_status` (if not live) →
`asc_phased_release_status` → `asc_list_builds` → `asc_signing_assets` →
`asc_list_customer_reviews`. Stop drilling into any area that's healthy. Summarize as a
table: area, status, action needed.

## Anything else

`asc_api_get` performs any `GET` under `/v1/` or `/v2/` and returns Apple's JSON
verbatim. Keep payloads small with `fields[<type>]`, `limit`, and `include`; paste a
`links.next` URL back as `path` to page. Check Apple's docs for attribute types rather
than guessing from the name.

## Rate limit

When a tool result carries a trailing "⚠️ App Store Connect API rate limit" block,
narrow your plan: prefer the aggregating tools, stop broad scans, and tell the user.
`asc_rate_limit_status` reports the position on demand.

## Writes

Write tools (`asc_ci_start_build`, `asc_ci_rerun_build`, `asc_update_whats_new`,
`asc_submit_for_review`, `asc_create_analytics_report_request`) exist only when the
server runs with `ASC_ENABLE_WRITES=1`. If a user asks for one and it's disabled, tell
them how to enable it — don't route around it with other tools. Always confirm with the
user before calling `asc_submit_for_review` (public and irreversible) or starting a
build (spends compute minutes).
