# Named browser windows

Use **File → New Window** (⌘N). Each additional window starts with its own
workspace and independent tab selection, split panes, private tabs, and undo
stack. Existing tabs remain in the original window's workspace. The workspace
menu can switch the current window to another saved workspace; switching in one
window does not change the others.

Use **File → Rename Window…** to name a window. Names appear in macOS's Window
menu. Open windows, their workspace selections, and their individual frames
are restored on launch. Closing a window preserves its workspace's tabs; the
workspace remains available from the workspace menu. **File → Close Window**
(⌥⇧⌘W) closes only that window. Closing its final tab closes that window when
other browser windows are open; the final browser window retains the existing
quit-on-last-tab behavior.

Enable **Settings → Appearance → Window → Use native full screen**, then use
⌃⌘F to enter or leave a native macOS full-screen Space. The page fills the window
and the sidebar, top tabs, and docked panels are hidden. The menu bar and Dock
stay hidden until reached with the pointer, following standard macOS full-screen
behavior. ⌘L opens the omnibar immediately. Each full-screen window occupies its
own Space, so the configured macOS trackpad gesture can switch between them.
Disabling this setting returns full-screen windows to normal windows; with it
off, ⌃⌘F uses the existing saved window layout.

Window identity and view state are stored locally in UserDefaults. Tabs and
workspace documents continue to use the existing SwiftData database. Window
commands are routed to their registered native window independently of whether
a WebKit page has attached yet. The first window migrates the old split, undo,
and frame state. Global privacy clearing removes all per-window undo stacks.
