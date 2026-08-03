//
//  WallClockScanTests.swift
//  ATCSimKitTests
//
//  This package is the simulation. It must not read a real clock, anywhere, for any reason.
//
//  Stricter than the app's equivalent scan, and it can be: there is no presentation layer here to make an
//  exception for. Every file is either simulation state or the maths that advances it, and simulated time
//  comes from `SimulationClock`.
//
//  The app enforces the same rule over its own simulation files in `DeterministicTimeTests`.
//

import XCTest
@testable import ATCSimKit

final class WallClockScanTests: XCTestCase {

    private static let wallClockAPIs = [
        "Date()",
        "CACurrentMediaTime",
        "CFAbsoluteTimeGetCurrent",
        "DispatchTime.now",
        "DispatchWallTime",
        "asyncAfter",
        "Task.sleep",
        "Thread.sleep",
        "systemUptime",
        "Timer(",
        "Timer.scheduledTimer",
    ]

    /// No wall clock, and no timer either.
    ///
    /// The app owns the one timer that decides *when* to step; this package only knows *how much* a step
    /// is, which is one simulated second. A timer in here would be a second thing deciding when the
    /// simulation advances, and two of those cannot stay in step across a speed change or a pause.
    func testThisPackageNeverReadsAWallClock() throws {
        var offences: [String] = []

        for url in try Self.sources() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                // The comments in SimulationClock name these APIs deliberately, to say they are banned.
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }

                for api in Self.wallClockAPIs where code.contains(api) {
                    offences.append("\(url.lastPathComponent):\(number + 1) — \(api)")
                }
            }
        }

        XCTAssertTrue(offences.isEmpty, """
            The simulation engine is reading real time here:

            \(offences.joined(separator: "\n            "))

            Simulated time is SimulationClock.tick and nothing else. A real-time call behaves differently \
            at 1x, at 30x, while paused, and under replay — and no ordinary test notices, because nothing \
            fails. It simply does the wrong thing quietly.
            """)
    }

    /// The scan is not passing because it is broken.
    func testTheScanWouldCatchAViolation() {
        for line in ["let now = Date()", "DispatchQueue.main.asyncAfter(deadline: .now() + 1)",
                     "Timer(timeInterval: 1, repeats: true) { _ in }"] {
            XCTAssertTrue(Self.wallClockAPIs.contains(where: line.contains),
                          "the scan would have missed: \(line)")
        }
        XCTAssertFalse(Self.wallClockAPIs.contains(where: "clock.advance()".contains))
    }

    private static func sources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ATCSimKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent("Sources/ATCSimKit")

        guard let walker = FileManager.default.enumerator(at: root,
                                                         includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [URL] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            found.append(file)
        }
        XCTAssertGreaterThan(found.count, 5, "the scan found almost nothing — the path is wrong")
        return found
    }
}
