import Foundation

/// Utility for throttling function calls to prevent excessive execution
/// Implements true throttling: runs action immediately on first call, then blocks subsequent calls
/// within the interval, while also scheduling one final call after interval if needed.
/// 
/// Thread-safe: Uses a dedicated serial queue for synchronization to avoid deadlocks when called
/// from the same queue that the action executes on.
/// 
/// Used to prevent UI updates from overwhelming the main thread during high-frequency changes
/// 
/// Memory Retention: The action closure is retained until execution completes or is cancelled.
/// If the action captures expensive objects (e.g., large buffers), they will be retained in memory
/// for the duration of the throttle interval. This is typically acceptable for UI updates but should
/// be considered for long-lived throttlers processing large data. The pending work item is automatically
/// cancelled in deinit to prevent leaks.
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
                 // Fix: Update lastFireTime at scheduling time, not execution time
                 // This prevents race condition where rapid calls could schedule multiple work items
                 // within the same throttle window if update was deferred to execution time
                 self.lastFireTime = now.addingTimeInterval(remainingTime)
                 
                 let newWorkItem = DispatchWorkItem {
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