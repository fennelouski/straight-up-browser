import Foundation

/// =============================================================================
/// STRAIGHT UP BROWSER LOGGER - COMPILE-TIME FILTERING SYSTEM
/// =============================================================================
///
/// This logger provides compile-time filtering to control log verbosity without
/// runtime performance impact. Logs are filtered out at compile time, so excluded
/// logs don't even exist in the final binary.
///
/// SETUP:
/// 1. Modify the filter arrays below to control what gets logged
/// 2. Rebuild your app - filtering happens at compile time
/// 3. Call Logger.printFilterStatus() in your app to verify configuration
///
/// USAGE IN CODE:
///   Logger.log("Something happened", type: "MyClass")
///   Logger.debug("Debug info", type: "MyClass")
///   Logger.info("Info message", type: "MyClass")
///   Logger.warning("Warning message", type: "MyClass")
///   Logger.error("Error message", type: "MyClass")
///
/// =============================================================================

/// Compile-time logging configuration
/// Modify these arrays to control which logs are compiled in/out
///
/// USAGE:
/// 1. EXCLUDE mode: Add items to excludedFiles/excludedTypes/excludedFunctions to block them
/// 2. SOLO mode: Add items to soloFiles/soloTypes/soloFunctions to ONLY show those (takes precedence over exclude)
/// 3. Leave arrays empty for no filtering (all logs enabled)
///
/// COMMON CONFIGURATIONS:
///
/// 1. Debug only WebView-related code:
///    soloTypes = ["WebView", "WebViewManager"]
///
/// 2. Disable noisy favicon logging:
///    excludedFunctions = ["downloadFavicon(from:webView:)", "findAlternativeImage(for:)"]
///
/// 3. Focus on tab management:
///    soloTypes = ["TabManager", "Tab"]
///
/// 4. Disable all ContentView logging:
///    excludedTypes = ["ContentView"]
///
/// 5. Debug a specific file:
///    soloFiles = ["WebView.swift"]
///
/// 6. Quiet mode (disable most logging):
///    excludedTypes = ["WebView", "ContentView", "TabManager", "WebViewManager"]

// Files to exclude from logging (case-sensitive, filename only, e.g., "WebView.swift")
private let excludedFiles: Set<String> = [
    // Add filenames here to exclude entire files from logging
]

// Types (classes/structs) to exclude from logging (e.g., "WebView", "TabManager")
private let excludedTypes: Set<String> = [
    // Add type names here to exclude all logs from specific classes/structs
]

// Functions to exclude from logging (exact match, e.g., "getCurrentWebView()")
private let excludedFunctions: Set<String> = [
    // Add function names here to exclude specific functions from logging
]

// SOLO MODE: If soloFiles is not empty, ONLY these files will be logged
private let soloFiles: Set<String> = [
    // Uncomment and add filenames to enable solo mode for files
]

// SOLO MODE: If soloTypes is not empty, ONLY these types will be logged
private let soloTypes: Set<String> = [
    // Uncomment and add type names to enable solo mode for types
]

// SOLO MODE: If soloFunctions is not empty, ONLY these functions will be logged
private let soloFunctions: Set<String> = [
    // Uncomment and add function names to enable solo mode for functions
]

// DEBUG MODE: Set to true to bypass all filters (shows all logs regardless of configuration)
private let debugMode: Bool = false

/// A logger that captures contextual information about where the log was called from
struct Logger {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Check if logging should be allowed for the given context
    @inline(__always)
    private static func shouldLog(
        file: String,
        type: String,
        function: String
    ) -> Bool {
        // DEBUG MODE: Bypass all filters
        if debugMode {
            return true
        }

        let filename = (file as NSString).lastPathComponent

        // SOLO MODE: If any solo filters are active, only allow matches
        if !soloFiles.isEmpty && !soloFiles.contains(filename) {
            return false
        }
        if !soloTypes.isEmpty && !soloTypes.contains(type) {
            return false
        }
        if !soloFunctions.isEmpty && !soloFunctions.contains(function) {
            return false
        }

        // EXCLUDE MODE: Block excluded items
        if excludedFiles.contains(filename) {
            return false
        }
        if excludedTypes.contains(type) {
            return false
        }
        if excludedFunctions.contains(function) {
            return false
        }

        return true
    }

    /// Log a message with contextual information
    /// - Parameters:
    ///   - message: The message to log
    ///   - type: The type (class/struct) where the log is called from
    ///   - file: The file name (automatically captured)
    ///   - function: The function name (automatically captured)
    ///   - line: The line number (automatically captured)
    static func log(
        _ message: String,
        type: String = "",
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        guard shouldLog(file: file, type: type, function: function) else { return }

        let timestamp = dateFormatter.string(from: Date())
        let filename = (file as NSString).lastPathComponent
        let context = type.isEmpty ? "" : "[\(type)] "

        print("\(timestamp) \(filename):\(line) \(function) \(context)\(message)")
    }

    /// Log a debug message
    static func debug(
        _ message: String,
        type: String = "",
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log("[DEBUG] \(message)", type: type, file: file, function: function, line: line)
    }

    /// Log an info message
    static func info(
        _ message: String,
        type: String = "",
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log("[INFO] \(message)", type: type, file: file, function: function, line: line)
    }

    /// Log a warning message
    static func warning(
        _ message: String,
        type: String = "",
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log("[WARNING] \(message)", type: type, file: file, function: function, line: line)
    }

    /// Log an error message
    static func error(
        _ message: String,
        type: String = "",
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log("[ERROR] \(message)", type: type, file: file, function: function, line: line)
    }

    // MARK: - Configuration Helpers

    /// Print current filter configuration status to console
    static func printFilterStatus() {
        Swift.print(getFilterStatus())
    }

    /// Get current filter configuration status (for debugging filter setup)
    static func getFilterStatus() -> String {
        var status = "Logger Filter Status:\n"
        status += "DEBUG MODE: \(debugMode ? "ENABLED (all filters bypassed)" : "DISABLED")\n\n"

        if !soloFiles.isEmpty {
            status += "SOLO FILES: \(soloFiles.sorted())\n"
        } else if !excludedFiles.isEmpty {
            status += "EXCLUDED FILES: \(excludedFiles.sorted())\n"
        } else {
            status += "FILES: All enabled\n"
        }

        if !soloTypes.isEmpty {
            status += "SOLO TYPES: \(soloTypes.sorted())\n"
        } else if !excludedTypes.isEmpty {
            status += "EXCLUDED TYPES: \(excludedTypes.sorted())\n"
        } else {
            status += "TYPES: All enabled\n"
        }

        if !soloFunctions.isEmpty {
            status += "SOLO FUNCTIONS: \(soloFunctions.sorted())\n"
        } else if !excludedFunctions.isEmpty {
            status += "EXCLUDED FUNCTIONS: \(excludedFunctions.sorted())\n"
        } else {
            status += "FUNCTIONS: All enabled\n"
        }

        return status
    }
}