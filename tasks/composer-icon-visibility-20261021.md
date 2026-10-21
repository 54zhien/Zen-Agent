# Composer symbol visibility — 2026-10-21

User screenshot of 22.1 shows empty model/plugin circles; thinking/photo/file still render. User asks to restore model/plugin visibility and return file to the previous icon. Keep layout, interaction, custom model/plug outlines and all motion. Compile/package, no tests. Blueprint amendment 4746ed1.

Both missing artworks used Canvas GraphicsContext.Shading.foreground, while the visible thinking artwork uses explicit color(.primary). Apply the same explicit semantic shading to the four model/plugin drawing calls, including the model center dot. This is a source-supported cause matching the device difference; visual confirmation remains on-device. The shared symbol view covers both primary menus and detail headers.

Restore SF paperclip medium weight, remove heavy weight and 1.10 horizontal scale, matching the pre-22.1 original proportions. No other production file changes. Unrelated deep-reading-native-trace.txt remains excluded.

Local diff/whitespace checks complete. No tests or simulator probes run. macOS build/package receipt pending.
