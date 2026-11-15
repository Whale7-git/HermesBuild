# GitHub collaboration — GPT development branches

The current GPT workflow is `.github/workflows/gpt-cloud-build.yml`. It runs on Push to `gpt/**`, checks source and Swift offline tests in parallel on Ubuntu, and builds/verifies a candidate unsigned IPA on a hosted macOS Runner. The verified package, checksum manifest, build metadata and logs are retained as Actions Artifacts. **No GitHub Release, tag, Bark notification, private Runner or SSH is used.**

Create `gpt/<topic>` from an existing GPT build baseline (currently `gpt/cloud-build-bootstrap`), **not from a bare main checkout without the GPT workflow**. Keep changes on that branch. Sync version metadata when needed, regenerate the exact source-scope manifest using `python3 tests/gen_release_scope.py`, push, and inspect all jobs and the exact resulting SHA. Keep signing and iPhone device acceptance separate from CI.

Do not run the SSH/xtool scripts as part of GPT development. Existing scripts and tests that mention a private build host are historical/manual tools. They are explicitly excluded from GPT's execution chain.

Other workflows under `.github/workflows/hermesshell-*.yml` serve the repository's independent official/manual release process; they have distinct triggers and are **not** the GPT Push entry point. Do not treat their publication mechanics or old README claims as instructions to invoke them for a GPT candidate.

Preserve Bundle ID `com.whale7.hermes`, per-instance Keychain data, session and attachment behavior. Never commit or print secrets or real user content. Use `docs/gpt-cloud-build.md` and `AGENTS.md` as the current GPT contracts.
