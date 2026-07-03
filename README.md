# Cemu — iOS Port (Wii U Emulator, A-chip)

A native SwiftUI iOS port targeting A-series ("A-chip") devices, built on top of the
[Cemu](https://cemu.info) Wii U emulator project. This repo contains the iOS app shell
(`src/ios/`) — game library, controller skins, a PowerPC interpreter with an optional
loop-caching JIT — alongside the vendored desktop Cemu C++ source it's built from.

**Status: early and experimental.** The interpreter implements only a subset of real
PowerPC opcodes and GPU command translation isn't implemented yet, so commercial games
don't run. This is under active development; expect gaps, and see the "Known
Limitations" section of each [release](https://github.com/bward-dev1/cemu-ios-a-chip/releases)
for exactly what's true of that build.

## Getting the app

Unsigned IPAs are built automatically via GitHub Actions on every tagged release — grab
the latest from the [Releases page](https://github.com/bward-dev1/cemu-ios-a-chip/releases)
and sideload with AltStore or Apple Configurator. See a release's notes for the current
feature list and installation steps.

## Building locally

See [BUILD_AND_DEPLOY.md](BUILD_AND_DEPLOY.md) for the XcodeGen + Xcode build steps.

## What's here

- `src/ios/` — the actual iOS app (Swift/SwiftUI): `App/` (UI, game library management),
  `Emulation/` (CPU interpreter, memory manager, JIT engine), `Rendering/` (Metal
  pipeline), `Resources/` (asset catalog).
- `src/iosTests/` — unit tests for the emulation core, runnable locally via Xcode/
  `xcodebuild test` (not part of the release build).
- `src/Cafe/`, `dependencies/`, `cmake/` and similar — the vendored desktop Cemu C++
  codebase this port is built from; not part of the iOS app target.
- `.github/workflows/build-and-release.yml` — CI: generates the Xcode project with
  XcodeGen, archives the iOS app target, packages the IPA, and publishes a GitHub
  Release with notes.

## License

Cemu is licensed under [Mozilla Public License 2.0](/LICENSE.txt). Exempt from this are all files in the dependencies directory for which the licenses of the original code apply as well as some individual files in the src folder, as specified in those file headers respectively.
