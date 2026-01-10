# Straight Up Browser CLI Usage Guide

This document provides comprehensive information about using the Straight Up Browser Command Line Interface (CLI).

## Overview

The CLI allows you to control the Straight Up Browser application programmatically. It communicates with a running instance of the browser through named pipes and temporary files.

## Prerequisites

1. **Browser Application**: The Straight Up Browser app must be running
2. **CLI Tool**: Build the CLI using `./build-cli.sh`

## Basic Usage

### Starting the Browser

```bash
# Launch the browser application
open "/path/to/Straight Up Browser.app"
```

### Basic Commands

```bash
# Create a new tab
./browser-cli-tool new

# Open a URL in a new tab
./browser-cli-tool open https://www.example.com

# Search for content (uses Google)
./browser-cli-tool search "guitar effects pedals"

# Close the current tab
./browser-cli-tool close
```

## Data Extraction

### Get Current Page Data

```bash
./browser-cli-tool get
```

This extracts data from the currently active tab and saves it to a temporary JSON file.

### Get Specific URL Data

```bash
./browser-cli-tool get https://www.sweetwater.com/shop/guitars/guitar-pedals/
```

This opens the URL in a new tab and extracts data from it.

## Response Files

All data extraction commands return results via temporary JSON files:

- **Location**: `/tmp/straight_up_browser_response_*.json`
- **Format**: JSON with page content
- **Cleanup**: Files are automatically cleaned up after reading

### Reading Response Files

```bash
#!/bin/bash
# Extract data and read the response
./browser-cli-tool get https://example.com

# Find and read the response file
RESPONSE_FILE=$(ls /tmp/straight_up_browser_response_*.json | head -1)
if [ -f "$RESPONSE_FILE" ]; then
    cat "$RESPONSE_FILE"
    rm "$RESPONSE_FILE"  # Clean up
fi
```

### Programmatic Usage (Python)

```python
import subprocess
import json
import glob
import time

# Send extraction command
subprocess.run(["./browser-cli-tool", "get", "https://example.com"])

# Wait for response file to appear
time.sleep(2)

# Find and read response
response_files = glob.glob("/tmp/straight_up_browser_response_*.json")
if response_files:
    with open(response_files[0], 'r') as f:
        data = json.load(f)

    print(f"Page Title: {data.get('title')}")
    print(f"URL: {data.get('url')}")
    print(f"Text Content: {data.get('text', '')[:200]}...")

    # Clean up
    import os
    os.remove(response_files[0])
```

## Response File Format

Response files contain JSON with the following structure:

```json
{
  "url": "https://example.com",
  "title": "Example Domain",
  "text": "Full text content of the page...",
  "html": "<!DOCTYPE html>...",
  "links": [
    {
      "text": "Link text",
      "href": "https://example.com/link"
    }
  ],
  "images": [
    {
      "src": "https://example.com/image.jpg",
      "alt": "Alt text"
    }
  ],
  "metaTags": [
    {
      "name": "description",
      "content": "Page description"
    }
  ]
}
```

## Important Considerations

### Browser State

- The browser application must be running for CLI commands to work
- Some operations may require user interaction in the browser window

### CAPTCHA and Human Verification

**⚠️ IMPORTANT**: When scraping websites, you may encounter CAPTCHA challenges or other human verification systems.

**What happens**:
1. CLI opens the page in the browser
2. Browser may display CAPTCHA or verification prompts
3. **You must manually complete verification in the browser window**
4. Then re-run the extraction command

**Example workflow**:
```bash
# Open target page
./browser-cli-tool open "https://www.sweetwater.com/shop/guitars/guitar-pedals/"

# Wait for page to load, then check browser for CAPTCHA
# Complete CAPTCHA in browser window manually
# Then extract data
./browser-cli-tool get
```

**For automated scraping**:
- Choose websites that don't require verification
- Implement delays between requests
- Handle CAPTCHA detection and user notification
- Consider using official APIs when available

### Security

- CLI commands execute in the browser context
- Be cautious with URLs from untrusted sources
- Data extraction includes all page content (HTML, scripts, etc.)
- Consider privacy implications of extracted data

### Performance

- Page loading times vary based on network and content
- Large pages may take longer to extract
- CLI has a 10-second timeout for response files

## Advanced Usage

### Direct Pipe Communication

You can send commands directly to the browser's named pipe:

```bash
echo "open https://github.com" > /tmp/straight_up_browser_commands
```

### Batch Processing

```bash
#!/bin/bash
# Process multiple URLs
URLS=(
    "https://www.sweetwater.com/shop/guitars/guitar-pedals/"
    "https://www.musiciansfriend.com/guitar-effects"
    "https://www.guitarcenter.com/Effects.gc"
)

for url in "${URLS[@]}"; do
    echo "Processing: $url"
    ./browser-cli-tool open "$url"
    sleep 5  # Wait for page load

    # Check if CAPTCHA is needed (manual intervention required)
    echo "Check browser for CAPTCHA, then press Enter to continue..."
    read

    ./browser-cli-tool get

    # Process response file
    RESPONSE_FILE=$(ls /tmp/straight_up_browser_response_*.json | head -1)
    if [ -f "$RESPONSE_FILE" ]; then
        # Process the JSON data
        python3 process_data.py "$RESPONSE_FILE"
        rm "$RESPONSE_FILE"
    fi

    sleep 2  # Rate limiting
done
```

## Troubleshooting

### Common Issues

1. **"Could not send command to browser"**
   - Ensure the Straight Up Browser app is running
   - Check that `/tmp/straight_up_browser_commands` exists

2. **Timeout waiting for response**
   - Page may be taking too long to load
   - Check browser for errors or slow network
   - CAPTCHA may be blocking the page

3. **Empty or malformed response**
   - Page may not have loaded completely
   - JavaScript errors on the target page
   - Content may be loaded dynamically (AJAX)

4. **Permission errors**
   - Ensure `/tmp/` is writable
   - Check file permissions on the CLI tool

### Debug Mode

Enable debug logging in the browser app for troubleshooting:

1. Open browser app
2. Check console logs for CLI command processing
3. Look for JavaScript errors during extraction

## Examples

### Extract Guitar Pedal Data

```bash
#!/bin/bash
# Extract popular guitar pedals from Sweetwater

echo "Opening Sweetwater guitar pedals page..."
./browser-cli-tool open "https://www.sweetwater.com/shop/guitars/guitar-pedals/"

echo "Waiting for page to load..."
sleep 5

echo "Check browser for any CAPTCHA or verification..."
echo "Press Enter when ready to extract data..."
read

echo "Extracting page data..."
./browser-cli-tool get

# Process the response
RESPONSE_FILE=$(ls /tmp/straight_up_browser_response_*.json | head -1)
if [ -f "$RESPONSE_FILE" ]; then
    echo "Data extracted successfully!"
    echo "Response saved to: $RESPONSE_FILE"

    # Extract pedal information (example)
    python3 -c "
import json
import sys

with open('$RESPONSE_FILE', 'r') as f:
    data = json.load(f)

print('Page Title:', data.get('title'))
print('URL:', data.get('url'))
print('Links found:', len(data.get('links', [])))
print('Images found:', len(data.get('images', [])))
"
    rm "$RESPONSE_FILE"
else
    echo "No response file found. Check browser for errors."
fi
```

### Monitor Page Changes

```bash
#!/bin/bash
# Monitor a page for changes

URL="https://www.sweetwater.com/shop/guitars/guitar-pedals/"
INTERVAL=300  # 5 minutes

while true; do
    echo "$(date): Checking $URL"

    ./browser-cli-tool open "$URL"
    sleep 3
    ./browser-cli-tool get

    RESPONSE_FILE=$(ls /tmp/straight_up_browser_response_*.json | head -1)
    if [ -f "$RESPONSE_FILE" ]; then
        # Process and compare with previous data
        python3 check_changes.py "$RESPONSE_FILE"
        rm "$RESPONSE_FILE"
    fi

    echo "Sleeping for $INTERVAL seconds..."
    sleep $INTERVAL
done
```

## API Reference

### Commands

| Command | Arguments | Description |
|---------|-----------|-------------|
| `new` | None | Create a new tab |
| `open` | `<url>` | Open URL in new tab |
| `get` | `[url]` | Extract data from current page or specified URL |
| `search` | `<query>` | Search using Google |
| `close` | None | Close current tab |

### Response File Fields

| Field | Type | Description |
|-------|------|-------------|
| `url` | string | Page URL |
| `title` | string | Page title |
| `text` | string | Extracted text content |
| `html` | string | Full HTML content |
| `links` | array | Array of link objects with `text` and `href` |
| `images` | array | Array of image objects with `src` and `alt` |
| `metaTags` | array | Array of meta tag objects with `name` and `content` |

## Support

For issues or questions:
1. Check this documentation
2. Review browser console logs
3. Test with simple URLs first (example.com)
4. Ensure browser app is running and accessible