# GPT Cloud Build contract

This workflow is separate from the main release pipeline. It runs only for
pushes to `gpt/**` branches; it never publishes a Release, moves
a tag, accesses private build hosts, uses signing keys, or sends Bark messages.

## Commands

- `bash scripts/gpt-cloud-build.sh source`: exact source inventory,
  source-gate mutation regression, SwiftUI checks, release-automation unit tests.
- `bash scripts/gpt-cloud-build.sh offline`: all offline Swift suites on Linux.
- `bash scripts/gpt-cloud-build.sh ipa`: compile and validate an unsigned
  iPhoneOS arm64 IPA on macOS with Xcode and XcodeGen.

Every command refuses a non-GPT branch. GitHub execution additionally requires
an exact `GITHUB_SHA` checkout and a push event from this repository.
IPA compilation requires a clean committed tree. The source and offline jobs
run in parallel; the macOS IPA job runs only if both pass.

The candidate artifact contains the IPA, build-info.json, validation.json, and
SHA256SUMS.txt. Build logs are a separate artifact even after failure.
No DerivedData cache is shared or restored until measured to be safe and useful.

## Development / integration

1. Branch from the current main into a short-lived `gpt/<topic>` branch.
2. Make changes only on that branch; keep `com.whale7.hermes` and
   current identity, session, Keychain, scrolling, and attachment invariants.
3. Maintain the exact `tests/release-scope-build<build>.json` inventory
   whenever tracked files change. Update `release.json`, Info.plist and
   README together when preparing a new version, after agreeing on its identity.
4. Push the branch. Review source, offline and macOS IPA results and download the
   candidate from Actions; successful CI does not assert real-device acceptance.
5. Submit a pull request to main. After review and approval to publish, merge
   through the PR. The existing main workflow owns the official Release.

Note: a candidate that inherits main's version/build also inherits those app
metadata values. It is an inspection artifact, not a separately versioned update.
Do not mistake it for a new official Release.

The original `scripts/github-build-ipa.sh` remains the one compiler
implementation for both release and branch candidates. This wrapper does not
fork packaging, source validation or the IPA verifier.
