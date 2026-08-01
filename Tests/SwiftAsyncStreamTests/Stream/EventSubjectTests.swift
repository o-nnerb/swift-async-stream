// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SwiftAsyncStream

struct EventSubjectTests {

    @Test
    func sendsValuesToSubscribers() async {
        let subject = EventSubject<Int>()
        let receivedValues = InlineProperty<[Int]>(wrappedValue: [])

        let task = Task {
            for await value in subject {
                receivedValues.wrappedValue.append(value)
                if receivedValues.wrappedValue.count >= 2 {
                    break
                }
            }
        }

        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        subject.send(10)
        subject.send(20)

        await task.value
        #expect(receivedValues.wrappedValue == [10, 20])
    }

    @Test
    func doesNotSendInitialValueToNewSubscribers() async {
        let subject = EventSubject<Int>()
        subject.send(100)  // Send before subscription

        let task = Task {
            var firstValue: Int?
            for await value in subject {
                firstValue = value
                break  // Exit after first value
            }
            return firstValue
        }

        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        subject.send(200)

        let received = await task.value
        #expect(received == 200)
    }

    @Test
    func multipleSubscribersReceiveSameValues() async {
        let subject = EventSubject<String>()
        let receivedByFirst = InlineProperty<[String]>(wrappedValue: [])
        let receivedBySecond = InlineProperty<[String]>(wrappedValue: [])

        let firstTask = Task {
            for await value in subject {
                receivedByFirst.wrappedValue.append(value)
                if receivedByFirst.wrappedValue.count >= 2 {
                    break
                }
            }
        }

        let secondTask = Task {
            for await value in subject {
                receivedBySecond.wrappedValue.append(value)
                if receivedBySecond.wrappedValue.count >= 2 {
                    break
                }
            }
        }

        // Allow time for subscriptions to start
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        subject.send("Hello")
        subject.send("World")

        await firstTask.value
        await secondTask.value

        #expect(receivedByFirst.wrappedValue == ["Hello", "World"])
        #expect(receivedBySecond.wrappedValue == ["Hello", "World"])
    }

    @Test
    func completesProperly() async {
        let subject = EventSubject<Int>()
        let receivedValues = InlineProperty<[Int]>(wrappedValue: [])

        let task = Task {
            for await value in subject {
                receivedValues.wrappedValue.append(value)
            }
        }

        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        subject.send(1)
        subject.completed()
        subject.send(2)  // This should not be received after completion

        await task.value
        #expect(receivedValues.wrappedValue == [1])
    }

    @Test
    func erasesToAnyAsyncSequence() async {
        let subject = EventSubject<Int>()
        let erasedSubject = subject.eraseToAnyAsyncSequence()

        let receivedValue = InlineProperty<Int?>(wrappedValue: nil)

        let task = Task {
            for await value in erasedSubject {
                receivedValue.wrappedValue = value
                break
            }
        }

        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        subject.send(42)

        await task.value
        #expect(receivedValue.wrappedValue == 42)
    }

    /// Two independent consumers of the same erased sequence must each receive every value,
    /// not compete for them. `AnyAsyncSequence` creates one iterator per `makeAsyncIterator()`
    /// call rather than sharing a single one.
    @Test
    func erasedSequenceDoesNotShareOneIteratorAcrossConsumers() async {
        let subject = EventSubject<Int>()
        let erasedSubject = subject.eraseToAnyAsyncSequence()

        let receivedByFirst = InlineProperty<[Int]>(wrappedValue: [])
        let receivedBySecond = InlineProperty<[Int]>(wrappedValue: [])

        let firstTask = Task {
            for await value in erasedSubject {
                receivedByFirst.wrappedValue.append(value)
                if receivedByFirst.wrappedValue.count >= 2 {
                    break
                }
            }
        }

        let secondTask = Task {
            for await value in erasedSubject {
                receivedBySecond.wrappedValue.append(value)
                if receivedBySecond.wrappedValue.count >= 2 {
                    break
                }
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        subject.send(1)
        subject.send(2)

        await firstTask.value
        await secondTask.value

        #expect(receivedByFirst.wrappedValue == [1, 2])
        #expect(receivedBySecond.wrappedValue == [1, 2])
    }

    // MARK: - Cancellation

    /// Cancelling a subscriber ends the `for await` loop instead of leaving the task
    /// suspended forever.
    @Test
    func cancellingASubscriberEndsTheLoop() async throws {
        let subject = EventSubject<Int>()

        let task = Task {
            for await value in subject {
                Issue.record("Should not receive \(value)")
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        task.cancel()

        try await withTaskTimeout(seconds: 1) {
            await task.value
        }
    }

    // MARK: - Buffering policy

    /// A subscriber that has not consumed anything yet, but falls more than the buffer limit
    /// behind, skips the discarded elements instead of receiving or stalling on them.
    @Test
    func discardsTheOldestElementsPastTheBufferLimit() async {
        let subject = EventSubject<Int>(bufferingPolicy: .bufferingNewest(2))

        var iterator = subject.makeAsyncIterator()

        subject.send(1)
        subject.send(2)
        subject.send(3)

        var received = [Int]()
        while let value = await iterator.next() {
            received.append(value)
            if received.count == 2 {
                break
            }
        }

        #expect(received == [2, 3])
    }
}
