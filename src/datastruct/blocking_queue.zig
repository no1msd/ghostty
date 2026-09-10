//! Blocking queue implementation aimed primarily for message passing
//! between threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compat_thread = @import("../lib/compat/thread.zig");

/// Returns a blocking queue implementation for type T.
///
/// This is tailor made for ghostty usage so it isn't meant to be maximally
/// generic, but I'm happy to make it more generic over time. Traits of this
/// queue that are specific to our usage:
///
///   - Fixed size. We expect our queue to quickly drain and also not be
///     too large so we prefer a fixed size queue for now.
///   - No blocking pop. We use an external event loop mechanism such as
///     eventfd to notify our waiter that there is no data available so
///     we don't need to implement a blocking pop.
///   - Drain function. Most queues usually pop one at a time. We have
///     a mechanism for draining since on every IO loop our TTY drains
///     the full queue so we can get rid of the overhead of a ton of
///     locks and bounds checking and do a one-time drain.
///
/// One key usage pattern is that our blocking queues are single producer
/// single consumer (SPSC). This should let us do some interesting optimizations
/// in the future. At the time of writing this, the blocking queue implementation
/// is purposely naive to build something quickly, but we should benchmark
/// and make this more optimized as necessary.
pub fn BlockingQueue(
    comptime T: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();

        // The type we use for queue size types. We can optimize this
        // in the future to be the correct bit-size for our preallocated
        // size for this queue.
        pub const Size = u32;

        // The bounds of this queue. We recast this to Size so we can do math.
        const bounds: Size = @intCast(capacity);

        /// Specifies the timeout for an operation.
        pub const Timeout = union(enum) {
            /// Fail instantly (non-blocking).
            instant: void,

            /// Run forever or until interrupted
            forever: void,

            /// Nanoseconds
            ns: u64,
        };

        /// Our data. The values are undefined until they are written.
        data: [bounds]T = undefined,

        /// The next location to write (next empty loc) and next location
        /// to read (next non-empty loc). The number of written elements.
        write: Size = 0,
        read: Size = 0,
        len: Size = 0,

        /// The big mutex that must be held to read/write.
        mutex: std.Io.Mutex = .init,

        /// A CV for being notified when the queue is no longer full. This is
        /// used for writing. Note we DON'T have a CV for waiting on the
        /// queue not being EMPTY because we use external notifiers for that.
        cond_not_full: std.Io.Condition = .init,
        not_full_waiters: usize = 0,

        /// Allocate the blocking queue on the heap.
        pub fn create(alloc: Allocator) Allocator.Error!*Self {
            const ptr = try alloc.create(Self);
            errdefer alloc.destroy(ptr);

            ptr.* = .{
                .data = undefined,
                .len = 0,
                .write = 0,
                .read = 0,
                .mutex = .init,
                .cond_not_full = .init,
                .not_full_waiters = 0,
            };

            return ptr;
        }

        /// Free all the resources for this queue. This should only be
        /// called once all producers and consumers have quit.
        pub fn destroy(self: *Self, alloc: Allocator) void {
            self.* = undefined;
            alloc.destroy(self);
        }

        /// Push a value to the queue. This returns the total size of the
        /// queue (unread items) after the push. A return value of zero
        /// means that the push failed.
        pub fn push(self: *Self, io: std.Io, value: T, timeout: Timeout) Size {
            return self.pushCancelable(io, value, timeout, null);
        }

        /// Like push, but fail if this producer has been cancelled. The flag
        /// must only be changed through cancelPushes and outlive every push
        /// using it. A failed push leaves ownership of value with the caller.
        pub fn pushCancelable(
            self: *Self,
            io: std.Io,
            value: T,
            timeout: Timeout,
            cancelled: ?*const bool,
        ) Size {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (cancelled) |flag| if (flag.*) return 0;
            // Reuse the deadline after another producer's cancellation wakes
            // us so timed pushes neither fail early nor extend their timeout.
            const deadline: std.Io.Timeout = switch (timeout) {
                .ns => |ns| (std.Io.Timeout{ .duration = .{
                    .raw = .fromNanoseconds(ns),
                    .clock = .awake,
                } }).toDeadline(io),
                else => .none,
            };
            while (self.full()) {
                switch (timeout) {
                    // If we're not waiting, then we failed to write.
                    .instant => return 0,

                    .forever => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.waitUncancelable(io, &self.mutex);
                    },

                    .ns => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        compat_thread.waitTimeout(
                            &self.cond_not_full,
                            io,
                            &self.mutex,
                            deadline,
                        ) catch return 0;
                    },
                }

                if (cancelled) |flag| if (flag.*) return 0;
                // Cancellation wakes every producer. Unaffected blocking
                // producers must keep waiting until there is room for them.
            }

            // Add our data and update our accounting
            self.data[self.write] = value;
            self.write += 1;
            if (self.write >= bounds) self.write -= bounds;
            self.len += 1;

            return self.len;
        }

        /// Stop a producer and wake its blocked pushes without closing the
        /// queue or dropping messages belonging to other producers.
        pub fn cancelPushes(self: *Self, io: std.Io, cancelled: *bool) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            cancelled.* = true;
            self.cond_not_full.broadcast(io);
        }

        /// Pop a value from the queue without blocking.
        pub fn pop(self: *Self, io: std.Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // If we're empty we have nothing
            if (self.len == 0) return null;

            // Get the index we're going to read data from and do some
            // accounting. We don't copy the value here to avoid copying twice.
            const n = self.read;
            self.read += 1;
            if (self.read >= bounds) self.read -= bounds;
            self.len -= 1;

            // If we have consumers waiting on a full queue, notify.
            if (self.not_full_waiters > 0) self.cond_not_full.signal(io);

            return self.data[n];
        }

        /// Pop all values from the queue. This will hold the big mutex
        /// until `deinit` is called on the return value. This is used if
        /// you know you're going to "pop" and utilize all the values
        /// quickly to avoid many locks, bounds checks, and cv signals.
        pub fn drain(self: *Self, io: std.Io) DrainIterator {
            self.mutex.lockUncancelable(io);
            return .{ .queue = self };
        }

        pub const DrainIterator = struct {
            queue: *Self,

            pub fn next(self: *DrainIterator) ?T {
                if (self.queue.len == 0) return null;

                // Read and account
                const n = self.queue.read;
                self.queue.read += 1;
                if (self.queue.read >= bounds) self.queue.read -= bounds;
                self.queue.len -= 1;

                return self.queue.data[n];
            }

            pub fn deinit(self: *DrainIterator, io: std.Io) void {
                // If we have consumers waiting on a full queue, notify.
                if (self.queue.not_full_waiters > 0) self.queue.cond_not_full.signal(io);

                // Unlock
                self.queue.mutex.unlock(io);
            }
        };

        /// Returns true if the queue is full. This is not public because
        /// it requires the lock to be held.
        inline fn full(self: *Self) bool {
            return self.len == bounds;
        }
    };
}

test "basic push and pop" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Should have no values
    try testing.expect(q.pop(io) == null);

    // Push until we're full
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(io, 2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 3), q.push(io, 3, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 4), q.push(io, 4, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 5, .{ .instant = {} }));

    // Pop!
    try testing.expect(q.pop(io).? == 1);
    try testing.expect(q.pop(io).? == 2);
    try testing.expect(q.pop(io).? == 3);
    try testing.expect(q.pop(io).? == 4);
    try testing.expect(q.pop(io) == null);

    // Drain does nothing
    var it = q.drain(io);
    try testing.expect(it.next() == null);
    it.deinit(io);

    // Verify we can still push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
}

test "timed push" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .instant = {} }));

    // Timed push should fail
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .ns = 1000 }));
}

test "cancelled push releases a blocked producer and rejects later sends" {
    const testing = std.testing;
    const io = testing.io;
    const Q = BlockingQueue(u64, 1);
    var q: Q = .{};
    var cancelled = false;
    var result: Q.Size = undefined;
    const Producer = struct {
        fn run(queue: *Q, flag: *bool, out: *Q.Size) void {
            out.* = queue.pushCancelable(std.testing.io, 2, .forever, flag);
        }
    };

    try testing.expectEqual(1, q.push(io, 1, .instant));
    const thread = try std.Thread.spawn(.{}, Producer.run, .{ &q, &cancelled, &result });
    var joined = false;
    defer if (!joined) {
        q.cancelPushes(io, &cancelled);
        thread.join();
    };
    try waitForBlockedPushes(&q, 1);
    q.cancelPushes(io, &cancelled);
    thread.join();
    joined = true;
    try testing.expectEqual(0, result);
    try testing.expectEqual(1, q.pop(io).?);
    try testing.expectEqual(0, q.pushCancelable(io, 3, .instant, &cancelled));
    try testing.expectEqual(0, q.pushCancelable(io, 3, .forever, &cancelled));
    try testing.expectEqual(0, q.pushCancelable(io, 3, .{ .ns = 1000 }, &cancelled));
    try testing.expect(q.pop(io) == null);
}

test "cancelled push preserves other producers and queued messages" {
    const testing = std.testing;
    const io = testing.io;
    const Q = BlockingQueue(u64, 1);
    const Producer = struct {
        fn run(queue: *Q, flag: ?*bool, timeout: Q.Timeout, out: *Q.Size) void {
            out.* = queue.pushCancelable(std.testing.io, 2, timeout, flag);
        }
    };
    // Both indefinitely blocked and timed producers must survive the broadcast.
    for ([_]Q.Timeout{ .forever, .{ .ns = 5 * std.time.ns_per_s } }) |timeout| {
        var q: Q = .{};
        var cancelled = false;
        var cancelled_result: Q.Size = undefined;
        var live_result: Q.Size = undefined;
        try testing.expectEqual(1, q.push(io, 1, .instant));
        const closing = try std.Thread.spawn(.{}, Producer.run, .{ &q, &cancelled, Q.Timeout.forever, &cancelled_result });
        var closing_joined = false;
        defer if (!closing_joined) {
            q.cancelPushes(io, &cancelled);
            closing.join();
        };
        const live = try std.Thread.spawn(.{}, Producer.run, .{ &q, null, timeout, &live_result });
        var live_joined = false;
        defer if (!live_joined) {
            q.cancelPushes(io, &cancelled);
            _ = q.pop(io);
            live.join();
        };
        try waitForBlockedPushes(&q, 2);
        q.cancelPushes(io, &cancelled);
        closing.join();
        closing_joined = true;
        try testing.expectEqual(0, cancelled_result);
        try testing.expectEqual(1, q.pop(io).?);
        live.join();
        live_joined = true;
        try testing.expectEqual(1, live_result);
        try testing.expectEqual(2, q.pop(io).?);
        try testing.expect(q.pop(io) == null);
    }
}

fn waitForBlockedPushes(queue: anytype, count: usize) !void {
    const io = std.testing.io;
    for (0..2000) |_| {
        queue.mutex.lockUncancelable(io);
        const waiting = queue.not_full_waiters;
        queue.mutex.unlock(io);
        if (waiting == count) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.TestTimeout;
}
