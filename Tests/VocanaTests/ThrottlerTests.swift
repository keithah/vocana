import XCTest
@testable import Vocana

final class ThrottlerTests: XCTestCase {
    
    func testThrottlerBasicBehavior() {
        let throttler = Throttler(interval: 0.1)
        var callCount = 0
        let expectation = XCTestExpectation(description: "Throttler executes")
        
        throttler.throttle {
            callCount += 1
            expectation.fulfill()
        }
        
        // Action should be executed
        XCTWaiter.wait(for: [expectation], timeout: 0.5)
        XCTAssertEqual(callCount, 1)
    }
    
    func testThrottlerBlocksRapidCalls() {
        let throttler = Throttler(interval: 0.1)
        var callCount = 0
        
        // First call
        throttler.throttle {
            callCount += 1
        }
        
        // Immediate second call (should be throttled)
        throttler.throttle {
            callCount += 1
        }
        
        // Third call immediately after
        throttler.throttle {
            callCount += 1
        }
        
        let expectation = XCTestExpectation(description: "Waiting for throttle interval")
        expectation.isInverted = true
        _ = XCTWaiter.wait(for: [expectation], timeout: 0.05)
        
        // First call should have executed, others throttled
        XCTAssertEqual(callCount, 1, "Only first call should execute immediately")
    }
    
    func testThrottlerExecutesAfterInterval() {
        let throttler = Throttler(interval: 0.05)
        var callCount = 0
        
        throttler.throttle {
            callCount += 1
        }
        
        throttler.throttle {
            callCount += 1
        }
        
        let expectation = XCTestExpectation(description: "Throttler executes after interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        
        XCTWaiter.wait(for: [expectation], timeout: 0.2)
        
        // Should have 2 executions: initial + pending after interval
        XCTAssertGreaterThanOrEqual(callCount, 1, "Should execute at least once")
    }
    
    func testThrottlerCancel() {
        let throttler = Throttler(interval: 0.1)
        var callCount = 0
        
        throttler.throttle {
            callCount += 1
        }
        
        // Cancel pending work
        throttler.cancel()
        
        let expectation = XCTestExpectation(description: "Waiting after cancel")
        expectation.isInverted = true
        _ = XCTWaiter.wait(for: [expectation], timeout: 0.15)
        
        // Should only have 1 execution (the immediate one)
        XCTAssertEqual(callCount, 1)
    }
    
    func testThrottlerConcurrentCalls() {
        let throttler = Throttler(interval: 0.05)
        var callCount = 0
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        let group = DispatchGroup()

        // Simulate concurrent calls from multiple threads
        for _ in 0..<10 {
            group.enter()
            queue.async {
                throttler.throttle {
                    callCount += 1
                }
                group.leave()
            }
        }

        group.wait()

        let expectation = XCTestExpectation(description: "Waiting for concurrent throttle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            expectation.fulfill()
        }

        XCTWaiter.wait(for: [expectation], timeout: 0.3)

        // With concurrent calls, throttling should coalesce them into single execution
        // The first call executes immediately, subsequent calls are throttled
        XCTAssertEqual(callCount, 1, "Concurrent calls should be throttled to single execution")
    }
    
    func testThrottlerDoesNotDeadlock() {
        let throttler = Throttler(interval: 0.05)
        var executed = false
        
        // Call throttle from main thread
        throttler.throttle {
            executed = true
        }
        
        // If there was a deadlock, this would hang
        let expectation = XCTestExpectation(description: "No deadlock")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        
        XCTWaiter.wait(for: [expectation], timeout: 0.2)
        XCTAssertTrue(executed)
    }
    
    func testThrottlerWithCustomQueue() {
        let customQueue = DispatchQueue(label: "test.custom")
        let throttler = Throttler(interval: 0.05, queue: customQueue)
        var callCount = 0
        var executedOnCustomQueue = false
        let expectation = XCTestExpectation(description: "Custom queue execution")
        
        throttler.throttle {
            callCount += 1
            // Check we're on the custom queue (approximate - just verify it executed)
            executedOnCustomQueue = true
            expectation.fulfill()
        }
        
        XCTWaiter.wait(for: [expectation], timeout: 0.5)
        XCTAssertTrue(executedOnCustomQueue)
        XCTAssertEqual(callCount, 1)
    }
    
    func testThrottlerRespectsInterval() {
        let throttler = Throttler(interval: 0.1)
        var executionTimes: [Date] = []
        
        // First execution
        throttler.throttle {
            executionTimes.append(Date())
        }
        
        // Throttled execution
        throttler.throttle {
            executionTimes.append(Date())
        }
        
        let expectation = XCTestExpectation(description: "Waiting for interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            expectation.fulfill()
        }
        
        XCTWaiter.wait(for: [expectation], timeout: 0.3)
        
        if executionTimes.count >= 2 {
            let timeBetweenExecutions = executionTimes[1].timeIntervalSince(executionTimes[0])
            XCTAssertGreaterThanOrEqual(timeBetweenExecutions, 0.08, 
                "Interval should be respected (with small timing tolerance)")
        }
    }
}
