# Third-party notices

Porpoise is free software under the GNU General Public License v3.0 or later (see `LICENSE`).
It is inspired by [KDE Dolphin](https://apps.kde.org/dolphin/) and follows its behaviour and layout, but it is an
independent project, not affiliated with or endorsed by KDE e.V. "KDE" and "Dolphin" are trademarks of KDE e.V.

Porpoise includes the following works:

| Component | Author | Licence | Where |
|---|---|---|---|
| Tela circle icon theme | Vince Liuice | GPL-3.0 | `Resources/icons` |
| Desert colour scheme (Plasma / Konsole) | L4ki | AGPL-3.0 | `Resources/Desert-Konsole.colorscheme`, colours in `Theme.swift` |
| SwiftTerm | Miguel de Icaza | MIT | `Vendor/SwiftTerm` |
| Sparkle 2.10 (in-app updates) | Andy Matuschak, the Sparkle Project contributors | MIT (with the notices in its licence file) | Swift package, shipped as `Contents/Frameworks/Sparkle.framework` |
| FFmpeg 8.0 | the FFmpeg developers | LGPL-2.1-or-later | built by `scripts/build-ffmpeg.sh`, shipped as `Contents/Helpers/ffmpeg` |
| fd 10.5.0 | David Peter and contributors | MIT (or Apache-2.0) | official release binary, fetched by `scripts/fetch-search-tools.sh`, shipped as `Contents/Helpers/fd` |
| ripgrep 15.2.0 | Andrew Gallant | MIT (or Unlicense) | official release binary, fetched by `scripts/fetch-search-tools.sh`, shipped as `Contents/Helpers/rg` |
| Symbols Nerd Font | Ryan L McIntyre and contributors | MIT; its glyphs come from Font Awesome, Material Design Icons, Codicons, Octicons, Devicons, Powerline and other icon sets under their own open licences (SIL OFL 1.1, Apache-2.0, MIT, CC BY 4.0), see [Nerd Fonts' licence notes](https://github.com/ryanoasis/nerd-fonts#license) | `Resources/fonts` |

The AGPL-3.0 colour scheme is combined with the GPL-3.0 program as allowed by section 13 of both licences; that part
remains under the AGPL-3.0. FFmpeg is a separate program run by Porpoise; its source is available at
https://ffmpeg.org/releases/ and can be rebuilt with `scripts/build-ffmpeg.sh`. Full licence texts are in `LICENSE`,
`LICENSE-AGPL-3.0.txt` (the colour scheme), `Vendor/SwiftTerm/LICENSE`, `Resources/fonts/NerdFontsSymbols-LICENSE.txt`, Sparkle's `LICENSE` and, inside the app,
`Contents/Resources/Licenses/`.

Android support downloads Google's Android SDK Platform-Tools from Google on request; they are not part of Porpoise
and are covered by Google's own licence.
