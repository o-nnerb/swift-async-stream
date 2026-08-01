// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SwiftAsyncStream

struct ValueSubjectTests {

    @Test
    func initialValue() async {
        let subject = ValueSubject(42)
        #expect(subject.value == 42)
    }

    @Test
    func valueUpdate() async {
        let subject = ValueSubject(1)
        subject.value = 2
        #expect(subject.value == 2)
    }

    @Test
    func currentValueOnSubscription() async {
        let subject = ValueSubject(10)

        let task = Task {
            var receivedValue: Int?
            for await value in subject {
                receivedValue = value
                break
            }
            return receivedValue
        }

        let received = await task.value
        #expect(received == 10)
    }

    @Test
    func subscribersReceiveValueUpdates() async {
        let subject = ValueSubject(1)
        let receivedValues = InlineProperty<[Int]>(wrappedValue: [])

        let task = Task {
            for await value in subject {
                receivedValues.wrappedValue.append(value)
                if receivedValues.wrappedValue.count >= 3 {
                    break
                }
            }
        }

        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        subject.value = 2
        subject.value = 3

        await task.value
        #expect(receivedValues.wrappedValue == [1, 2, 3])
    }

    @Test
    func multipleSubscribersReceiveTheSameValues() async {
        let subject = ValueSubject(0)
        let receivedByFirst = InlineProperty<[Int]>(wrappedValue: [])
        let receivedBySecond = InlineProperty<[Int]>(wrappedValue: [])

        let firstTask = Task {
            for await value in subject {
                receivedByFirst.wrappedValue.append(value)
                if receivedByFirst.wrappedValue.count >= 3 {
                    break
                }
            }
        }

        let secondTask = Task {
            for await value in subject {
                receivedBySecond.wrappedValue.append(value)
                if receivedBySecond.wrappedValue.count >= 3 {
                    break
                }
            }
        }

        // Allow time for subscriptions to start
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        subject.value = 1
        subject.value = 2

        await firstTask.value
        await secondTask.value

        #expect(receivedByFirst.wrappedValue == [0, 1, 2])
        #expect(receivedBySecond.wrappedValue == [0, 1, 2])
    }

    @Test
    func erasesToAnyAsyncSequence() async {
        let subject = ValueSubject(100)
        let erasedSubject = subject.eraseToAnyAsyncSequence()

        let task = Task {
            var receivedValue: Int?
            for await value in erasedSubject {
                receivedValue = value
                break
            }
            return receivedValue
        }

        let received = await task.value
        #expect(received == 100)
    }

    // MARK: - Cancellation

    /// Cancelling a subscriber ends the `for await` loop instead of leaving the task
    /// suspended forever.
    @Test
    func cancellingASubscriberEndsTheLoop() async throws {
        let subject = ValueSubject(0)

        let task = Task {
            for await _ in subject {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        task.cancel()

        try await withTaskTimeout(seconds: 1) {
            await task.value
        }
    }

    // MARK: - Buffering policy

    /// `.bufferingNewest(1)` turns the subject into a conflating one: intermediate updates
    /// published while a subscriber has not consumed anything yet are skipped, and it jumps
    /// straight to the latest value instead of stalling on the first one.
    @Test
    func conflatesToTheLatestValueWhenBufferingNewestOne() async throws {
        let subject = ValueSubject(0, bufferingPolicy: .bufferingNewest(1))

        var iterator = subject.makeAsyncIterator()

        subject.value = 1
        subject.value = 2
        subject.value = 3

        let first = await iterator.next()
        #expect(first == 3)
    }
}
