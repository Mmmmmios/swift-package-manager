//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import CoreCommands
import Foundation
import PackageModel
import PackageGraph
import SPMBuildCore

import func TSCBasic.exec
import enum TSCBasic.ProcessEnv

/// A card displaying a ``Snippet`` at the terminal.
struct SnippetCard: Card {
    enum Error: Swift.Error, CustomStringConvertible {
        case cantRunSnippet(reason: String)

        var description: String {
            switch self {
            case let .cantRunSnippet(reason):
                return "Can't run snippet: \(reason)"
            }
        }
    }

    /// The snippet to display in the terminal.
    var snippet: Snippet

    /// The snippet's index within its group.
    var number: Int

    /// The tool used for eventually building and running a chosen snippet.
    var swiftCommandState: SwiftCommandState

    func render() -> String {
        let isColorized: Bool = swiftCommandState.options.logging.colorDiagnostics
        var rendered = isColorized ? colorized {
            brightYellow {
                "# "
                snippet.name
            }
            "\n\n"
        }.terminalString()
            :
            plain {
                plain {
                    "# "
                    snippet.name
                }
                "\n\n"
            }.terminalString()

        if !snippet.explanation.isEmpty {
            rendered += isColorized ? brightBlack {
                snippet.explanation
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "// " + $0 }
                    .joined(separator: "\n")
            }.terminalString()
            : plain {
                snippet.explanation
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "// " + $0 }
                    .joined(separator: "\n")
            }.terminalString()

            rendered += "\n\n"
        }

        rendered += snippet.presentationCode

        return rendered
    }

    var inputPrompt: String? {
        return "\nRun this snippet? [R: run, or press Enter to return]"
    }

    func acceptLineInput<S>(_ line: S) async -> CardEvent? where S : StringProtocol {
        let trimmed = line.drop { $0.isWhitespace }.prefix { !$0.isWhitespace }.lowercased()
        guard !trimmed.isEmpty else {
            return .pop()
        }

        switch trimmed {
        case "r", "run":
            do {
                try await runExample()
            } catch {
                return .pop(SnippetCard.Error.cantRunSnippet(reason: error.localizedDescription))
            }
            break
        case "c", "copy":
            print("Unimplemented")
            break
        default:
            break
        }

        return .pop()
    }

    func runExample() async throws {
        print("Building '\(snippet.path)'\n")
        let buildSystem = try await swiftCommandState.createBuildSystem(explicitProduct: snippet.name)
        try await buildSystem.build(subset: .product(snippet.name), buildOutputs: [])
        let executablePath = try swiftCommandState.productsBuildParameters.buildPath.appending(component: snippet.name)
        if let exampleTarget = try await buildSystem.getPackageGraph().module(for: snippet.name) {
            try ProcessEnv.chdir(exampleTarget.sources.paths[0].parentDirectory)
        }
        try exec(path: executablePath.pathString, args: [])
    }
}
