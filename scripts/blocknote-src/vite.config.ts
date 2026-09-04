import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Vite config for the BlockNote bundle embedded inside Sidekey's
// Resources/blocknote/. Output is loaded by WKWebView via a `file://`
// URL from the .app's Contents/Resources/blocknote/ at runtime, so:
//
//   - `base: "./"` produces relative asset URLs that work under file://
//     (absolute "/assets/..." would 404 on the local filesystem).
//   - The HTML is emitted as a single self-contained <script src=...>
//     (NOT `<script type="module">`). WebKit silently refuses to load
//     ES modules over the `file://` scheme because file URLs are not
//     a "trustworthy origin" for the module loader. The fetch never
//     hits Web Inspector → Network and no console error appears, so
//     the symptom is a blank right pane in the Meetings viewer.
//     Switching the output format to `iife` makes Rollup emit a
//     classic script wrapper (`(function(){…})()`) with all of React
//     + BlockNote inlined — no `import`/`export` keywords at the
//     top level, no module preloads, no `crossorigin` attribute
//     needed on the tag. Loadable via a plain `<script src="…">`.
//   - `inlineDynamicImports: true` is required by the iife format
//     because IIFE cannot represent multiple chunks. We already wanted
//     a single bundle (audit + caching simplicity), so this is free.
//   - `assetFileNames` keeps the existing `assets/<name>` layout so
//     the Swift host's path resolution stays the same.
//
// If you switch back to ES-module output, also drop the CSP meta tag
// from the HTML and route the bundle through a custom
// `WKURLSchemeHandler` instead of `loadFileURL` — otherwise the page
// stays blank with no diagnostics.
export default defineConfig({
  plugins: [react()],
  base: "./",
  build: {
    outDir: "../../Resources/blocknote",
    emptyOutDir: true,
    rollupOptions: {
      output: {
        format: "iife",
        entryFileNames: "assets/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
        inlineDynamicImports: true,
      },
    },
  },
});
