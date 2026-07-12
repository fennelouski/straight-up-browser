//
//  Logger.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import os

/// Thin wrapper over unified logging. View output in Console.app or with:
///   log stream --predicate 'subsystem == "com.straightupbrowser"'
struct Logger {
    private static let logger = os.Logger(subsystem: "com.straightupbrowser", category: "app")

    static func log(
        _ message: String,
        type: String = "",
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let filename = (file as NSString).lastPathComponent
        let context = type.isEmpty ? "" : "[\(type)] "
        logger.debug("\(filename, privacy: .public):\(line) \(context, privacy: .public)\(message, privacy: .public)")
    }

    static func debug(_ message: String, type: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        log("[DEBUG] \(message)", type: type, file: file, function: function, line: line)
    }

    static func info(_ message: String, type: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        log("[INFO] \(message)", type: type, file: file, function: function, line: line)
    }

    static func warning(_ message: String, type: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        log("[WARNING] \(message)", type: type, file: file, function: function, line: line)
    }

    static func error(_ message: String, type: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        log("[ERROR] \(message)", type: type, file: file, function: function, line: line)
    }
}
