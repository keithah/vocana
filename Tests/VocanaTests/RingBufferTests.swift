//
//  RingBufferTests.swift
//  Vocana
//
//  Ring Buffer Testing for PR #52
//  Tests thread safety, bounds checking, and performance of ring buffer operations
//

import XCTest
import Foundation
@testable import Vocana

/// Thread-safe ring buffer implementation for testing
class TestRingBuffer {
    private var buffer: [Float]
    private var head: Int = 0
    private var tail: Int = 0
    private var count: Int = 0
    private let capacity: Int
    private let lock = NSLock()
    
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0.0, count: capacity)
    }
    
    func write(_ data: [Float]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard data.count <= capacity - count else { return false }
        
        for sample in data {
            buffer[tail] = sample
            tail = (tail + 1) % capacity
            count += 1
        }
        
        return true
    }
    
    func read(count: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        
        guard count <= self.count else { return nil }
        
        var result = [Float]()
        for _ in 0..<count {
            result.append(buffer[head])
            head = (head + 1) % capacity
            self.count -= 1
        }
        
        return result
    }
    
    func availableToRead() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    
    func availableToWrite() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return capacity - count
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        head = 0
        tail = 0
        count = 0
    }
}

@MainActor
final class RingBufferTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var ringBuffer: TestRingBuffer!
    private var testAudioData: [Float]!
    
    // MARK: - Setup and Teardown
    
    override func setUp() {
        super.setUp()
        ringBuffer = TestRingBuffer(capacity: 1024)
        
        // Generate test audio data
        testAudioData = (0..<512).map { i in
            sin(2 * Float.pi * Float(i) / 512.0) * 0.5
        }
    }
    
    override func tearDown() {
        ringBuffer = nil
        testAudioData = nil
        super.tearDown()
    }
    
    // MARK: - Basic Operations Tests
    
    func testRingBufferInitialization() {
        XCTAssertNotNil(ringBuffer, "Ring buffer should be initialized")
        XCTAssertEqual(ringBuffer.availableToRead(), 0, "Initial read count should be 0")
        XCTAssertEqual(ringBuffer.availableToWrite(), 1024, "Initial write capacity should be full")
    }
    
    func testSingleWriteRead() {
        let testData: [Float] = [0.5, -0.3, 0.8, -0.1]
        
        // Test write
        let writeSuccess = ringBuffer.write(testData)
        XCTAssertTrue(writeSuccess, "Write should succeed")
        XCTAssertEqual(ringBuffer.availableToRead(), 4, "Should have 4 samples available to read")
        XCTAssertEqual(ringBuffer.availableToWrite(), 1020, "Should have 1020 samples available to write")
        
        // Test read
        let readData = ringBuffer.read(count: 4)
        XCTAssertNotNil(readData, "Read should succeed")
        XCTAssertEqual(readData?.count, 4, "Should read 4 samples")
        XCTAssertEqual(readData, testData, "Read data should match written data")
        XCTAssertEqual(ringBuffer.availableToRead(), 0, "Should have 0 samples available after reading")
        XCTAssertEqual(ringBuffer.availableToWrite(), 1024, "Should have full write capacity after reading")
    }
    
    func testMultipleWriteRead() {
        let chunkSize = 128
        
        // Write multiple chunks
        for i in 0..<4 {
            let chunk = Array(testAudioData.dropFirst(i * chunkSize).prefix(chunkSize))
            let writeSuccess = ringBuffer.write(chunk)
            XCTAssertTrue(writeSuccess, "Write chunk \(i) should succeed")
        }
        
        XCTAssertEqual(ringBuffer.availableToRead(), 512, "Should have 512 samples available")
        XCTAssertEqual(ringBuffer.availableToWrite(), 512, "Should have 512 samples available to write")
        
        // Read multiple chunks
        var allReadData: [Float] = []
        for i in 0..<4 {
            let readData = ringBuffer.read(count: chunkSize)
            XCTAssertNotNil(readData, "Read chunk \(i) should succeed")
            XCTAssertEqual(readData?.count, chunkSize, "Should read \(chunkSize) samples")
            allReadData.append(contentsOf: readData!)
        }
        
        XCTAssertEqual(allReadData.count, 512, "Should have read 512 total samples")
        XCTAssertEqual(allReadData, Array(testAudioData.prefix(512)), "Read data should match written data")
    }
    
    func testWrapAroundBehavior() {
        let capacity = ringBuffer.availableToWrite()
        
        // Fill buffer to near capacity
        let largeChunk = [Float](repeating: 0.5, count: capacity - 10)
        let writeSuccess1 = ringBuffer.write(largeChunk)
        XCTAssertTrue(writeSuccess1, "Large write should succeed")
        
        // Write more to trigger wrap-around
        let wrapChunk = [Float](repeating: 0.8, count: 5)
        let writeSuccess2 = ringBuffer.write(wrapChunk)
        XCTAssertTrue(writeSuccess2, "Wrap-around write should succeed")
        
        // Read all data to test wrap-around read
        let readData = ringBuffer.read(count: capacity - 5)
        XCTAssertNotNil(readData, "Wrap-around read should succeed")
        XCTAssertEqual(readData?.count, capacity - 5, "Should read correct number of samples")
        
        // Read remaining data
        let remainingData = ringBuffer.read(count: 5)
        XCTAssertNotNil(remainingData, "Remaining read should succeed")
        XCTAssertEqual(remainingData, wrapChunk, "Remaining data should match wrap chunk")
    }
    
    // MARK: - Bounds Checking Tests
    
    func testWriteOverflow() {
        let capacity = ringBuffer.availableToWrite()
        
        // Fill buffer to capacity
        let fullChunk = [Float](repeating: 0.5, count: capacity)
        let writeSuccess1 = ringBuffer.write(fullChunk)
        XCTAssertTrue(writeSuccess1, "Full capacity write should succeed")
        XCTAssertEqual(ringBuffer.availableToWrite(), 0, "Should have no write capacity left")
        
        // Attempt to write beyond capacity
        let overflowChunk: [Float] = [0.1, 0.2, 0.3]
        let writeSuccess2 = ringBuffer.write(overflowChunk)
        XCTAssertFalse(writeSuccess2, "Overflow write should fail")
        XCTAssertEqual(ringBuffer.availableToWrite(), 0, "Should still have no write capacity")
    }
    
    func testReadUnderflow() {
        // Attempt to read from empty buffer
        let readData = ringBuffer.read(count: 10)
        XCTAssertNil(readData, "Read from empty buffer should fail")
        
        // Write some data then read more than available
        let smallChunk: [Float] = [0.1, 0.2, 0.3]
        _ = ringBuffer.write(smallChunk)
        
        let overRead = ringBuffer.read(count: 10)
        XCTAssertNil(overRead, "Over-read should fail")
        
        // Read exact amount
        let exactRead = ringBuffer.read(count: 3)
        XCTAssertNotNil(exactRead, "Exact read should succeed")
        XCTAssertEqual(exactRead, smallChunk, "Exact read should match written data")
    }
    
    func testZeroLengthOperations() {
        // Test zero-length write
        let emptyWrite: [Float] = []
        let writeSuccess = ringBuffer.write(emptyWrite)
        XCTAssertTrue(writeSuccess, "Zero-length write should succeed")
        XCTAssertEqual(ringBuffer.availableToRead(), 0, "Should have no data after zero-length write")
        
        // Test zero-length read
        let emptyRead = ringBuffer.read(count: 0)
        XCTAssertNotNil(emptyRead, "Zero-length read should succeed")
        XCTAssertEqual(emptyRead?.count, 0, "Zero-length read should return empty array")
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentWrites() {
        let writeExpectation = XCTestExpectation(description: "Concurrent writes")
        writeExpectation.expectedFulfillmentCount = 10
        
        let chunkSize = 50
        let chunksPerThread = 10
        
        // Launch multiple writer threads
        for threadID in 0..<10 {
            DispatchQueue.global(qos: .userInteractive).async {
                for chunkID in 0..<chunksPerThread {
                    let chunk = (0..<chunkSize).map { i in
                        Float(threadID * chunksPerThread + chunkID) * 0.1
                    }
                    
                    let success = self.ringBuffer.write(chunk)
                    XCTAssertTrue(success, "Concurrent write should succeed")
                }
                writeExpectation.fulfill()
            }
        }
        
        wait(for: [writeExpectation], timeout: 10.0)
        
        // Verify all data was written
        let totalWritten = 10 * chunksPerThread * chunkSize
        XCTAssertEqual(ringBuffer.availableToRead(), totalWritten, "All concurrent writes should be recorded")
        
        // Read and verify data integrity
        let readData = ringBuffer.read(count: totalWritten)
        XCTAssertNotNil(readData, "Should be able to read all written data")
        XCTAssertEqual(readData?.count, totalWritten, "Should read all written data")
    }
    
    func testConcurrentReads() {
        // Fill buffer with data
        let totalData = [Float](repeating: 0.5, count: 500)
        _ = ringBuffer.write(totalData)
        
        let readExpectation = XCTestExpectation(description: "Concurrent reads")
        readExpectation.expectedFulfillmentCount = 5
        
        let readSize = 100
        
        // Launch multiple reader threads
        for threadID in 0..<5 {
            DispatchQueue.global(qos: .userInteractive).async {
                let readData = self.ringBuffer.read(count: readSize)
                XCTAssertNotNil(readData, "Concurrent read should succeed")
                XCTAssertEqual(readData?.count, readSize, "Should read correct amount")
                readExpectation.fulfill()
            }
        }
        
        wait(for: [readExpectation], timeout: 5.0)
        
        // Verify remaining data
        let remainingData = ringBuffer.availableToRead()
        XCTAssertEqual(remainingData, 0, "All data should be consumed by concurrent reads")
    }
    
    func testConcurrentReadWrite() {
        let concurrentExpectation = XCTestExpectation(description: "Concurrent read/write")
        concurrentExpectation.expectedFulfillmentCount = 20
        
        let chunkSize = 25
        
        // Launch writer threads
        for threadID in 0..<10 {
            DispatchQueue.global(qos: .userInteractive).async {
                for chunkID in 0..<5 {
                    let chunk = (0..<chunkSize).map { i in
                        sin(2 * Float.pi * Float(i) / Float(chunkSize)) * 0.5
                    }
                    
                    let success = self.ringBuffer.write(chunk)
                    if success {
                        concurrentExpectation.fulfill()
                    }
                    
                    // Small delay to allow reads
                    usleep(1000) // 1ms
                }
            }
        }
        
        // Launch reader threads
        for threadID in 0..<10 {
            DispatchQueue.global(qos: .userInteractive).async {
                for _ in 0..<5 {
                    let readData = self.ringBuffer.read(count: chunkSize)
                    if readData != nil {
                        concurrentExpectation.fulfill()
                    }
                    
                    // Small delay to allow writes
                    usleep(1000) // 1ms
                }
            }
        }
        
        wait(for: [concurrentExpectation], timeout: 10.0)
        
        // Buffer should be reasonably balanced
        let remaining = ringBuffer.availableToRead()
        XCTAssertLessThanOrEqual(remaining, 100, "Should not have excessive remaining data")
    }
    
    // MARK: - Performance Tests
    
    func testWritePerformance() {
        let iterations = 10000
        let chunkSize = 64
        let testData = [Float](repeating: 0.5, count: chunkSize)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for _ in 0..<iterations {
            // Clear buffer if needed
            if ringBuffer.availableToWrite() < chunkSize {
                ringBuffer.clear()
            }
            
            _ = ringBuffer.write(testData)
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let totalTime = endTime - startTime
        let averageTime = totalTime / Double(iterations)
        let throughput = Double(chunkSize) / averageTime
        
        print(String(format: "Write Performance: %.3fμs avg, %.0f samples/sec",
                     averageTime * 1_000_000, throughput))
        
        XCTAssertLessThan(averageTime, 0.001, "Average write time should be < 1ms")
    }
    
    func testReadPerformance() {
        let iterations = 10000
        let chunkSize = 64
        
        // Pre-fill buffer
        let totalData = [Float](repeating: 0.5, count: iterations * chunkSize)
        _ = ringBuffer.write(totalData)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for _ in 0..<iterations {
            _ = ringBuffer.read(count: chunkSize)
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let totalTime = endTime - startTime
        let averageTime = totalTime / Double(iterations)
        let throughput = Double(chunkSize) / averageTime
        
        print(String(format: "Read Performance: %.3fμs avg, %.0f samples/sec",
                     averageTime * 1_000_000, throughput))
        
        XCTAssertLessThan(averageTime, 0.001, "Average read time should be < 1ms")
    }
    
    func testMemoryEfficiency() {
        let initialMemory = getCurrentMemoryUsage()
        
        // Perform many operations
        for i in 0..<1000 {
            let chunk = (0..<100).map { Float(i) * 0.01 }
            _ = ringBuffer.write(chunk)
            _ = ringBuffer.read(count: 100)
        }
        
        let finalMemory = getCurrentMemoryUsage()
        let memoryIncrease = finalMemory - initialMemory
        
        print(String(format: "Memory Efficiency: %.1fKB increase", memoryIncrease / 1024.0))
        XCTAssertLessThan(memoryIncrease, 1024 * 1024, "Memory increase should be < 1MB")
    }
    
    // MARK: - Stress Tests
    
    func testHighFrequencyOperations() {
        let duration = 1.0 // 1 second
        let chunkSize = 32
        let startTime = CFAbsoluteTimeGetCurrent()
        var operations = 0
        
        while CFAbsoluteTimeGetCurrent() - startTime < duration {
            let chunk = [Float](repeating: Float.random(in: -1...1), count: chunkSize)
            
            if ringBuffer.write(chunk) {
                _ = ringBuffer.read(count: chunkSize)
                operations += 1
            } else {
                ringBuffer.clear()
            }
        }
        
        let actualDuration = CFAbsoluteTimeGetCurrent() - startTime
        let operationsPerSecond = Double(operations) / actualDuration
        
        print(String(format: "High Frequency: %.0f operations/sec", operationsPerSecond))
        XCTAssertGreaterThan(operationsPerSecond, 1000, "Should handle > 1000 operations/sec")
    }
    
    func testLongRunningStability() {
        let duration = 10.0 // 10 seconds
        let startTime = CFAbsoluteTimeGetCurrent()
        var errors = 0
        var successfulOperations = 0
        
        while CFAbsoluteTimeGetCurrent() - startTime < duration {
            let chunkSize = Int.random(in: 1...100)
            let chunk = [Float](repeating: Float.random(in: -1...1), count: chunkSize)
            
            if ringBuffer.write(chunk) {
                let readSize = Int.random(in: 1...chunkSize)
                if let _ = ringBuffer.read(count: readSize) {
                    successfulOperations += 1
                } else {
                    errors += 1
                }
            } else {
                ringBuffer.clear()
                errors += 1
            }
            
            usleep(1000) // 1ms delay
        }
        
        let totalOperations = successfulOperations + errors
        let errorRate = Double(errors) / Double(totalOperations)
        
        print(String(format: "Long Running: %d operations, %.1f%% error rate",
                     totalOperations, errorRate * 100))
        XCTAssertLessThan(errorRate, 0.05, "Error rate should be < 5%")
    }
    
    // MARK: - Helper Methods
    
    private func getCurrentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size)
        } else {
            return 0.0
        }
    }
}