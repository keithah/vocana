import Foundation

/// Utility for throttling function calls to prevent excessive execution
/// Used to prevent UI updates from overwhelming the main thread
class Throttler {
    private var workItem: DispatchWorkItem?
    private let queue: DispatchQueue
    private let interval: TimeInterval
    
    /// Initialize throttler with specified interval
    /// - Parameters:
    ///   - interval: Minimum time between executions in seconds
    ///   - queue: Queue to execute on (defaults to main)
    init(interval: TimeInterval, queue: DispatchQueue = DispatchQueue.main) {
        self.interval = interval
        self.queue = queue
    }
    
    /// Execute function with throttling
    /// If called multiple times within interval, only the last call will execute
    /// - Parameter action: Function to execute
    func throttle(_ action: @escaping () -> Void) {
        // Cancel previous work item
        workItem?.cancel()
        
        // Create new work item
        workItem = DispatchWorkItem(block: action)
        
        // Schedule after delay
        if let workItem = workItem {
            queue.asyncAfter(deadline: .now() + interval, execute: workItem)
        }
    }
    
    /// Cancel any pending throttled execution
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}