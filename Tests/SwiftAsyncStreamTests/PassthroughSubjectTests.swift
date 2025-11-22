import Testing
import SwiftAsyncStream

struct PassthroughSubjectTests {
    
    @Test("PassthroughSubject sends values to subscribers")
    func testSendValues() async {
        let subject = PassthroughSubject<Int, Never>()
        var receivedValues: [Int] = []
        
        let task = Task {
            for await value in subject {
                receivedValues.append(value)
                if receivedValues.count >= 2 {
                    break
                }
            }
        }
        
        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.send(10)
        subject.send(20)
        
        await task.value
        #expect(receivedValues == [10, 20])
    }
    
    @Test("PassthroughSubject doesn't send initial value to new subscribers")
    func testNoInitialValue() async {
        let subject = PassthroughSubject<Int, Never>()
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
        let subject = PassthroughSubject<String, Never>()
        var receivedByFirst: [String] = []
        var receivedBySecond: [String] = []
        
        let firstTask = Task {
            for await value in subject {
                receivedByFirst.append(value)
                if receivedByFirst.count >= 2 {
                    break
                }
            }
        }
        
        let secondTask = Task {
            for await value in subject {
                receivedBySecond.append(value)
                if receivedBySecond.count >= 2 {
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
        
        #expect(receivedByFirst == ["Hello", "World"])
        #expect(receivedBySecond == ["Hello", "World"])
    }
    
    @Test("Subject completes properly")
    func testCompletion() async {
        let subject = PassthroughSubject<Int, Never>()
        var receivedValues: [Int] = []
        
        let task = Task {
            for await value in subject {
                receivedValues.append(value)
            }
        }
        
        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.send(1)
        subject.completed()
        subject.send(2) // This should not be received after completion
        
        await task.value
        #expect(receivedValues == [1])
    }
    
    @Test("PassthroughSubject can be erased to AnyAsyncSequence")
    func testEraseToAnyAsyncSequence() async {
        let subject = PassthroughSubject<Int, Never>()
        let erasedSubject = subject.eraseToAnyAsyncSequence()
        
        var receivedValue: Int?
        
        let task = Task {
            for await value in erasedSubject {
                receivedValue = value
                break
            }
        }
        
        // Allow time for subscription to start
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        subject.send(42)
        
        await task.value
        #expect(receivedValue == 42)
    }
}