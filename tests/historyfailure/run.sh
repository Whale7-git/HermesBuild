#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
build=$(mktemp -d /tmp/hermes-historyfailure-tests-XXXXXXXX)
trap 'rm -rf "$build"' EXIT
s=Sources/HermesShell
swiftc -warnings-as-errors -swift-version 6 -parse-as-library \
  "$s/HistoryLoadFailure.swift" tests/historyfailure/main.swift -o "$build/test"
"$build/test"
