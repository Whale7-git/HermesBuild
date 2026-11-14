# Hermes iOS build: package the work tree, build it on the 9 host inside the
# ios-build container, then download and seal the artifacts.
#
# Configure HERMES_BUILD_TARGET and HERMES_BUILD_PROJECTS locally.
# No host, SSH account or storage location is shipped in the public source.
param(
    [string]$Target = $env:HERMES_BUILD_TARGET
)
$ErrorActionPreference = 'Stop'
if (-not $Target) { throw 'Set HERMES_BUILD_TARGET or pass -Target.' }
if ($Target -notmatch '^[A-Za-z0-9_.@:-]+$') { throw 'Invalid SSH target' }
$sshExecutable = (Get-Command ssh -ErrorAction SilentlyContinue).Source
$scpExecutable = (Get-Command scp -ErrorAction SilentlyContinue).Source
# Resolve Windows bsdtar by absolute path. When this script is launched from a
# Git Bash/MSYS parent, `tar` can resolve to /usr/bin/tar; GNU tar then treats a
# Windows path such as C:\Temp\x.tgz as a remote host and source packaging fails.
$tarExecutable = Join-Path $env:WINDIR 'System32\tar.exe'
if (-not $sshExecutable) { $sshExecutable = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe' }
if (-not $scpExecutable) { $scpExecutable = Join-Path $env:WINDIR 'System32\OpenSSH\scp.exe' }
if (-not (Test-Path -LiteralPath $sshExecutable) -or -not (Test-Path -LiteralPath $scpExecutable) -or -not (Test-Path -LiteralPath $tarExecutable)) {
    throw 'Windows OpenSSH Client (ssh/scp) and tar.exe are required.'
}
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# Directory name must identify the commit: suffix uses the 12-char git SHA, not a random GUID,
# so the IPA can be traced back to its commit straight from the path.
$gitSha = (& git -C $sourceRoot rev-parse --short=12 HEAD 2>$null)
if (-not $gitSha) { throw 'git rev-parse failed: build must run inside the git work tree' }
$gitSha = $gitSha.Trim()
if ($gitSha -notmatch '^[0-9a-f]{12}$') { throw "Unexpected git SHA: $gitSha" }
$gitTree = (& git -C $sourceRoot rev-parse 'HEAD^{tree}' 2>$null)
$gitStatus = (& git -C $sourceRoot status --porcelain 2>$null)
if ($gitStatus) { throw "Working tree is dirty; commit or stash before building:`n$gitStatus" }
# F-41: version/build come from release.json at the repository root, the single
# source of truth shared with tests/verify_source.py and scripts/release-local.sh.
# No fallback on purpose: a missing or malformed file must stop the build rather
# than ship a package whose number disagrees with the source gate. Note that
# Resources/Info.plist is a static file and cannot read release.json, so it still
# has to be edited by hand; the gate fails with 'Info.plist release mismatch' if
# the two drift apart.
$releaseFile = Join-Path $sourceRoot 'release.json'
if (-not (Test-Path -LiteralPath $releaseFile)) {
    throw "release.json not found at $releaseFile (single source of truth for version/build)"
}
try {
    $releaseData = Get-Content -LiteralPath $releaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "release.json is not valid JSON: $($_.Exception.Message)"
}
$releaseVersion = $releaseData.version
$releaseBuild = $releaseData.build
# Both must be JSON strings, matching what tests/verify_source.py enforces. An
# unquoted number would coerce to the right text here but fail the gate, so reject
# it at the earliest point instead of shipping a mismatch.
if (-not ($releaseVersion -is [string]) -or -not $releaseVersion.Trim()) {
    throw 'release.json needs a non-empty "version" string'
}
if (-not ($releaseBuild -is [string]) -or -not $releaseBuild.Trim()) {
    throw 'release.json needs a non-empty "build" string'
}
if ($releaseVersion -ne $releaseVersion.Trim() -or $releaseBuild -ne $releaseBuild.Trim()) {
    throw 'release.json values must not be padded with whitespace'
}
$taskName = "HermesShell-$releaseVersion-build$releaseBuild-" + $gitSha + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$projects = $env:HERMES_BUILD_PROJECTS
if (-not $projects) { throw 'Set HERMES_BUILD_PROJECTS to your remote build directory.' }
if ($projects -notmatch '^/[A-Za-z0-9_./-]+$') { throw "Invalid remote project root: $projects" }
# Fixed workspace: the build reuses one directory instead of a fresh one per
# release. That is what makes incremental compilation possible -- SwiftPM keeps
# .build/ (module cache, object files, dependency checkouts) between runs, which
# cuts a full rebuild from ~200s to the time of the changed files only.
# The directory name is stable on purpose; the version/build/commit still end up
# in the delivery directory ($outputs) and in build-info.json.
$remoteWorkspaceName = '.hermes-build-workspace'
$remoteRoot = "$projects/$remoteWorkspaceName"
$outputs = Join-Path (Join-Path $sourceRoot 'releases') $taskName
$ipaName = "Hermes-$releaseVersion-build$releaseBuild-unsigned.ipa"
# Only one publishable directory per version+build: refuse duplicates so two different
# binaries can never share the same version number. A directory left behind by a
# failed run carries FAILED.txt and no IPA, so it must not block the retry.
$releasesRoot = Join-Path $sourceRoot 'releases'
$existing = @()
if (Test-Path -LiteralPath $releasesRoot) {
    $existing = @(Get-ChildItem -Path $releasesRoot -Directory |
        Where-Object { $_.Name -like "HermesShell-$releaseVersion-build$releaseBuild-*" } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $ipaName) })
}
if ($existing.Count -gt 0) {
    throw "Refusing duplicate build: $releaseVersion/build$releaseBuild already exists at $($existing[0].Name). Move it to releases/archive/ first."
}
# Bind the artifact to its commit via build-info.json, written only after a
# successful build so a failed run never leaves a half-package behind.
$buildInfo = [ordered]@{
    version = $releaseVersion
    build = $releaseBuild
    head_commit = $gitSha
    head_tree = ($gitTree -as [string]).Trim()
    built_at = (Get-Date).ToString('o')
    working_tree = 'clean'
}
$step = 'init'
# Last native exit code, kept for FAILED.txt because $LASTEXITCODE is not
# reliable inside the catch block.
$script:lastStepExit = 0
function Assert-Exit([string]$Name) {
    $script:lastStepExit = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { throw "$Name failed (exit $LASTEXITCODE). Old project and IPA were preserved." }
}
# Windows PowerShell 5.1 writes a UTF-8 BOM with -Encoding utf8. A BOM breaks
# sha256sum -c and any strict JSON reader, so every sealed file is written
# through this helper instead.
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
# F-30/P2-19: a failed run must leave a diagnosis next to the artifacts instead
# of an empty or half-filled directory.
function Write-Failure([string]$Name, [string]$Detail) {
    if (-not (Test-Path -LiteralPath $outputs)) { return }
    $detailLine = ($Detail -replace '\s+', ' ').Trim()
    if ($detailLine.Length -gt 500) { $detailLine = $detailLine.Substring(0, 500) }
    $lines = @(
        'status=FAILED',
        "step=$Name",
        "last_exit_code=$script:lastStepExit",
        ('failed_at=' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')),
        "detail=$detailLine"
    )
    Write-Utf8NoBom (Join-Path $outputs 'FAILED.txt') (($lines -join "`n") + "`n")
}
# F-42/F-65: the container cannot know the commit provenance (the tarball ships
# without .git), so the sealed report and the checksum list are completed here,
# after the download, and only for a fully successful build.
function Complete-Release {
    $ipaPath = Join-Path $outputs $ipaName
    if (-not (Test-Path -LiteralPath $ipaPath)) { throw "Missing IPA in download: $ipaName" }
    $validationPath = Join-Path $outputs 'validation.json'
    if (-not (Test-Path -LiteralPath $validationPath)) { throw 'Missing validation.json in download' }
    $validation = Get-Content -LiteralPath $validationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $actual = (Get-FileHash -LiteralPath $ipaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($validation.sha256 -and ($validation.sha256.ToLowerInvariant() -ne $actual)) {
        throw "Downloaded IPA does not match validation.json (got $actual, expected $($validation.sha256))"
    }
    # Provenance gate: same three assertions verify_ipa.py enforces. They are
    # repeated here because build-info.json is created after the container step.
    $info = Get-Content -LiteralPath (Join-Path $outputs 'build-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($info.working_tree -ne 'clean') { throw "build-info.json working_tree is '$($info.working_tree)', expected clean" }
    if ($info.version -ne $buildInfo.version -or $info.build -ne $buildInfo.build) {
        throw "build-info.json version/build mismatch: $($info.version)/$($info.build)"
    }
    if (-not $info.head_commit) { throw 'build-info.json has no head_commit' }
    $validation | Add-Member -NotePropertyName 'ipa' -NotePropertyValue $ipaName -Force
    $validation | Add-Member -NotePropertyName 'sha256' -NotePropertyValue $actual -Force
    $validation | Add-Member -NotePropertyName 'build_info' -NotePropertyValue ([ordered]@{
        head_commit = $info.head_commit
        head_tree = $info.head_tree
        working_tree = $info.working_tree
        built_at = $info.built_at
    }) -Force
    Write-Utf8NoBom $validationPath ($validation | ConvertTo-Json -Depth 6)
    # Cover every delivered file, not only the IPA (F-65).
    $names = @(Get-ChildItem -LiteralPath $outputs -File |
        Where-Object { $_.Name -ne 'SHA256SUMS.txt' -and $_.Name -ne 'FAILED.txt' } |
        Sort-Object Name | ForEach-Object { $_.Name })
    if ($names.Count -eq 0) { throw 'No release files to hash' }
    $sums = foreach ($name in $names) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $outputs $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    Write-Utf8NoBom (Join-Path $outputs 'SHA256SUMS.txt') (($sums -join "`n") + "`n")
    # Only clear the marker when it actually exists: the safe-delete wrapper fails
    # closed on a missing path, which would abort a successful build.
    $failedMarker = Join-Path $outputs 'FAILED.txt'
    if (Test-Path -LiteralPath $failedMarker) {
        Remove-Item -LiteralPath $failedMarker -ErrorAction SilentlyContinue
    }
    Write-Host "Sealed $($names.Count) files in $outputs"
}
# Uses your existing SSH agent/keys and known_hosts. No passwords or keys are embedded.
try {
    $step = 'Check build tools'
    & $sshExecutable -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=10 $Target "docker exec ios-build bash -lc 'command -v swiftc && command -v xtool'"
    Assert-Exit $step
    # Reproducible packaging: export SOURCE_DATE_EPOCH for the compiler/toolchain.
    # Note that `tar --mtime` is deliberately NOT used here any more -- see the
    # pack step below for why it defeated incremental builds.
    $epoch = (& git -C $sourceRoot log -1 --format=%ct).Trim()
    if (-not $epoch) { throw 'git log --format=%ct failed' }
    $env:SOURCE_DATE_EPOCH = $epoch
    # Fixed workspace + rsync --delete keeps the build tree in sync with this
    # commit while preserving .build/ (SwiftPM's module cache, object files and
    # dependency checkouts). That is the whole point of this step: a per-release
    # fresh directory forced a full rebuild every time.
    #
    # The Windows host has no rsync, so the source is streamed as a tar over SSH
    # and unpacked remotely, then rsync copies it into the workspace. --delete
    # removes files that no longer exist in this commit; the excludes keep
    # .build/ and the delivery directory intact so the next build stays warm.
    #
    # The staging directory MUST live outside $remoteRoot: rsync --delete would
    # otherwise delete its own source while copying (it deletes everything in the
    # destination that is absent from the source, and .incoming is inside it).
    $step = 'Sync source into the fixed workspace'
    $tarExcludes = '--exclude=.git --exclude=.build --exclude=.bsp --exclude=xtool --exclude=releases'
    $staging = "$projects/.hermes-build-incoming"
    $remoteSync = "set -e; " +
        "rm -rf '$staging'; mkdir -p '$staging'; " +
        "tar xzf '$staging.tgz' -C '$staging'; " +
        "mkdir -p '$remoteRoot'; " +
        "rsync -a --delete --exclude=.build --exclude=xtool --exclude=releases " +
        "'$staging/' '$remoteRoot/'; " +
        "rm -rf '$staging' '$staging.tgz'; " +
        "mkdir -p '$remoteRoot/releases'"
    # The source is packed to a local tarball, uploaded, then unpacked remotely.
    #
    # Why not stream it: PowerShell 5.1 pipes binary data through the text
    # pipeline, which corrupts the gzip stream ('gzip: stdin: not in gzip
    # format' / 'tar: Child died with signal 13'). A temp file is the only
    # reliable transport here.
    #
    # NO --mtime. It used to stamp every file with the commit time "for
    # reproducibility", and that silently defeated incremental builds: SwiftPM
    # decides what to recompile by comparing file mtimes against the build
    # database, so after every rsync all 110 files looked freshly modified and
    # the whole module was rebuilt even when only one file changed. Measured on
    # the build host: touching a single file cost 111s (identical to a full
    # rebuild), while a genuine no-op build took 5.9s. Keeping the real mtimes
    # lets rsync skip unchanged files, so their mtimes stay put and SwiftPM can
    # skip them too.
    #
    # Reproducibility is preserved where it actually matters: SOURCE_DATE_EPOCH
    # is still exported above, and the IPA bytes are verified by sha256 in
    # validation.json/SHA256SUMS.txt rather than by a byte-identical tarball.
    $archive = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-sync-" + $gitSha + '.tgz')
    & $tarExecutable $tarExcludes.Split(' ') -czf $archive -C $sourceRoot .
    Assert-Exit 'Pack source'
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $scpExecutable -o BatchMode=yes -o LogLevel=ERROR $archive "${Target}:$staging.tgz"
        if ($LASTEXITCODE -eq 0) {
            & $sshExecutable -o BatchMode=yes -o LogLevel=ERROR $Target $remoteSync
        }
    } finally {
        $ErrorActionPreference = $previousPreference
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -ErrorAction SilentlyContinue }
    }
    Assert-Exit $step
    $step = 'Release build and IPA verification'
    # The workspace is written by the host user over rsync but built as root
    # inside the container, so git refuses the dependency caches under
    # .build/repositories ('detected dubious ownership'). SwiftPM then treats
    # them as unusable, falls back to fetching from the network, and the
    # container has no route to github.com -- the build dies after a 135s
    # connect timeout. release-local.sh fixes ownership and registers the
    # safe directory itself; doing it there avoids quoting a glob through
    # `bash -lc '...'`, which terminates the outer single quotes.
    # `-tt` forces a PTY, which xtool requires. Its output is captured to a file
    # and replayed afterwards instead of being piped: piping a PTY through the
    # caller's pipeline closes the session early and the build dies with SIGHUP
    # (exit 129) before xtool finishes.
    $buildLog = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-build-" + $gitSha + '.log')
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $sshExecutable -tt -o BatchMode=yes -o LogLevel=ERROR $Target "docker exec -t -w /work/$remoteWorkspaceName ios-build bash -lc 'bash scripts/release-local.sh'" > $buildLog 2>&1
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if (Test-Path -LiteralPath $buildLog) {
        Get-Content -LiteralPath $buildLog | ForEach-Object { Write-Host $_ }
    }
    Assert-Exit $step
    if (Test-Path -LiteralPath $buildLog) { Remove-Item -LiteralPath $buildLog -ErrorAction SilentlyContinue }
    $step = 'Download artifacts'
    # Only the delivery directory is copied out; .build/ never leaves the host.
    # Windows OpenSSH's recursive scp does not reliably create a missing local
    # destination directory when the source is written as `releases/.`. Stream
    # one archive instead: the remote archive is removed even when download or
    # extraction fails, and the local extraction directory is explicitly made.
    $releaseArchive = Join-Path ([System.IO.Path]::GetTempPath()) (
        'hermes-releases-' + [guid]::NewGuid().ToString('N') + '.tgz')
    $remoteReleaseArchive = "$remoteRoot/releases.tgz"
    try {
        & $sshExecutable -o BatchMode=yes -o LogLevel=ERROR $Target `
            "tar czf '$remoteReleaseArchive' -C '$remoteRoot/releases' ."
        Assert-Exit $step
        & $scpExecutable -o BatchMode=yes -o LogLevel=ERROR `
            "${Target}:$remoteReleaseArchive" $releaseArchive
        Assert-Exit $step
        New-Item -ItemType Directory -Path $outputs -Force | Out-Null
        & $tarExecutable -xzf $releaseArchive -C $outputs
        Assert-Exit $step
    } finally {
        & $sshExecutable -o BatchMode=yes -o LogLevel=ERROR $Target `
            "rm -f '$remoteReleaseArchive'" 2>$null
        if (Test-Path -LiteralPath $releaseArchive) {
            Remove-Item -LiteralPath $releaseArchive -ErrorAction SilentlyContinue
        }
    }
    $step = 'Write build-info'
    Write-Utf8NoBom (Join-Path $outputs 'build-info.json') ($buildInfo | ConvertTo-Json)
    $step = 'Seal validation and checksums'
    Complete-Release
    Write-Host "Verified IPA and logs: $outputs"
} catch {
    # Create the directory first: a failure before the download must still leave
    # a diagnosis. A FAILED.txt-only directory has no IPA, so the duplicate check
    # above lets the retry proceed.
    if (-not (Test-Path -LiteralPath $outputs)) { New-Item -ItemType Directory -Path $outputs -Force | Out-Null }
    Write-Failure $step $_.Exception.Message
    throw
} finally {
    # The local tarball is removed in the sync step's own finally block.
    # The remote workspace deliberately survives so .build/ stays warm.
    Write-Host "Workspace kept for incremental builds: $Target`:$remoteRoot"
}
