# Composer symbol visibility — 2026-10-21

User screenshot of 22.1 shows empty model/plugin circles; thinking/photo/file still render. User asks to restore model/plugin visibility and return file to the previous icon. Keep layout, interaction, custom model/plug outlines and all motion. Compile/package, no tests. Blueprint amendment 4746ed1.

Both missing artworks used Canvas GraphicsContext.Shading.foreground, while the visible thinking artwork uses explicit color(.primary). Apply the same explicit semantic shading to the four model/plugin drawing calls, including the model center dot. This is a source-supported cause matching the device difference; visual confirmation remains on-device. The shared symbol view covers both primary menus and detail headers.

Restore SF paperclip medium weight, remove heavy weight and 1.10 horizontal scale, matching the pre-22.1 original proportions. No other production file changes. Unrelated deep-reading-native-trace.txt remains excluded.

Local diff/whitespace checks complete. No tests or simulator probes run. macOS build/package receipt pending.

## Build and delivery receipt

Application source b05d0cc308a99d040efdfb2897d0b7949c28c3d8; packaging 0b1a063ed2ea40248e032579dd63ac95fd472252. Run https://github.com/54zhien/Zen-Agent/actions/runs/39544057633 succeeded: XcodeGen generation, Xcode 26.6 device build and unsigned IPA packaging. No tests run.

Downloaded version 23.1; Info.plist bundle ID/version and BUILD-INFO source matched. SHA256SUMS matched local SHA-256 7a8237eba2e3186cf93b9b90dfafac936e3d9981a8b1624e96936a96ae64afcd. Runtime icon visibility remains device acceptance, not established by compilation. No main merge.
