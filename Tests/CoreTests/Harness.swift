import CoreGraphics
import Foundation
import ImageIO

/// A ~100 line test harness.
///
/// Command Line Tools ship neither XCTest nor swift-testing, so `swift test`
/// can't run on a machine without Xcode. These tests are an ordinary executable
/// instead: `swift run CoreTests` (or `make test`).
enum Check {
    nonisolated(unsafe) static var currentSuite = ""
    nonisolated(unsafe) static var currentTest = ""
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var testFailures = 0
    nonisolated(unsafe) static var passed = 0

    struct RequirementFailure: Error {
        let message: String
    }
}

func suite(_ name: String, _ body: () -> Void) {
    Check.currentSuite = name
    print("\u{001B}[1m\(name)\u{001B}[0m")
    body()
    print("")
}

func test(_ name: String, _ body: () throws -> Void) {
    Check.currentTest = name
    let failuresBefore = Check.failures.count
    do {
        try body()
    } catch let failure as Check.RequirementFailure {
        Check.failures.append("  \(Check.currentSuite) › \(name): \(failure.message)")
    } catch {
        Check.failures.append("  \(Check.currentSuite) › \(name): threw \(error)")
    }

    let newFailures = Check.failures.count - failuresBefore
    if newFailures == 0 {
        Check.passed += 1
        print("  \u{001B}[32m✓\u{001B}[0m \(name)")
    } else {
        Check.testFailures += 1
        print("  \u{001B}[31m✗\u{001B}[0m \(name)")
        for failure in Check.failures.suffix(newFailures) {
            print("      \u{001B}[31m\(failure.trimmingCharacters(in: .whitespaces))\u{001B}[0m")
        }
    }
}

/// Expectations swallow thrown errors and report them as failures, so one bad
/// assertion doesn't abandon the rest of the test.
func expect(
    _ condition: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "expectation failed",
    line: UInt = #line
) {
    do {
        guard try !condition() else { return }
        record("\(message()) (line \(line))")
    } catch {
        record("threw \(error) (line \(line))")
    }
}

func expectEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    _ label: String = "",
    line: UInt = #line
) {
    do {
        let lhs = try actual()
        let rhs = try expected()
        guard lhs != rhs else { return }
        let prefix = label.isEmpty ? "" : "\(label): "
        record("\(prefix)expected \(rhs), got \(lhs) (line \(line))")
    } catch {
        record("threw \(error) (line \(line))")
    }
}

private func record(_ detail: String) {
    Check.failures.append("  \(Check.currentSuite) › \(Check.currentTest): \(detail)")
}

/// Unwraps or aborts the current test.
func require<T>(_ value: T?, _ message: String = "unexpected nil", line: UInt = #line) throws -> T {
    guard let value else { throw Check.RequirementFailure(message: "\(message) (line \(line))") }
    return value
}

func fail(_ message: String, line: UInt = #line) {
    Check.failures.append("  \(Check.currentSuite) › \(Check.currentTest): \(message) (line \(line))")
}

func summarise() -> Never {
    let total = Check.passed + Check.testFailures
    if Check.testFailures == 0 {
        print("\u{001B}[32m\(total) tests passed\u{001B}[0m")
        exit(0)
    }
    print("\u{001B}[31m\(Check.testFailures) of \(total) tests failed\u{001B}[0m")
    exit(1)
}

// MARK: - Shared fixtures

enum Fixture {
    /// A scratch directory that cleans itself up.
    static func withTemporaryDirectory(_ body: (URL) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastedeck-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// An encoded PNG of the requested size, so image tests need no fixture files.
    static func png(width: Int, height: Int) -> Data? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 200
            pixels[index + 1] = 120
            pixels[index + 2] = 40
            pixels[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
