#!/usr/bin/env swift
//
//  main.swift
//  browser-cli
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation

// TODO: Enhance CLI tool features
// - Add JSON output format option (--json)
// - Support for configuration files
// - Batch command execution from file
// - Interactive mode with tab completion
// - Authentication for remote browser control
// - Progress indicators for long operations
// - Error handling with detailed exit codes
// - Logging and verbose output options

// Command line interface for Straight Up Browser
// Usage: browser-cli <command> [arguments]

enum Command: String {
    case open
    case get
    case search
    case close
    case new
}

func printUsage() {
    print("""
    Straight Up Browser CLI

    Usage: browser-cli <command> [arguments]

    Commands:
      open <url>        Open URL in new tab
      get [url]         Get page data from URL or current page
      search <query>    Search for query
      close             Close active tab
      new               Create new tab

    Examples:
      browser-cli open https://www.apple.com
      browser-cli search "swift programming"
      browser-cli new
    """)
}

func sendCommand(_ command: String, expectsResponse: Bool = false) -> String? {
    let pipePath = "/tmp/straight_up_browser_commands"

    var commandWithResponse = command
    var responseFile: URL?

    if expectsResponse {
        // Create a response file in /tmp which should be accessible to both processes
        let responseFilename = "straight_up_browser_response_\(UUID().uuidString).json"
        responseFile = URL(fileURLWithPath: "/tmp/\(responseFilename)")
        commandWithResponse += " --response-file \(responseFile!.path)"
        print("Expecting response in file: \(responseFile!.path)")
    }

    do {
        try commandWithResponse.write(toFile: pipePath, atomically: true, encoding: .utf8)
        print("Command sent: \(command)")

        if expectsResponse, let responseFile = responseFile {
            // Wait for response file to be created and read it
            let maxWaitTime = 10.0 // 10 seconds
            let startTime = Date()

            while Date().timeIntervalSince(startTime) < maxWaitTime {
                if FileManager.default.fileExists(atPath: responseFile.path) {
                    do {
                        let responseData = try String(contentsOf: responseFile, encoding: .utf8)
                        // Clean up the response file
                        try? FileManager.default.removeItem(at: responseFile)
                        return responseData
                    } catch {
                        print("Error reading response file: \(error)")
                        try? FileManager.default.removeItem(at: responseFile)
                        return nil
                    }
                }
                Thread.sleep(forTimeInterval: 0.1) // Wait 100ms before checking again
            }

            print("Timeout waiting for response from browser")
            try? FileManager.default.removeItem(at: responseFile)
            return nil
        }

        return nil
    } catch {
        print("Error: Could not send command to browser. Make sure Straight Up Browser is running.")
        print("Error details: \(error)")
        exit(1)
    }
}

func handleGetCommand(arguments: [String]) {
    // For now, send the command via pipe and the app will log results
    // In a future version, this will return the data directly
    var fullCommand = "get"

    if arguments.count > 2 {
        let parameter = arguments[2..<arguments.count].joined(separator: " ")
        fullCommand += " \(parameter)"
    } else {
        fullCommand += " current"
    }

    sendCommand(fullCommand)
    print("Command sent. Check the Straight Up Browser app console for results.")
    print("Future versions will return data directly to CLI.")
}

func main() {
    let arguments = CommandLine.arguments

    guard arguments.count >= 2 else {
        printUsage()
        exit(1)
    }

    let commandString = arguments[1].lowercased()

    guard let command = Command(rawValue: commandString) else {
        print("Error: Unknown command '\(commandString)'")
        printUsage()
        exit(1)
    }

    if command == .get {
        // Use browser tools to get page data
        handleGetCommand(arguments: arguments)
    } else {
        // Use the traditional pipe-based communication for other commands
        var fullCommand = commandString

        if arguments.count > 2 {
            let parameter = arguments[2..<arguments.count].joined(separator: " ")
            fullCommand += " \(parameter)"
        }

        sendCommand(fullCommand)
    }
}

main()
