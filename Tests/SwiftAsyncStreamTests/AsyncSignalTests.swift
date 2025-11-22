import Testing
import SwiftAsyncStream

struct AsyncSignalTests {
    
    @Test("AsyncSignal signals and waits properly")
    func testBasicSignal() async {
        let signal = AsyncSignal()
        
        let task = Task {
            await signal.wait()
        }
        
        // Allow time for wait to start
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        signal.signal()
        
        await task.value
    }
    
    @Test("AsyncSignal can be awaited multiple times after signaling")
    func testMultipleWaitsAfterSignal() async {
        let signal = AsyncSignal()
        
        // Signal first
        signal.signal()
        
        // Multiple awaits should all return immediately
        await signal.wait()
        await signal.wait()
        await signal.wait()
    }
    
    @Test("AsyncSignal waits until signaled")
    func testWaitUntilSignaled() async {
        let signal = AsyncSignal()
        var completed = false
        
        let task = Task {
            await signal.wait()
            completed = true
        }
        
        // Wait a bit to ensure the task has started waiting
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        #expect(!completed) // Should not be completed yet
        
        signal.signal()
        await task.value
        #expect(completed) // Should now be completed
    }
}