# MCP tools and prompts

## Tools

**Xcode Cloud**

| Tool | Arguments | Returns |
|---|---|---|
| `asc_ci_list_products` | `app_id?` | Xcode Cloud products |
| `asc_ci_list_workflows` | `product_id` | workflows for a product |
| `asc_ci_list_build_runs` | `workflow_id`, `limit?`, `failed_only?` | recent build runs, newest first; `failed_only` over-fetches and returns only `FAILED`/`ERRORED`/`INVALID` runs |
| `asc_ci_list_test_plans` | `workflow_id` | the test plans the workflow runs, flattened from its `TEST` actions (scheme, selection kind, test-plan names) |
| `asc_ci_get_build_run` | `build_run_id` | the run + its actions with issue counts, plus `durationSeconds` for the run and each action |
| `asc_ci_get_issues` | `build_action_id` | errors / warnings / analyzer findings (file + line) |
| `asc_ci_get_test_results` | `build_action_id` | test results |
| `asc_ci_get_artifacts` | `build_action_id` | log bundle / xcresult / product download URLs |
| `asc_ci_failure_report` | `build_run_id`, `workflow_name?` | **one aggregated payload**: every failed action's issues, failed tests, and artifacts, with run + action `durationSeconds` (a value near Xcode Cloud's 120-minute ceiling means a timeout) |
| `asc_ci_failure_report_with_logs` | `build_run_id`, `workflow_name?` | `asc_ci_failure_report` plus each failed action's **text logs downloaded and parsed** into structured findings (compiler / linker / code-signing errors, test failures, with file + line). Zipped `LOG_BUNDLE` artifacts are expanded in-process so custom CI-script output (`ci_post_xcodebuild.sh`, …) is parsed too; genuinely binary artifacts (`xcresult`) are listed under `skippedArtifacts` |
| `asc_ci_latest_failure` | `app_id?` / `product_id?` / `workflow_id?` (one required) | **triage shortcut**: resolves the scope, finds the most recent failed build run, and returns its `asc_ci_failure_report` payload plus the chosen `workflow` + `build_run_id`. Collapses the products → workflows → build runs → run → issues walk into one call; returns `{"found": false}` when nothing has failed |
| `asc_ci_analyze_log` | `text?` **or** `download_url?` | parse raw CI log text (or a downloaded text artifact / zipped log bundle) into structured findings by kind |
| `asc_submission_status` | `bundle_id` | diagnose where the latest App Store version stands in review: version state (`REJECTED`, `METADATA_REJECTED`, `INVALID_BINARY`, `WAITING_FOR_REVIEW`, …), review-submission state, per-item outcomes, whether the developer must act, and a plain-language next step |

**App Store & TestFlight**

| Tool | Arguments | Returns |
|---|---|---|
| `asc_list_apps` | `bundle_id?`, `name?`, `limit?` | the apps this key can see, with app id, bundle id, name, SKU, primary locale — **the discovery entry point**: every other app tool needs an id |
| `asc_list_app_store_versions` | `app_id?` / `bundle_id?`, `platform?`, `limit?` | App Store versions newest first: version string, platform, review state, release type |
| `asc_get_version_metadata` | `version_id`, `limit?` | per-locale store listing text: description, keywords, what's new, promotional text, URLs |
| `asc_list_builds` | `app_id?` / `bundle_id?`, `version?`, `pre_release_version?`, `processing_state?`, `limit?` | uploaded builds newest first: processing state, upload/expiry dates, minimum OS, `buildAudienceType`, export-compliance answer |
| `asc_testflight_build_status` | `app_id?` / `bundle_id?`, `version?` | why a build is (or isn't) available to testers: the build plus its internal/external beta states and per-locale "What to Test" notes, in one call |
| `asc_list_beta_groups` | `app_id?` / `bundle_id?`, `limit?` | TestFlight groups: internal vs external, public link + cap, feedback enabled, auto-add-builds |
| `asc_list_beta_testers` | `beta_group_id`, `limit?` | testers in a group, with invite type and state |
| `asc_list_beta_feedback` | `app_id?` / `bundle_id?`, `kind?` (`crash` \| `screenshot`), `build_id?`, `device_model?`, `os_version?`, `limit?` | TestFlight tester feedback newest first — crash submissions with device state, or screenshots with the tester's comment and image URLs |
| `asc_list_customer_reviews` | `app_id?` / `bundle_id?`, `rating?`, `territory?`, `limit?` | App Store reviews newest first, filterable by star rating and storefront |
| `asc_list_diagnostic_signatures` | `build_id?` / `app_id?` / `bundle_id?`, `diagnostic_type?` (`HANGS` \| `LAUNCHES` \| `DISK_WRITES`), `limit?` | hang, slow-launch and disk-write signatures real devices reported against a build (crashes come from TestFlight feedback, below), with `weight` and a regression insight (falls back to the app's newest build) |
| `asc_get_diagnostic_logs` | `signature_id`, `limit?`, `max_frames?` | the call stacks behind a signature, **reduced to the frames Apple blames** — symbol, binary, file + line where symbolicated — with each report's app/OS version and device. `totalFrames` says how much was elided |
| `asc_get_beta_crash_log` | `feedback_id` | the symbolicated crash log attached to a TestFlight crash submission; `{"available": false}` while Apple is still attaching it |
| `asc_perf_power_metrics` | `app_id?` / `bundle_id?`, `metric_type?`, `platform?`, `device_type?`, `raw?` | launch time, hang rate, memory, disk, battery from real devices: Apple's flagged regressions plus the newest measurement per percentile, with unit and goal band. `raw` returns the unreduced payload |
| `asc_phased_release_status` | `version_id?` / `app_id?` / `bundle_id?` | staged-rollout state, which day of Apple's fixed 7-day schedule it is on, and the share of users that reaches; `{"configured": false}` for an immediate release |
| `asc_review_details` | `app_id?` / `bundle_id?`, `version_id?` | what App Review and Beta App Review were told: contact, whether a demo account is required and its username, reviewer notes. Passwords are never returned |
| `asc_list_app_infos` | `app_id?` / `bundle_id?`, `limit?` | the app-level listing records and their state — reviewed separately from a version, so an app can be `METADATA_REJECTED` while the version looks fine — plus computed age ratings |
| `asc_signing_assets` | `within_days?`, `limit?` | certificates and profiles with expiry dates, flagging the expired, the soon-to-expire, and profiles Apple marked `INVALID`. The usual cause of "it signed last week and fails today" |
| `asc_list_analytics_reports` | `app_id?` / `bundle_id?`, `category?`, `limit?` | the analytics report requests configured for an app and the reports under them. An empty list means nobody has created a request yet |
| `asc_get_analytics_report` | `app_id?` / `bundle_id?`, `report_name?`, `category?`, `granularity?`, `processing_date?`, `max_rows?` | one report's data: walks request → report → newest instance → segment, inflates the gzipped CSV, and returns columns, capped rows, and the true row count |
| `asc_sales_report` | `report_date`, `vendor_number?`, `frequency?`, `report_type?`, `report_sub_type?`, `version?`, `max_rows?` | a Sales and Trends report as a bounded table. Vendor number comes from the argument or `$ASC_VENDOR_NUMBER`. **Needs a Finance/Sales-role key**, not the Team key the `ci*` tools want |
| `asc_rate_limit_status` | — | this key's hourly rate-limit position before you start a broad scan |
| `asc_api_get` | `path`, `query?` | **escape hatch**: any authenticated `GET` against `/v1/…` or `/v2/…`, returned verbatim — appInfos, prices, in-app purchases, subscriptions, users, devices, certificates, and anything Apple ships next. Read-only by construction; a `links.next` URL can be pasted straight back as `path` |

Every app-scoped tool accepts **either** `app_id` **or** `bundle_id` (the bundle id
costs one extra lookup). Every tool above is advertised with MCP's `readOnlyHint`, so
a host can auto-approve them instead of prompting once per lookup during an
investigation.

<a id="writes-opt-in"></a>
**Writes (opt-in)**

The tools above only read. The ones below change something in App Store Connect and
are advertised **only** when `ASC_ENABLE_WRITES=1` is set in the server's environment
— so a default deployment keeps a catalog that is read-only end to end, and an
operator opts in deliberately. Calling one while it is disabled returns a message
naming the variable rather than "unknown tool".

| Tool | Arguments | Does |
|---|---|---|
| `asc_ci_start_build` | `workflow_id`, `git_reference_id?`, `clean?` | starts a real Xcode Cloud build (consumes compute minutes) |
| `asc_ci_rerun_build` | `build_run_id`, `clean?` | re-runs a build run, reusing its workflow **and git reference**, so the retry builds the same commit |
| `asc_update_whats_new` | `bundle_id`, `locale`, `text` | sets the release notes for one locale on the latest version; fails once that version is in review |
| `asc_update_version_localization` | `bundle_id`, `locale`, `description?`, `keywords?`, `promotional_text?` | updates description/keywords/promotional text for one locale on the latest version — only the fields passed are changed. `description`/`keywords` lock once the version is in review; `promotional_text` stays editable on a `READY_FOR_SALE` version |
| `asc_update_app_info_localization` | `bundle_id`, `locale`, `name?`, `subtitle?` | updates the app name/subtitle for one locale at the app-info level — app-wide, not version-scoped, so it isn't blocked by review state |
| `asc_submit_for_review` | `bundle_id`, `version_string?`, `automatic_release?`, `phased_release?` | **submits the app to App Review** — irreversible and public |
| `asc_create_analytics_report_request` | `app_id?` / `bundle_id?`, `access_type?` | creates the analytics report request that makes `asc_get_analytics_report` return anything |

The server does no analysis of its own beyond normalization (`CIFailureReport`, `CILatestFailure`, `CILogParser`, `AppStoreSubmissionService`) — the calling agent reasons over the data. When a response leaves the App Store Connect hourly rate limit within 10 points of its throttle threshold, an extra text block is appended warning that further calls may stall.

Each tool is one `ToolSpec` that carries both its JSON Schema and its handler, so the
advertised catalog and the dispatcher cannot drift apart; adding a tool means adding
one spec to the relevant list (`CITools`, `AppStoreTools`, `DiagnosticsTools`,
`ReviewTools`, `ReportingTools`, or `WriteTools`), which `CITools.specs` concatenates.

**A note on "failed":** `failed_only` and `asc_ci_latest_failure` treat a *run* as
failed when its `completionStatus` is `FAILED`, `ERRORED`, or `INVALID` — a run
someone canceled by hand is not a red build. The failure reports additionally collect
`CANCELED` *actions*, because Xcode Cloud cancels an action's siblings when one
breaks and those still carry the issues that explain it.

## Prompts

Each prompt expands to a step-by-step plan naming the tools to call and how to read
their output. They reference read-only tools only.

| Prompt | Arguments | Walks through |
|---|---|---|
| `triage_ci_failure` | `bundle_id?` / `app_id?` / `build_run_id?` | latest failed Xcode Cloud run → parsed logs → root cause with file:line, timeout and signing checks |
| `diagnose_review` | `bundle_id` | submission status → app-info / review-detail / metadata checks → next step |
| `testflight_availability` | `bundle_id`, `version?` | build processing, export compliance, beta review, group setup — internal vs external |
| `investigate_crashes` | `bundle_id`, `build_id?` | TestFlight crash logs, then hang / launch / disk-write signatures and their stacks |
| `release_health` | `bundle_id` | versions, review, phased rollout, builds, signing expiry, recent reviews → one table |

### Claude Code skill

[`skills/app-store-connect/SKILL.md`](../skills/app-store-connect/SKILL.md) is a richer
version of the same playbooks for Claude Code, including what 401 / 403 mean and when
to stop drilling. `scripts/install-mcp.sh` offers to install it; by hand:

```bash
mkdir -p ~/.claude/skills/app-store-connect
cp skills/app-store-connect/SKILL.md ~/.claude/skills/app-store-connect/
```

Or copy it into a project's `.claude/skills/` to share it with the team.

