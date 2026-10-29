# Bundled fonts

Both families are licensed under the SIL Open Font License 1.1. The licence texts are in
`MyGuide/Design/Fonts/` (`Inter-OFL.txt`, `PlayfairDisplay-OFL.txt`) and are copied into the app bundle.
The font files are unmodified; downloaded 2026-10-29 with the owner's approval.

## Inter 4.1

- Source: https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip (official release, tag v4.1)
- Files taken: `extras/ttf/Inter-Regular.ttf`, `extras/ttf/Inter-Medium.ttf` (static TrueType, version 4.001)
- Licence: `LICENSE.txt` from the same zip, stored as `Inter-OFL.txt`
- PostScript names: `Inter-Regular`, `Inter-Medium`
- SHA-256: Regular `40d692fc...0c82`, Medium `97ad806f...a872` (full: `shasum -a 256` on the files)

## Playfair Display (variable, SemiBold instance)

- Source: https://github.com/google/fonts/blob/main/ofl/playfairdisplay/PlayfairDisplay%5Bwght%5D.ttf
  (google/fonts at main, commit 9862abc066c9b83bf84c3e8ed1fc2d8d48f9bbf0 at download time; upstream
  https://github.com/clauseggers/Playfair, pinned commit 80a334101928546b04fa9e709ad4b2f11f8a9e10).
- Stored as `PlayfairDisplay-Variable.ttf` (renamed only: the file name has brackets; contents unmodified).
- Licence: https://raw.githubusercontent.com/google/fonts/main/ofl/playfairdisplay/OFL.txt, stored as `PlayfairDisplay-OFL.txt`.
- Why variable: upstream `clauseggers/Playfair` 2.203 ships only the new Playfair family (variable, optical size),
  not Playfair Display. Google Fonts never carried a static SemiBold (its old static folder had Regular, Bold,
  Black only, removed in google/fonts#3695). Cutting a static SemiBold would modify the font under the
  Reserved Font Name "Playfair Display", so the unmodified variable file is bundled instead.
- Weight axis 400-900. Its named SemiBold instance (wght 600) has the PostScript name
  `PlayfairDisplayRoman-SemiBold`; this resolved through `UIFont(name:)` on the iOS 26.2 simulator with wght=600.
  The theme uses that name.
- SHA-256: `c40f2293...d8d6`
