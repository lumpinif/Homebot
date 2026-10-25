# Third-party notices

Homebot is MIT licensed (see [LICENSE](LICENSE)). It includes code adapted from the projects below. Each one's license text sits next to the code it covers.

| Code | Adapted from | License | Notice |
| --- | --- | --- | --- |
| `site/src/ui/ff/`, `site/src/ui/scroll-area.tsx`, the surface, interaction and `scroll-fade` styles in `site/src/index.css` | [Fluid Functionalism](https://github.com/mickadesign/fluid-functionalism) (Micka Touillaud), which adapts [Lina](https://github.com/SameerJS6/lina) (Sameer Singh) and the [shadcn/ui](https://ui.shadcn.com) scroll-fade utility | MIT | [site/public/THIRD_PARTY.md](site/public/THIRD_PARTY.md) |
| `web/src/components/fluid/` | Fluid Functionalism | MIT | [web/src/components/fluid/LICENSE](web/src/components/fluid/LICENSE) |
| `web/src/components/motion/`, `web/src/lib/` | beUI | MIT | [web/src/components/motion/LICENSE](web/src/components/motion/LICENSE) |
| The Cursor mark in `web/src/app/brand.tsx` | [@lobehub/icons](https://github.com/lobehub/lobe-icons) | MIT | [web/README.md](web/README.md) |

The Mac app's hover highlight (`GlideHover` in `mac/Sources/HomebotUI/Views/Pieces.swift`) follows Fluid Functionalism's design; no code was copied.

Swift and npm dependencies are listed in `mac/Package.resolved` and the `package-lock.json` files, under their own licenses.

Grok Bot, Cursor, Siri, HomePod and iPhone are trademarks of their owners. Homebot uses their names and marks only to say which products it works with, and is not affiliated with or endorsed by them.
