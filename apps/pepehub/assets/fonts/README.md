# Reader font

Lora.ttf is the unmodified variable font `Lora[wght].ttf` from
https://github.com/google/fonts/tree/main/ofl/lora, downloaded 2026-09-19.

SHA-256: `822a6621ccbe8d97d20ac88c1c41f5615c9c2c202eaa75f272cd452aac6475a7`.
The accompanying `Lora-OFL.txt` contains its copyright and SIL Open Font License.
Both the font and license are bundled for offline use. `ReaderLora` is the
Flutter asset registration alias; the font binary has not been renamed internally.

# Interface fonts

`Oswald.ttf`, `CormorantGaramond.ttf`, `CormorantGaramond-Italic.ttf` and
`Onest.ttf` are the unmodified variable fonts from
https://github.com/google/fonts (folders `ofl/oswald`, `ofl/cormorantgaramond`,
`ofl/onest`). Their SIL Open Font License texts are bundled next to them as
`*-OFL.txt`. `.local/claude-fonts.ps1` downloads them if they are missing.

# Additional reading fonts

Literata, Merriweather, Noto Serif, PT Serif, PT Sans, Roboto and Open Sans
are bundled unmodified from the official `google/fonts` repository at revision
`9b59ea9f333c5b8a99fa44e2a698496d6cde5b8e`. Each family includes its italic
face; static PT faces also include bold and bold italic. Variable faces retain
their full weight ranges. Lora, Onest and Manrope remain available under their
existing registration names.

`reader-fonts.json` records the pinned source URLs, registration aliases and
SHA-256 of every added font binary. `scripts/fetch-reader-fonts.py` retrieves
the upstream fonts and the accompanying OFL licenses. Merriweather's FONTLOG
is also bundled as requested by its authors. The app never downloads fonts
while reading. Glyph coverage is checked against the full Ukrainian, Russian
and English alphabets, including Ґґ, Єє, Іі and Її.
