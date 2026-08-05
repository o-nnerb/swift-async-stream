// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SwiftAsyncStream

struct InlinePropertyTests {

    @Test
    func wrappedValueReadsTheInitialValue() {
        let property = InlineProperty(wrappedValue: 42)

        #expect(property.wrappedValue == 42)
    }

    @Test
    func wrappedValueSetReplacesTheStoredValue() {
        let property = InlineProperty(wrappedValue: 1)

        property.wrappedValue = 2

        #expect(property.wrappedValue == 2)
    }

    @Test
    func withValueReadsAndWritesInOneCriticalSection() {
        let property = InlineProperty(wrappedValue: 1)

        let result = property.withValue { value -> Int in
            value += 1
            return value
        }

        #expect(result == 2)
        #expect(property.wrappedValue == 2)
    }

    @Test
    func withValuePropagatesTheClosuresError() {
        let property = InlineProperty(wrappedValue: 1)

        struct TestError: Error {}

        #expect(throws: TestError.self) {
            try property.withValue { _ in
                throw TestError()
            }
        }
    }

    @Test
    func equatableComparesByWrappedValue() {
        let first = InlineProperty(wrappedValue: 1)
        let second = InlineProperty(wrappedValue: 1)
        let third = InlineProperty(wrappedValue: 2)

        #expect(first == second)
        #expect(first != third)
    }

    @Test
    func hashableMatchesEqualWrappedValues() {
        let first = InlineProperty(wrappedValue: "a")
        let second = InlineProperty(wrappedValue: "a")

        #expect(first.hashValue == second.hashValue)

        let set: Set<InlineProperty<String>> = [first, second]
        #expect(set.count == 1)
    }
}
