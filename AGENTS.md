# AGENTS.md

## Project intent

This repository contains a minimal macOS user agent that recovers a Wacom
Cintiq when the display reconnects but the Wacom tablet driver fails to claim
the USB device.

## Non-negotiable behavior

- Keep detection event-driven through IOKit. Do not add timers or periodic
  polling.
- Match both Wacom vendor ID `0x056a` and the configured USB product name.
- Check for `WacomTabletDrive` in the device's IOService subtree before taking
  action.
- Restart only the three known user-session jobs in `wacomLaunchdLabels`.
- Never require root, install a kernel extension, access the network, or modify
  the official Wacom driver.
- Preserve the grace delay and restart cooldown as configurable safeguards.

## Build and validation

- Native build: `make release`
- Universal build: `make universal`
- Plist check: `plutil -lint launchd/com.local.wacom-recovery.plist`
- Inspect architectures: `lipo -archs .build/release/wacom-recovery-universal`

Generated binaries belong in `.build/` or GitHub Releases, never in Git.

## Repository conventions

- Support macOS 13 and newer on Apple silicon and Intel.
- Use Foundation and system IOKit only; avoid package dependencies.
- Keep installation reversible through `scripts/uninstall.sh`.
- Update the README when command-line flags, job labels, or installation paths
  change.
- Tag stable releases as `vMAJOR.MINOR.PATCH`; the release workflow publishes
  a universal binary and SHA-256 checksum.
