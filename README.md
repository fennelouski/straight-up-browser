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

## Command Line Interface (CLI)

The browser includes a comprehensive command-line interface that allows other applications to control it programmatically. The CLI supports both simple commands and data extraction operations.

### Building the CLI Tool

```bash
# Use the provided build script
./build-cli.sh

# Or build manually
swiftc browser-cli/main.swift -o browser-cli-tool
```

### CLI Architecture

The CLI communicates with the running browser application through:
- **Command Channel**: Named pipe at `/tmp/straight_up_browser_commands`
- **Response Channel**: Temporary files in `/tmp/` for commands that return data

**Important**: The browser application must be running for CLI commands to work.

### Usage

#### Basic Commands

```bash
# Open a URL in a new tab
./browser-cli-tool open https://www.apple.com

# Search for something (uses Google)
./browser-cli-tool search "swift programming"

# Create a new tab
./browser-cli-tool new

# Close current tab
./browser-cli-tool close
```

#### Data Extraction Commands

```bash
# Extract data from current page
./browser-cli-tool get

# Extract data from specific URL (opens in new tab)
./browser-cli-tool get https://example.com
```

### Response Handling for Data Commands

Commands that extract data (`get`) return results via temporary JSON files:

1. **File Location**: Responses are written to `/tmp/straight_up_browser_response_*.json`
2. **Format**: JSON containing page title, URL, HTML content, text content, links, and images
3. **Lifetime**: Files are automatically cleaned up after reading

**Example Response File Content**:
```json
{
  "url": "https://example.com",
  "title": "Example Domain",
  "text": "Example Domain\nThis domain is for use in illustrative examples...",
  "links": [
    {
      "text": "More information...",
      "href": "https://www.iana.org/domains/example"
    }
  ]
}
```

### Programmatic Usage

#### From Shell Scripts

```bash
#!/bin/bash
# Open Sweetwater and extract guitar pedal data
./browser-cli-tool open "https://www.sweetwater.com/shop/guitars/guitar-pedals/"
sleep 3
./browser-cli-tool get
```

#### From Other Applications

```python
import subprocess
import json
import glob

# Send command
subprocess.run(["./browser-cli-tool", "get", "https://example.com"])

# Read response
response_files = glob.glob("/tmp/straight_up_browser_response_*.json")
if response_files:
    with open(response_files[0], 'r') as f:
        data = json.load(f)
    print(f"Page title: {data.get('title')}")
```

### Important Notes

#### Browser State Requirements
- The Straight Up Browser application must be running
- Some websites may require user interaction (CAPTCHA verification, login, etc.)
- The browser may display dialogs that require user attention

#### CAPTCHA and Human Verification
When scraping websites, you may encounter CAPTCHA challenges or other human verification systems. The CLI will open the page, but you may need to:

1. **Switch to the browser application**
2. **Complete any CAPTCHA or verification**
3. **Then run the extraction command**

For automated scraping, consider websites that don't require human verification or implement appropriate delays and error handling.

#### Security Considerations
- CLI commands execute in the context of the running browser
- Be cautious with URLs from untrusted sources
- Data extraction includes all page content (HTML, scripts, etc.)

### Integration with Other Apps

You can send commands directly to the named pipe:

```bash
echo "open https://github.com" > /tmp/straight_up_browser_commands
```

Or use the CLI tool for more complex operations with response handling.

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
- **Logger**: Compile-time filtering logging system for debugging

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
- [x] Import/export bookmarks (Chrome, Edge support; Safari/Firefox in progress)
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
- [x] Crash recovery and session restoration

### 🛠️ Developer Features

#### CLI Integration
- [x] Enhanced CLI commands (page data extraction, tab management, bookmark operations)
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
