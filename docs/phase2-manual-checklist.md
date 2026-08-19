# Phase 2 — Manual test checklist

**Status: NOT yet run.** Phase 2 shipped with the automated suite green but before any hands-on pass — these checks are the outstanding verification debt. Work through them at your leisure; anything that fails is a Phase 2 bug, not a known limitation (the known limitations are docs/phase2-design.md §12). The iPad section especially: deviation #6 (documents are full-screen only on iPad, no document-in-split) was flagged for review and needs your explicit "fine" or a follow-up.

Unit tests cover the editor core, resolution, conflicts, transcripts, and pane rules headlessly. This checklist covers what only hands on real devices can: the anchor creation gesture end to end, iCloud behaving like iCloud, and the panes feeling right.

**Setup for both platforms:** signed into iCloud, `tabSyncEnabled` on, at least one workspace with a few tabs. First run after this build: check Settings → iCloud shows the app under iCloud Drive (new CloudDocuments entitlement).

## Mac

### Anchor creation, end to end
- [ ] In a workspace, open an article tab, select a sentence, press **⌥⇧⌘D**. Expect: transient note "Anchored to 'Notes' — link copied"; a `Notes.md` appears in the sidebar's Documents block (auto-created on first anchor).
- [ ] Open the document (click its sidebar row): the appended line renders as a **pill** (tinted background), not raw Markdown; caret on that line reveals the syntax faintly.
- [ ] Paste (⌘V) into the middle of a paragraph — the same link lands wherever you paste; after ~2s (autosave) both occurrences still render enriched.
- [ ] Right-click a selection on a page → "Anchor Selection to Document" does the same as the keystroke.
- [ ] With **no selection** on an article: ⌥⇧⌘D anchors the whole page (link text = page title).
- [ ] On a YouTube tab mid-playback, no selection: ⌥⇧⌘D → link text "Title at m:ss"; clicking the pill later opens the video **seeked to that time**.
- [ ] Outside any workspace: the gesture shows "Open a workspace to anchor sources into it." and writes nothing.
- [ ] In an incognito tab: "Private tabs are never captured."

### Pills and the open setting
- [ ] Click a pill (default setting): **peek popover** — quote, host, disposition — and "Open Source" opens the source **beside the document in a split**, scrolled to the text fragment (Safari/Chrome render `#:~:text=`).
- [ ] Settings → General → Research Anchors → "Beside the document": click opens the split directly, reusing an existing tab for that source if the workspace has one.
- [ ] "As a tab": click behaves like a normal link (single view).
- [ ] A plain `[link](https://…)` you type by hand opens as a normal tab and never grows a pill.

### Documents as panes (ADR 0008)
- [ ] Shift-click a document row → document joins a split beside the current tab; the focused pane border follows clicks between panes.
- [ ] **⌘W** with the document focused closes the pane only; the sidebar row stays; no disposition is written (check seen-before later: the *source* tabs unaffected).
- [ ] **⌘L** with the document focused opens the editor's find bar, not the omnibar.
- [ ] Switching workspace (⇧⌘W or menu) drops document panes; returning shows them in the sidebar again.
- [ ] ⌃⌘N creates "Untitled", opens it focused; rename via double-click works and renames the file in iCloud Drive (check Finder).

### iCloud coordination
- [ ] Open a document, then edit the same file in Finder (TextEdit): with the app's editor **clean**, it reloads silently within a few seconds.
- [ ] Type in the editor (don't wait for autosave), then change the file externally: the external version appears as a "**(conflict, …)**" sibling document in the sidebar; your typing survives on the original; a transient note announces it.
- [ ] Drop a stray `.md` into the workspace's folder in Finder → it appears as a document row (adoption).
- [ ] Delete a document from the sidebar → file gone from Finder, row gone; anchors still resolve in other documents.

### Transcripts
- [ ] On a captured YouTube tab: **⌃⌘T** opens the transcript panel; search filters lines; clicking a line seeks the video.
- [ ] Select a line (shift-click to extend) → **Anchor** → a timestamped anchor lands in the current document; its pill opens the video seeked.
- [ ] A video with captions disabled: "No transcript available." + Retry.
- [ ] Omnibar: type a distinctive phrase said in a captured video → a "m:ss · <title>" row appears below ordinary suggestions and opens the video seeked.

## iPhone

### Anchor creation, end to end (the hundred-tabs flow)
- [ ] In a workspace, select text on a page → **"Anchor"** in the callout bar next to Copy. Expect: the transient capsule "Anchored to 'Notes' — link copied"; no visible mode change; you stay on the page.
- [ ] Repeat across several tabs quickly (select → Anchor → swipe to next tab): each lands in the same document; nothing steals focus.
- [ ] Swipe down → workspace switcher → **"Anchor This Page"** anchors with no selection (whole page / video timestamp).
- [ ] Open the sidebar → Documents → the document: every anchored line is there, pills enriched; the appended links are pasteable from the clipboard too.
- [ ] Tap a pill → the source opens **full screen**, scrolled/seeked; sidebar → document returns you.
- [ ] Outside a workspace / in a private tab: correct refusal notes.

### Documents on iPhone
- [ ] Selecting a document shows it full screen where the page was; the X (or selecting any tab) returns to browsing.
- [ ] Editing: keyboard has no smart quotes mangling `**bold**` or links; typed Markdown styles live; syntax marks fade off the caret line.
- [ ] Edit the same document on the Mac; iPhone (clean editor) picks up the change. Edit on both within seconds: a conflict sibling appears rather than losing either.
- [ ] Files app → iCloud Drive → Browser: documents visible, readable, plain Markdown.

### Transcripts on iPhone
- [ ] Workspace switcher → "Video Transcript" on a captured YouTube tab → sheet with lines; tap seeks; long-press a line → "Anchor This Line".
- [ ] Omnibar transcript rows appear as on Mac.

### iPad spot-check
- [ ] Documents behave as on iPhone (full-screen display; document-in-split is Mac-only this phase — flagged deviation #6, confirm you can live with it).
- [ ] Hardware keyboard: ⌥⇧⌘D / ⌃⌘N / ⌃⌘T fire from the Bookmarks menu group.

## Cross-device
- [ ] Anchor on the Mac → within a minute the iPhone's same workspace shows the document row and, once iCloud Drive syncs the file, its content with the pill enriched (anchor row came via CloudKit, bytes via iCloud Drive — brief "Waiting for iCloud…" is normal, not a bug).
- [ ] A transcript fetched on the Mac is searchable from the iPhone omnibar without re-fetching.
