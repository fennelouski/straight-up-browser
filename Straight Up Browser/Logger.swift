//
//  Logger.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import Combine
import os

enum LogPayloadVisibility: Equatable {
    case `private`
    case `public`
}

/// Thin wrapper over unified logging. View output in Console.app or with:
///   log stream --predicate 'subsystem == "com.straightupbrowser"'
struct Logger {
    nonisolated private static let logger = os.Logger(subsystem: "com.straightupbrowser", category: "app")
    nonisolated static let defaultPayloadVisibility: LogPayloadVisibility = .private

    nonisolated static func log(
        _ message: String,
        type: String = "",
        visibility: LogPayloadVisibility = defaultPayloadVisibility,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let filename = (file as NSString).lastPathComponent
        let context = type.isEmpty ? "" : "[\(type)] "
        switch visibility {
        case .private:
            // Navigation URLs, incognito state, form values, and CLI payloads all
            // flow through this logger. Keep dynamic data private unless a caller
            // deliberately opts a coarse, non-user-derived event into visibility.
            logger.debug("\(filename, privacy: .public):\(line) \(context, privacy: .public)\(message, privacy: .private)")
        case .public:
            logger.debug("\(filename, privacy: .public):\(line) \(context, privacy: .public)\(message, privacy: .public)")
        }
    }

    nonisolated static func debug(_ message: String, type: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        log("[DEBUG] \(message)", type: type, file: file, function: function, line: line)
    }

    nonisolated static func info(_ message: String, type: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        log("[INFO] \(message)", type: type, file: file, function: function, line: line)
    }

    nonisolated static func warning(_ message: String, type: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        log("[WARNING] \(message)", type: type, file: file, function: function, line: line)
    }

    nonisolated static func error(_ message: String, type: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        log("[ERROR] \(message)", type: type, file: file, function: function, line: line)
    }
}

struct PersistenceIssue: Identifiable, Equatable {
    let id = UUID()
    let operation: String
    let message: String
}

@MainActor
final class PersistenceDiagnostics: ObservableObject {
    static let shared = PersistenceDiagnostics()
    @Published var latestIssue: PersistenceIssue?

    func report(operation: String, error: Error) {
        Logger.error("\(operation): \(error.localizedDescription)", type: "Persistence")
        latestIssue = PersistenceIssue(
            operation: operation,
            message: error.localizedDescription
        )
    }
}
