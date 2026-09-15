import XCTest
@testable import SwiftOSLogger

final class ConsoleDestinationTests: XCTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    func testDefaults() {
        let destination = ConsoleDestination()
        XCTAssertEqual(destination.minLevel, .trace)
        XCTAssertEqual(destination.output, .standardOutput)
        XCTAssertEqual((destination.formatter as? TextLogFormatter)?.includeEmoji, true)
    }

    func testWritesFormattedLineWithNewline() {
        let capture = Capture()
        let destination = ConsoleDestination(minLevel: .trace, formatter: TextLogFormatter(), output: .standardOutput,
                                             writer: { capture.append($0) })
        destination.write(makeEntry(), formatted: "line one")
        destination.write(makeEntry(), formatted: "line two")
        XCTAssertEqual(capture.text, "line one\nline two\n")
    }

    func testConcurrentWritesDoNotInterleave() {
        let capture = Capture()
        let destination = ConsoleDestination(minLevel: .trace, formatter: TextLogFormatter(), output: .standardError,
                                             writer: { data in
                                                 // Write byte-by-byte to expose any missing serialization.
                                                 for byte in data { capture.append(Data([byte])) }
                                             })
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            destination.write(makeEntry(), formatted: "entry-\(i)-end")
        }
        let lines = capture.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 200)
        XCTAssertTrue(lines.allSatisfy { $0.range(of: #"^entry-\d+-end$"#, options: .regularExpression) != nil })
    }
}
