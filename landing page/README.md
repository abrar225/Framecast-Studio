# Framecast Studio landing page

This is a dependency-free static page. Edit `index.html`; no install or build step is needed. The page uses original CSS/SVG product illustrations and does not load third-party fonts, scripts, analytics, or image assets.

Push changes to `landing page/` on `main` to publish with the GitHub Pages workflow. The repository README links to the published page. Keep product claims aligned with the app's current [README](../README.md#known-limits), especially the distinction between implemented local/YouTube workflows and unfinished guest, multistream, and unified-chat features.

Preview locally with:

```sh
python3 -m http.server 8000 --directory 'landing page'
```
