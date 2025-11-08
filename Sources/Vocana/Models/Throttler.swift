import Foundation

/// Utility for throttling function calls to prevent excessive execution
/// Implements true throttling: runs action immediately on first call, then blocks subsequent calls
/// within the interval, while also scheduling one final call after interval if needed.
/// 
/// Thread-safe: Uses a dedicated serial queue for synchronization to avoid deadlocks when called
/// from the same queue that the action executes on.
/// 
/// Used to prevent UI updates from overwhelming the main thread during high-frequency changes
class Throttler {
    private var lastFireTime: Date = Date.distantPast
    private var pendingWorkItem: DispatchWorkItem?
    private let queue: DispatchQueue  // Queue to execute action on
    private let syncQueue: DispatchQueue  // Dedicated serial queue for synchronization (CRITICAL: prevents deadlock)
    private let interval: TimeInterval
    
    /// Initialize throttler with specified interval
    /// - Parameters:
    ///   - interval: Minimum time between executions in seconds
    ///   - queue: Queue to execute on (defaults to main)
    init(interval: TimeInterval, queue: DispatchQueue = DispatchQueue.main) {
        self.interval = interval
        self.queue = queue
        // CRITICAL: Use dedicated serial queue for synchronization to prevent deadlocks
        // This queue is never the same as the main queue, so sync() won't deadlock
        self.syncQueue = DispatchQueue(label: "com.vocana.throttler.\(UUID().uuidString)", qos: .userInteractive)
    }
    
    /// Execute function with true throttling
    /// - If enough time has elapsed since last execution, runs immediately
    /// - Otherwise, schedules execution for when interval expires
    /// - Parameter action: Function to execute
    func throttle(_ action: @escaping () -> Void) {
        // CRITICAL FIX: Use dedicated syncQueue instead of main queue to prevent deadlocks
        // syncQueue.sync is safe because syncQueue is never the caller's queue
        syncQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastFireTime)
            
            if elapsed >= self.interval {
                // Enough time has passed, execute immediately
                self.lastFireTime = now
                self.pendingWorkItem?.cancel()
                self.pendingWorkItem = nil
                
                // Execute on target queue asynchronously (never blocks caller)
                self.queue.async {
                    action()
                }
            } else {
                // Schedule execution for when interval expires
                self.pendingWorkItem?.cancel()
                
                let remainingTime = self.interval - elapsed
                let newWorkItem = DispatchWorkItem { [weak self] in
                    self?.syncQueue.sync {
                        self?.lastFireTime = Date()
                    }
                    action()
                }
                
                self.pendingWorkItem = newWorkItem
                self.queue.asyncAfter(deadline: .now() + remainingTime, execute: newWorkItem)
            }
        }
    }
    
    /// Cancel any pending throttled execution
    func cancel() {
        syncQueue.sync {
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
        }
    }
}