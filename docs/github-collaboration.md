# GitHub collaboration

Work from main on a short-lived feature branch and submit a pull request. Preserve the iOS client scope, existing instance identities, Keychain isolation and chat behavior. Do not commit generated outputs or local machine configuration.

The public workflow runs exact source checks and Swift offline regressions in parallel for pull requests and main. A main push that changes version/build (with increasing build and non-decreasing version) automatically builds once with Xcode 26.3, validates and publishes directly from the same macOS runner. Assets are downloaded and SHA256-checked while the Release is a draft, then the official Release and tag are verified again. No Actions Artifact relay is used. Published versions are immutable; only an owned draft from the same source/run can resume with identical bytes. Transient upload/API failures retry up to three times in the same job. A fresh job producing different bytes fails closed rather than mixing packages. GitHub determines Latest using legacy automatic commit-date/version ordering; publication does not force an older completion to Latest.

Maintenance pushes run checks only. workflow_dispatch is build-and-verify only, with no Release or retained Artifact. BARK_URL is an optional repository Secret used by a separate best-effort notification job. Package validation and device acceptance are separate from source tests.

Provide remote build targets and directory paths through local environment variables. Do not print machine identities, proxy URLs, tokens or notification keys in public logs. Update the current release scope only after reviewing the complete source change; preserve frozen baseline manifests and third-party notices.
