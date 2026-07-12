#!/usr/bin/env swift
//
//  main.swift
//  browser-cli
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation

// Command line interface for Straight Up Browser
// Usage: browser-cli <command> [arguments]
//
// Talks to the running app over a named pipe in the app's own Application
// Support directory (owner-only permissions). Data commands pass a response
// file path inside the app's response directory and poll it for the result.

let supportDirectory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Straight Up Browser", isDirectory: true)
let pipePath = supportDirectory.appendingPathComponent("cli.pipe").path
let responseDirectory = supportDirectory.appendingPathComponent("responses", isDirectory: true)

enum Command: String {
    case open
    case get
    case search
    case close
    case new
    case tabs
}

func printUsage() {
    print("""
    Straight Up Browser CLI

    Usage: browser-cli <command> [arguments]

    Commands:
      open <url>        Open URL in the browser
      get [url]         Get page data (JSON) from URL or current page
      search <query>    Search for query
      close             Close active tab
      new               Create new tab
      tabs              List open tabs (JSON)

    Examples:
      browser-cli open https://www.apple.com
      browser-cli search "swift programming"
      browser-cli get current
      browser-cli tabs
    """)
}

// Write a command line into the FIFO. O_NONBLOCK makes open() fail with ENXIO
// when no reader (the app) is on the other end instead of hanging forever.
// A plain write(toFile:atomically:true) would rename() over the FIFO and
// destroy it - never do that.
func sendCommand(_ command: String) {
    let fd = open(pipePath, O_WRONLY | O_NONBLOCK)
    guard fd >= 0 else {
        print("Error: Could not reach the browser. Make sure Straight Up Browser is running.")
        exit(1)
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    handle.write((command + "\n").data(using: .utf8)!)
    try? handle.close()
}

// Send a command that produces a JSON response and print it to stdout.
// Only the response FILENAME goes over the pipe (the full path contains
// spaces, and the app only writes inside its own response directory).
func sendCommandExpectingResponse(_ command: String) {
    try? FileManager.default.createDirectory(at: responseDirectory, withIntermediateDirectories: true)
    let responseName = "response_\(UUID().uuidString).json"
    let responseFile = responseDirectory.appendingPathComponent(responseName)

    sendCommand("\(command) --response-file \(responseName)")

    let deadline = Date().addingTimeInterval(15.0)
    while Date() < deadline {
        if let response = try? String(contentsOf: responseFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: responseFile)
            print(response)
            return
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    try? FileManager.default.removeItem(at: responseFile)
    print("Error: Timeout waiting for response from browser.")
    exit(1)
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
        fullCommand += " " + arguments[2...].joined(separator: " ")
    }

    switch command {
    case .get:
        if arguments.count <= 2 {
            fullCommand += " current"
        }
        sendCommandExpectingResponse(fullCommand)
    case .tabs:
        sendCommandExpectingResponse(fullCommand)
    case .open, .search, .close, .new:
        sendCommand(fullCommand)
        print("Command sent: \(fullCommand)")
    }
}

main()
