The in-app SVG uses the exact geometry from `/assets/procul-logo.svg` at the
repository root. Inkscape editor metadata is omitted; black strokes become
`currentColor` so `ProculLogo` can keep them visible in both themes. Magenta
fills and their opacity are preserved.

If the original logo changes, update this copy in the same change. Launcher
icons continue to use `../icon/icon.png`.
