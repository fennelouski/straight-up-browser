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
      get <url>         Get page data from URL
      search <query>    Search for query
      close             Close active tab
      new               Create new tab

    Examples:
      browser-cli open https://www.apple.com
      browser-cli search "swift programming"
      browser-cli new
    """)
}

func sendCommand(_ command: String) {
    let pipePath = "/tmp/straight_up_browser_commands"

    do {
        try command.write(toFile: pipePath, atomically: true, encoding: .utf8)
        print("Command sent: \(command)")
    } catch {
        print("Error: Could not send command to browser. Make sure Straight Up Browser is running.")
        print("Error details: \(error)")
        exit(1)
    }
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

    var fullCommand = commandString

    if arguments.count > 2 {
        let parameter = arguments[2..<arguments.count].joined(separator: " ")
        fullCommand += " \(parameter)"
    }

    sendCommand(fullCommand)
}

main()
