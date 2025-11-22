import Testing
@testable import SwiftAsyncStream

struct ValueSubjectTests {
    
    @Test("Initial value is correctly set")
    func testInitialValue() async {
        let subject = ValueSubject(42)
        #expect(subject.value == 42)
    }
    
    @Test("Value updates correctly")
    func testValueUpdate() async {
        let subject = ValueSubject(1)
        subject.value = 2
        #expect(subject.value == 2)
    }
    
    @Test("Subscribers receive current value upon subscription")
    func testCurrentValueOnSubscription() async {
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
    
    @Test("Subscribers receive value updates")
    func testValueUpdates() async {
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
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.value = 2
        subject.value = 3
        
        await task.value
        #expect(receivedValues.wrappedValue == [1, 2, 3])
    }
    
    @Test("Multiple subscribers receive the same values")
    func testMultipleSubscribers() async {
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
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.value = 1
        subject.value = 2
        
        await firstTask.value
        await secondTask.value
        
        #expect(receivedByFirst.wrappedValue == [0, 1, 2])
        #expect(receivedBySecond.wrappedValue == [0, 1, 2])
    }
    
    @Test("ValueSubject can be erased to AnyAsyncSequence")
    func testEraseToAnyAsyncSequence() async {
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
}
