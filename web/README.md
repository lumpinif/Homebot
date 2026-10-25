# Homebot setup page

The page the gateway serves at `http://127.0.0.1:8788/`. React 19, Tailwind CSS v4 and
[beUI](https://beui.dev) components, built by Vite into `../src/setup-ui/`, where the build is
committed: people who run Homebot install nothing for it.

```bash
npm --prefix web install      # once
npm run build:ui              # from the repository root: rebuild src/setup-ui
npm run check:ui              # fails if the committed build is stale
```

- `src/components/motion/` and `src/lib/` are beUI components added with the shadcn CLI
  (`npx shadcn@latest add @beui/<name>`; the registry is in `components.json`). beUI is MIT
  licensed; its license is in `src/components/motion/LICENSE`. Local changes are marked
  `// Homebot:`.
- `src/components/fluid/` is Fluid Functionalism's fluid-hover hook, highlight and spring tiers
  (MIT, Micka Touillaud; license in that folder). `src/app/fluid.tsx` builds the segmented
  control, menus and chips on them.
- `src/app/brand.tsx` draws the Grok Bot face (from the geometry on x.ai/bot) and the Cursor
  mark (path from `@lobehub/icons`, MIT). The marks belong to xAI and Anysphere and only name
  their products. The Siri orb is Homebot's own; Apple's icons are not used.
- The gateway's Content-Security-Policy allows only same-origin scripts and styles, plus
  `<style>` elements carrying the per-load nonce in `<meta name="homebot-style-nonce">`
  (motion inserts a few). No inline scripts, no `data:` URLs.
- Strings live in `src/strings.ts`, English and Simplified Chinese with the same keys
  (checked by `test/setup.test.ts`).
