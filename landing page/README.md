# Framecast Studio landing page

This is the Framecast Studio marketing site, built with React and Vite. GSAP handles the short opening sequence and scroll reveals. A small original Lottie animation adds motion to the audio signal indicator. The illustrations are original; no external font, analytics, or image service is required.

Use the Node version in `.nvmrc`. The build output is `dist/`, including the project-page base path for GitHub Pages.

Push changes to `landing page/` on `main` to build and publish with the GitHub Pages workflow. Keep product claims aligned with the app's current [README](../README.md#known-limits), especially the distinction between implemented local/YouTube workflows and unfinished guest, multistream, and unified-chat features. The screenshots and app tour in `public/media/` are captures of the installed app, not mockups.

Preview locally with:

```sh
npm ci
npm run dev
```
