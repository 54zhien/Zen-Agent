# Flat thinking rail, centered gauge and directional title — 2026-10-21

Owner rejects the recessed finish and approves a flat rail with smoother inner/outer arc-to-cap connections, strict gauge centering and a higher committed-effort title that slides/fades horizontally. Blueprint 1238a73. Build/package only, no tests; preserve all other interactions and animation.

Reference image measurement: the gray disc bounds are x35...178, y27...170 (center 106.5,98.5), while dark artwork bounds are x75...139, y73...129 (center 107,101). Remove the prior empirical downward optical offset. Center the full stroked arc using CGPath.boundingBoxOfPath; the needle remains inside that fixed envelope throughout its existing animation. Menu/header frames remain untouched.

Separate the existing analytical circle geometry into ComposerThinkingArcGeometry.swift. Hit projection and thumb/detent positions remain unchanged. The visual band trims short portions around each of four circular-arc/semicircle joins, connects endpoint position/tangent/curvature with quintic Hermite blends approximated by four native cubic segments, and keeps the circular centers and cap tips. Trim distance shrinks with very short selected segments. Both flat track and selection use this outline; selection clips to the full track. Remove rim highlights and all shadow finishes; keep the 70% white thumb and its hit geometry/motion.

Raise effort label by 2/5/7/14pt depending on available height (previous 1/3/4/8), preserving the surrounding layout budget. ComposerThinkingLevelLabel owns only committed-value display, with a 14pt/0.30s directional slide/fade and Reduce Motion handling. Model-name crossfade and selection/cancellation/request logic remain unchanged.

Equivalent SVG artwork inspected in light/dark at zero, near-start, middle and maximum progress. This is drawing review, not a native screenshot, runtime test or performance measurement. No tests run. Xcode build receipt pending. Unrelated deep-reading-native-trace.txt excluded; no main merge.
