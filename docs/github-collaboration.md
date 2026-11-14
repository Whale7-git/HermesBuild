# GitHub collaboration

Work from main on a short-lived feature branch and submit a pull request. Preserve the iOS client scope, existing instance identities, Keychain isolation and chat behavior. Do not commit generated outputs or local machine configuration.

The public workflow checks exact source hashes and runs offline Swift regressions for pull requests and main. An iPhoneOS IPA build is available through workflow_dispatch only; it uploads a verified unsigned Actions artifact without creating a Release. Package validation and device acceptance are separate from source tests.

Provide remote build targets and directory paths through local environment variables. Do not print machine identities, proxy URLs, tokens or notification keys in public logs. Update the current release scope only after reviewing the complete source change; preserve frozen baseline manifests and third-party notices.
