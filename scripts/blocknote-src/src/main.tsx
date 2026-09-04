import { useEffect } from "react";
import ReactDOM from "react-dom/client";
import { BlockNoteView } from "@blocknote/mantine";
import { useCreateBlockNote } from "@blocknote/react";
import "@blocknote/mantine/style.css";
import "./sidekey.css";

// NOTE: `@blocknote/core/fonts/inter.css` is intentionally NOT imported.
// The full Inter family ships nine weights as both `.woff` and `.woff2`
// (~360 KB combined), pushing the bundle above the 2 MB cap enforced in
// `Scripts/build-blocknote.sh`. macOS draws perfectly readable text in
// San Francisco via the CSS system-font stack — see `@blocknote/mantine`
// default font-family — and the user-visible delta is minor. If a future
// design pass wants Inter back, raise the cap (and audit the actual
// woff/woff2 weight set we ship) instead of unconditionally re-adding
// this import.

// JS <-> Swift bridge surface. The native side calls
// `window.loadMarkdown(...)` to push a meeting note into the editor and
// listens for `webkit.messageHandlers.noteEdit` posts on every change.
//
// Pull-model bridge: as soon as `useEffect` finishes wiring
// `window.loadMarkdown`, we post to `webkit.messageHandlers.editorReady`
// to tell the Swift viewer it is safe to push markdown. This eliminates
// the first-open empty-render race where Swift's `loadMarkdown(...)`
// call landed before React's initial empty-document render and got
// stomped (or hit `loadMarkdown` undefined). `window.blockNoteReady`
// stays for the existing throwaway-WKWebView smoke test, but the
// production fast path is the `editorReady` postMessage.
declare global {
  interface Window {
    loadMarkdown: (md: string) => Promise<void>;
    saveMarkdown: () => string;
    currentVersion: number;
    blockNoteReady: boolean;
    webkit?: {
      messageHandlers?: {
        noteEdit?: { postMessage: (payload: object) => void };
        editorReady?: { postMessage: (payload: object) => void };
      };
    };
  }
}

function App() {
  const editor = useCreateBlockNote();

  useEffect(() => {
    // Guard against onChange notifications fired by NON-USER edits.
    // BlockNote emits onChange when:
    //   - The editor mounts with its initial empty document.
    //   - `editor.replaceBlocks(...)` runs inside `window.loadMarkdown`.
    //   - Any future programmatic content swap we add.
    // Without this guard, every programmatic edit immediately
    // postMessages back to the Swift side, which treats it as a user
    // edit and PUTs a stale version onto the backend, triggering the
    // "Note has diverged" conflict dialog the moment the user opens
    // a note. Start suppressed; the initial mount alone fires several
    // onChange events as BlockNote settles, and we want to drop ALL of
    // them. The first `loadMarkdown` call clears the suppression after
    // its programmatic edits finish.
    let suppressOnChange = true;

    window.loadMarkdown = async (md: string) => {
      suppressOnChange = true;
      try {
        const blocks = await editor.tryParseMarkdownToBlocks(md);
        editor.replaceBlocks(editor.document, blocks);
      } finally {
        // `replaceBlocks` triggers onChange synchronously; defer the
        // re-enable so the burst of programmatic-edit onChanges drains
        // first. A microtask is enough — onChange handlers run in the
        // same tick as the editor mutation, so the next macrotask is
        // already "user-edit territory".
        queueMicrotask(() => {
          suppressOnChange = false;
        });
      }
    };

    // Synchronous shim. The real save path is the postMessage flow below;
    // this exists so any caller polling the bridge surface for symmetry
    // does not crash. Returning empty string is intentional — callers
    // that need the latest markdown should subscribe to noteEdit posts.
    window.saveMarkdown = () => "";
    window.currentVersion = 1;

    editor.onChange(() => {
      if (suppressOnChange) return;
      void (async () => {
        const md = await editor.blocksToMarkdownLossy(editor.document);
        window.webkit?.messageHandlers?.noteEdit?.postMessage({
          markdown: md,
          clientVersion: window.currentVersion,
        });
      })();
    });

    window.blockNoteReady = true;

    // Tell the Swift viewer the bridge is live. Idempotent on the
    // Swift side: the viewer's `isEditorReady` flag flips to true on
    // the first message and stays true until the WebContent process
    // crashes; a second post (e.g. React strict-mode double-mount in
    // dev, or any future re-run of this effect) is a no-op there.
    // Optional chaining everywhere because the messageHandlers
    // surface is undefined in the throwaway-WebView smoke test that
    // doesn't register the handler.
    window.webkit?.messageHandlers?.editorReady?.postMessage({});
  }, [editor]);

  return <BlockNoteView editor={editor} theme="dark" />;
}

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("BlockNote bundle: #root element missing in index.html");
}
ReactDOM.createRoot(rootElement).render(<App />);
