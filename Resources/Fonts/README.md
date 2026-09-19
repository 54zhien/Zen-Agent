# Zen Agent Font Assets

These are the canonical font assets selected for Zen Agent development.

> Important for development AI:
> - Do not silently replace these fonts with similarly named files.
> - Verify the actual bundled font/PostScript names at runtime before wiring typography.
> - Use the centralized Typography system described in
>   `Zen-Agent-Blueprint → Design/Zen Agent Conversation UI 与 Composer.md`; do not scatter raw font names across views.
> - These assets define the intended visual direction, but the implementation still needs to respect Dynamic Type, fallback glyphs, target SDK behavior, and actual licensing.
> - **Anthropic Sans licensing/distribution status is not yet verified. Do not ship or publicly redistribute it until rights are confirmed.**
>   This is a **release blocker, not a product invariant** — the interface typeface role is a design baseline,
>   and the Typography token structure does not depend on which typeface fills it.
>   See `Zen-Agent-Blueprint → Design/ADR/0003-interface-font-is-a-release-blocker.md`.
>
> This file is the **file manifest** for these assets (identity, hashes, upstream provenance).
> The design rationale and licensing constraints live in the Blueprint, not here.
> - **Do not assume the interface typeface has multiple weights.** See the per-file notes below before designing
>   type hierarchy around it.

## Canonical files

### Interface — Anthropic Sans

- Repository path: `Resources/Fonts/Anthropic Sans.ttf`
- Expected family: `Anthropic Sans Web Text`
- Expected PostScript name: `AnthropicSansWebVariable-TextRegular`
- File size: 69,252 bytes
- SHA-256: `23d4e1fd7be1c5660deb039dfee29dc284417aea90b744a435ce9ad752e50254`
- Git blob hash: `71810f174d9e4219e2f42db8f9427209b80a3276`
- Role: application/interface typography.
- CJK fallback: iOS System Sans.
- Licensing: **UNVERIFIED — development/reference use only until confirmed for app embedding/distribution.**
- **Weights available: Regular only.** Inspected, this file has no `fvar` axis — it is a single static
  Regular instance despite its internal name containing `WebVariable`. There is no Bold, Semibold or Italic.
  Any title/body/caption hierarchy built on this typeface therefore relies on **synthesised** bold,
  which does not match a real bold face and degrades at accessibility sizes. Calibrate on device,
  and treat "the interface typeface may need to change" as a live possibility when designing the tokens.
- The binary itself carries **no license declaration** (no `name[13]`/`name[14]` records); its copyright
  string is `Copyright 2025 Anthropic PBC`. Absence of an embedded licence is not permission.

### Conversation Content — Source Han Serif SC VF

- Repository path: `Resources/Fonts/SourceHanSerifSC-VF.ttf`
- Expected family: `Source Han Serif SC VF` / `思源宋体 VF`
- Expected PostScript name: `SourceHanSerifSCVF-ExtraLight`
- File size: 59,925,144 bytes
- SHA-256: `78b3620b612554d6811ede71614ea100e5af4cd7a4ca26c570704061f8b176a9`
- Git blob hash: `7491214b74e60ca517753700739b35065e2db358`
- Role: User Prompt and Assistant reading content, Markdown headings/lists/quotes.
- Variable `wght` axis: 250–900.
- Do not rely on the file's default axis value; use an explicit readable body weight (start around 400 and tune on-device).
- Upstream identity used for verification: Adobe Source Han Serif 2.001, `Variable/TTF/SourceHanSerifSC-VF.ttf`.
- License: SIL Open Font License 1.1. Repository copy: `Resources/Fonts/LICENSE-SourceHanSerif.txt`. Keep the license with redistributed copies.
- The repository copy of this license was **corrected on 2026-09-19**: it previously omitted the
  `Copyright 2017-2022 Adobe …, with Reserved Font Name 'Source'.` notice and the trademark line,
  which OFL 1.1 §2 requires to accompany every copy. It is now byte-identical to Adobe's upstream
  `LICENSE.txt`. Do not replace it with a copy that drops the header again.
- **Subsetting or converting to static weights makes this a "Modified Version" under OFL 1.1 §3**,
  which forbids continuing to use the Reserved Font Name `Source` — i.e. a subset build may not still be
  named "Source Han Serif" / "思源宋体". Any size-optimisation work must account for that renaming,
  not just for glyph coverage.

### Code — JetBrains Mono

- Repository path: `Resources/Fonts/JetBrainsMono-Regular.ttf`
- Expected family: `JetBrains Mono`
- Expected PostScript name: `JetBrainsMono-Regular`
- File size: 273,900 bytes
- SHA-256: `a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f`
- Git blob hash: `dff66cc50702c75abd025dcf49f62a4dcc2d72de`
- Role: code blocks, inline code, shell/terminal, JSON.
- CJK fallback: iOS System Monospaced (or the closest available monospaced CJK fallback).
- Upstream identity used for verification: JetBrains Mono 2.304, `fonts/ttf/JetBrainsMono-Regular.ttf`.
- License: SIL Open Font License 1.1. Repository copy: `Resources/Fonts/LICENSE-JetBrainsMono.txt`. Keep the license with redistributed copies.

## Asset-size note

`SourceHanSerifSC-VF.ttf` is approximately 59.9 MB. Keep this canonical file during development so typography is reproducible. Before release, measure IPA/install size, first-use latency and memory. Any subsetting/static-weight conversion or replacement must preserve the required Chinese glyph coverage and comply with OFL conditions; do not silently replace the user-selected font. Note the Reserved Font Name consequence of subsetting described above.

**No acceptable size threshold has been set.** "Measure it" without a target is not a pass/fail criterion,
so this stays an open decision rather than a satisfied requirement. Also note that if the interface typeface
has to be replaced for licensing reasons, the packaging and first-load measurements must be redone for the
new face — the current numbers are not a durable baseline.

## Runtime integration checklist

1. Add the actual font assets to the application target/resources.
2. Verify registration using the real target SDK/build, rather than trusting filenames alone.
3. Build a centralized typography token/factory layer.
4. Apply:
   - Interface → Anthropic Sans, CJK System Sans fallback.
   - Conversation content → Source Han Serif SC VF with explicit weight.
   - Code → JetBrains Mono, CJK monospaced fallback.
5. Apply Dynamic Type / `UIFontMetrics` or the current equivalent.
6. Test Chinese, English, mixed CJK/Latin, emoji, code with Chinese comments, Bold/heading cases, and accessibility sizes on-device.
7. Source Han Serif and JetBrains Mono have their OFL copies in this folder (Source Han Serif's was corrected on 2026-09-19 — see above). Anthropic Sans remains unverified for redistribution/app embedding; do not ship it until its rights are independently confirmed. It is a release blocker, so make sure the release path can proceed with a different interface typeface if that is how the licensing question resolves.
