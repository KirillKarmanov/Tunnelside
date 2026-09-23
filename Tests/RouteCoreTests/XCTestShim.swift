import Testing

// Command Line Tools have no XCTest, only Swift Testing.
// This shim keeps the familiar XCTAssert* so the tests don't have to be rewritten line by line.

/// An empty Comment crashes the process (SIGTRAP) in Swift Testing from Command Line Tools, so an empty message becomes nil.
private func note(_ message: String) -> Comment? {
    message.isEmpty ? nil : Comment(rawValue: message)
}

func XCTAssertEqual<T: Equatable>(
    _ a: @autoclosure () throws -> T,
    _ b: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    let lhs = try a()
    let rhs = try b()
    #expect(lhs == rhs, "\(message()) (\(String(describing: lhs)) != \(String(describing: rhs)))", sourceLocation: sourceLocation)
}

func XCTAssertTrue(
    _ condition: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    let value = try condition()
    #expect(value == true, note(message()), sourceLocation: sourceLocation)
}

func XCTAssertFalse(
    _ condition: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    let value = try condition()
    #expect(value == false, note(message()), sourceLocation: sourceLocation)
}

func XCTAssertNil<T>(
    _ value: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    let unwrapped = try value()
    #expect(unwrapped == nil, "\(message()) (\(String(describing: unwrapped)))", sourceLocation: sourceLocation)
}

func XCTAssertNotNil<T>(
    _ value: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    let unwrapped = try value()
    #expect(unwrapped != nil, note(message()), sourceLocation: sourceLocation)
}

func XCTUnwrap<T>(
    _ value: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    guard let unwrapped = try value() else {
        Issue.record("XCTUnwrap: nil. \(message())", sourceLocation: sourceLocation)
        throw UnwrapError()
    }
    return unwrapped
}

struct UnwrapError: Error {}
