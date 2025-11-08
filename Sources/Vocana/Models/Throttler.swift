import Foundation

/// Utility for throttling function calls to prevent excessive execution
/// Implements true throttling: runs action immediately on first call, then blocks subsequent calls
/// within the interval, while also scheduling one final call after interval if needed.
/// 
/// Used to prevent UI updates from overwhelming the main thread during high-frequency changes
class Throttler {
    private var lastFireTime: Date = Date.distantPast
    private var pendingWorkItem: DispatchWorkItem?
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
    
    /// Execute function with true throttling
    /// - If enough time has elapsed since last execution, runs immediately
    /// - Otherwise, schedules execution for when interval expires
    /// - Parameter action: Function to execute
    func throttle(_ action: @escaping () -> Void) {
        queue.sync { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastFireTime)
            
            if elapsed >= self.interval {
                // Enough time has passed, execute immediately
                self.lastFireTime = now
                self.pendingWorkItem?.cancel()
                self.pendingWorkItem = nil
                
                self.queue.async {
                    action()
                }
            } else {
                // Schedule execution for when interval expires
                self.pendingWorkItem?.cancel()
                
                let remainingTime = self.interval - elapsed
                let newWorkItem = DispatchWorkItem { [weak self] in
                    self?.lastFireTime = Date()
                    action()
                }
                
                self.pendingWorkItem = newWorkItem
                self.queue.asyncAfter(deadline: .now() + remainingTime, execute: newWorkItem)
            }
        }
    }
    
    /// Cancel any pending throttled execution
    func cancel() {
        queue.sync {
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
        }
    }
}