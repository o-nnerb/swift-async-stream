import Testing
@testable import SwiftAsyncStream

struct PassthroughSubjectTests {
    
    @Test("PassthroughSubject sends values to subscribers")
    func testSendValues() async {
        let subject = PassthroughSubject<Int>()
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
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.send(10)
        subject.send(20)
        
        await task.value
        #expect(receivedValues.wrappedValue == [10, 20])
    }
    
    @Test("PassthroughSubject doesn't send initial value to new subscribers")
    func testNoInitialValue() async {
        let subject = PassthroughSubject<Int>()
        subject.send(100) // Send before subscription
        
        let task = Task {
            var firstValue: Int?
            for await value in subject {
                firstValue = value
                break // Exit after first value
            }
            return firstValue
        }
        
        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.send(200)
        
        let received = await task.value
        #expect(received == 200)
    }
    
    @Test("Multiple subscribers receive same values")
    func testMultipleSubscribers() async {
        let subject = PassthroughSubject<String>()
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
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.send("Hello")
        subject.send("World")
        
        await firstTask.value
        await secondTask.value
        
        #expect(receivedByFirst.wrappedValue == ["Hello", "World"])
        #expect(receivedBySecond.wrappedValue == ["Hello", "World"])
    }
    
    @Test("Subject completes properly")
    func testCompletion() async {
        let subject = PassthroughSubject<Int>()
        let receivedValues = InlineProperty<[Int]>(wrappedValue: [])

        let task = Task {
            for await value in subject {
                receivedValues.wrappedValue.append(value)
            }
        }
        
        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.send(1)
        subject.completed()
        subject.send(2) // This should not be received after completion
        
        await task.value
        #expect(receivedValues.wrappedValue == [1])
    }
    
    @Test("PassthroughSubject can be erased to AnyAsyncSequence")
    func testEraseToAnyAsyncSequence() async {
        let subject = PassthroughSubject<Int>()
        let erasedSubject = subject.eraseToAnyAsyncSequence()
        
        let receivedValue = InlineProperty<Int?>(wrappedValue: nil)

        let task = Task {
            for await value in erasedSubject {
                receivedValue.wrappedValue = value
                break
            }
        }
        
        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.send(42)
        
        await task.value
        #expect(receivedValue.wrappedValue == 42)
    }
}
