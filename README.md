# Straight Up Browser

A minimal, efficient web browser for macOS with left-side tabs, popup omnibar, and command-line interface.

## Features

### Core Features
- **Left-side tabs**: Clean, vertical tab layout instead of traditional top tabs
- **Popup omnibar**: Press `⌥Space` to quickly navigate to URLs or search
- **Maximized vertical space**: Window optimized for content viewing
- **Full keyboard shortcuts**: All common browser shortcuts work out of the box
- **Command-line interface**: Control the browser from other applications

### Keyboard Shortcuts
- `⌥Space` - Show omnibar
- `⌘T` - New tab
- `⌘W` - Close current tab
- `⌘R` - Reload page
- `⌘L` - Focus address bar (opens omnibar)
- `⌘[` - Go back
- `⌘]` - Go forward

## Command Line Interface

The browser includes a command-line interface that allows other applications to control it.

### Building the CLI Tool

```bash
swiftc browser-cli/main.swift -o browser-cli
```

### Usage

```bash
# Open a URL in a new tab
./browser-cli open https://www.apple.com

# Search for something
./browser-cli search "swift programming"

# Get page data (for scraping)
./browser-cli get https://example.com

# Create a new tab
./browser-cli new

# Close current tab
./browser-cli close
```

### Integration with Other Apps

The CLI communicates with the browser via a named pipe at `/tmp/straight_up_browser_commands`. You can send commands directly:

```bash
echo "open https://github.com" > /tmp/straight_up_browser_commands
```

## Building the Application

```bash
cd "Straight Up Browser"
xcodebuild -scheme "Straight Up Browser" -configuration Release build
```

## Architecture

- **WebView**: Custom NSViewRepresentable wrapper around WKWebView
- **Tab Model**: SwiftData-powered tab management with history
- **Omnibar**: Popup search/navigation interface
- **CLI**: Named pipe-based inter-process communication

## Future Development Roadmap

### 🚀 High Priority Features

#### Tab Management
- [ ] Tab state persistence across app restarts
- [ ] Tab reordering with drag and drop
- [ ] Tab pinning (keep important tabs at front)
- [ ] Recently closed tabs (Cmd+Shift+T to reopen)
- [ ] Tab groups/workspaces
- [ ] Tab thumbnails/previews

#### Navigation & History
- [ ] Enhanced history management with timestamps
- [ ] History search and filtering
- [ ] Forward/back gesture improvements
- [ ] URL validation and security warnings
- [ ] Auto-complete in omnibar
- [ ] Multiple search engine support

#### User Interface
- [ ] Omnibar animations and transitions
- [ ] Find-in-page functionality (Cmd+F)
- [ ] Page zoom controls (Cmd+/-)
- [ ] Reader mode toggle
- [ ] Full-screen optimizations
- [ ] Dark/light mode support

### 🔧 Medium Priority Features

#### Bookmarks & Organization
- [ ] Bookmark management system
- [ ] Bookmark folders and organization
- [ ] Bookmark sync across devices
- [ ] Import/export bookmarks
- [ ] Quick bookmark access in omnibar

#### Privacy & Security
- [ ] Cookie management
- [ ] Tracking protection
- [ ] Ad blocking/content blockers
- [ ] HTTPS Everywhere enforcement
- [ ] Password management
- [ ] Form auto-fill

#### Performance
- [ ] Page preload for faster navigation
- [ ] Memory management for multiple tabs
- [ ] Cache management
- [ ] Background tab throttling
- [ ] Crash recovery and session restoration

### 🛠️ Developer Features

#### CLI Integration
- [ ] Enhanced CLI commands (screenshot, PDF export, etc.)
- [ ] JavaScript injection capabilities
- [ ] Cookie inspection and management
- [ ] Network request monitoring
- [ ] Extension API for CLI plugins

#### Extensions & Customization
- [ ] Browser extension system
- [ ] Theme customization
- [ ] Keyboard shortcut customization
- [ ] User script support
- [ ] Custom CSS injection

#### Advanced Features
- [ ] Developer tools integration
- [ ] WebRTC and media controls
- [ ] Download manager
- [ ] Print preview and customization
- [ ] Touch Bar support
- [ ] Notification integration

### 🐛 Bug Fixes & Edge Cases

#### Tab Handling
- [ ] Proper handling of closing last tab
- [ ] Tab state during app minimization
- [ ] Memory cleanup when tabs are closed
- [ ] URL encoding/decoding edge cases

#### Navigation
- [ ] Handling of invalid URLs gracefully
- [ ] Redirect loop detection
- [ ] Mixed content warnings
- [ ] SSL certificate validation display

#### UI/UX
- [ ] Keyboard focus management
- [ ] Window resizing edge cases
- [ ] High DPI display support
- [ ] Accessibility improvements

### 📚 Documentation & Testing

#### Testing
- [ ] Unit tests for core functionality
- [ ] UI tests for critical user flows
- [ ] Performance benchmarking
- [ ] Memory leak detection

#### Documentation
- [ ] API documentation for CLI
- [ ] Extension development guide
- [ ] User manual and tutorials
- [ ] Contributing guidelines

## Requirements

- macOS 15.0+
- Xcode 16+
- Swift 6+

## Contributing

See the TODO comments throughout the codebase for specific implementation details and requirements for each feature.

## License

This project is open source. Feel free to use and modify as needed.
