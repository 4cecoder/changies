const std = @import("std");
const Allocator = std.mem.Allocator;

/// Simple delay effect with feedback and wet/dry mix
pub const Delay = struct {
    sample_rate: u32,
    allocator: Allocator,

    buffer: []f32,
    write_pos: usize,

    delay_time_ms: f32,
    feedback: f32,
    wet_dry: f32,
    enabled: bool,

    max_delay_ms: f32,

    pub fn init(allocator: Allocator, sample_rate: u32, max_delay_ms: f32) !Delay {
        const buffer_size = @as(usize, @intFromFloat(
            @as(f32, @floatFromInt(sample_rate)) * max_delay_ms / 1000.0,
        ));

        const buffer = try allocator.alloc(f32, buffer_size);
        @memset(buffer, 0.0);

        return Delay{
            .sample_rate = sample_rate,
            .allocator = allocator,
            .buffer = buffer,
            .write_pos = 0,
            .delay_time_ms = 250.0, // Default 250ms delay
            .feedback = 0.5, // Default moderate feedback
            .wet_dry = 0.3, // Default 30% wet
            .enabled = true,
            .max_delay_ms = max_delay_ms,
        };
    }

    pub fn deinit(self: *Delay) void {
        self.allocator.free(self.buffer);
    }

    pub fn setDelayTime(self: *Delay, time_ms: f32) void {
        self.delay_time_ms = std.math.clamp(time_ms, 0.0, self.max_delay_ms);
    }

    pub fn setFeedback(self: *Delay, feedback: f32) void {
        // Limit feedback to prevent runaway oscillation
        self.feedback = std.math.clamp(feedback, 0.0, 0.95);
    }

    pub fn setWetDry(self: *Delay, mix: f32) void {
        self.wet_dry = std.math.clamp(mix, 0.0, 1.0);
    }

    pub fn setEnabled(self: *Delay, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn mute(self: *Delay) void {
        @memset(self.buffer, 0.0);
        self.write_pos = 0;
    }

    /// Process audio through delay effect
    pub fn process(self: *Delay, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            @memcpy(output, input);
            return;
        }

        const delay_samples = @as(usize, @intFromFloat(
            self.delay_time_ms * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0,
        ));

        // Handle edge case where delay is longer than buffer
        const actual_delay = @min(delay_samples, self.buffer.len - 1);

        for (input, 0..) |sample, i| {
            // Calculate read position (circular buffer)
            const read_pos = (self.write_pos + self.buffer.len - actual_delay) % self.buffer.len;

            // Read delayed sample
            const delayed: f32 = self.buffer[read_pos];

            // Write input + feedback to buffer
            self.buffer[self.write_pos] = sample + delayed * self.feedback;

            // Mix wet/dry
            output[i] = sample * (1.0 - self.wet_dry) + delayed * self.wet_dry;

            // Advance write position
            self.write_pos = (self.write_pos + 1) % self.buffer.len;
        }
    }

    /// Process audio in-place
    pub fn processInPlace(self: *Delay, buffer: []f32) void {
        if (!self.enabled) {
            return;
        }

        const delay_samples = @as(usize, @intFromFloat(
            self.delay_time_ms * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0,
        ));

        const actual_delay = @min(delay_samples, self.buffer.len - 1);

        for (buffer) |*sample| {
            const input: f32 = sample.*;

            // Calculate read position
            const read_pos = (self.write_pos + self.buffer.len - actual_delay) % self.buffer.len;

            // Read delayed sample
            const delayed: f32 = self.buffer[read_pos];

            // Write input + feedback
            self.buffer[self.write_pos] = input + delayed * self.feedback;

            // Mix wet/dry
            sample.* = input * (1.0 - self.wet_dry) + delayed * self.wet_dry;

            // Advance write position
            self.write_pos = (self.write_pos + 1) % self.buffer.len;
        }
    }

    /// Get the current delay time in samples
    pub fn getDelaySamples(self: *const Delay) usize {
        return @as(usize, @intFromFloat(
            self.delay_time_ms * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0,
        ));
    }

    /// Get the maximum delay time in samples
    pub fn getMaxDelaySamples(self: *const Delay) usize {
        return self.buffer.len;
    }
};

// Basic tests
test "Delay init and deinit" {
    const allocator = std.testing.allocator;
    var delay = try Delay.init(allocator, 48000, 2000.0);
    defer delay.deinit();

    try std.testing.expect(delay.enabled == true);
    try std.testing.expect(delay.delay_time_ms == 250.0);
    try std.testing.expect(delay.feedback == 0.5);
    try std.testing.expect(delay.wet_dry == 0.3);
}

test "Delay buffer size calculation" {
    const allocator = std.testing.allocator;
    var delay = try Delay.init(allocator, 48000, 1000.0);
    defer delay.deinit();

    // 48000 samples/sec * 1000ms / 1000 = 48000 samples
    try std.testing.expectEqual(@as(usize, 48000), delay.buffer.len);
}

test "Delay parameter clamping" {
    const allocator = std.testing.allocator;
    var delay = try Delay.init(allocator, 48000, 1000.0);
    defer delay.deinit();

    delay.setDelayTime(5000.0);
    try std.testing.expect(delay.delay_time_ms == 1000.0);

    delay.setDelayTime(-100.0);
    try std.testing.expect(delay.delay_time_ms == 0.0);

    delay.setFeedback(1.5);
    try std.testing.expect(delay.feedback == 0.95);

    delay.setFeedback(-0.5);
    try std.testing.expect(delay.feedback == 0.0);

    delay.setWetDry(2.0);
    try std.testing.expect(delay.wet_dry == 1.0);

    delay.setWetDry(-1.0);
    try std.testing.expect(delay.wet_dry == 0.0);
}

test "Delay bypass when disabled" {
    const allocator = std.testing.allocator;
    var delay = try Delay.init(allocator, 48000, 1000.0);
    defer delay.deinit();

    delay.setEnabled(false);

    const input = [_]f32{ 0.5, 0.3, -0.2, 0.1 };
    var output: [4]f32 = undefined;

    delay.process(&input, &output);

    try std.testing.expectEqualSlices(f32, &input, &output);
}

test "Delay produces delayed output" {
    const allocator = std.testing.allocator;
    var delay = try Delay.init(allocator, 48000, 1000.0);
    defer delay.deinit();

    delay.setDelayTime(100.0); // 100ms delay
    delay.setWetDry(1.0); // 100% wet for testing
    delay.setFeedback(0.0); // No feedback for simpler test

    // Calculate expected delay in samples
    const expected_delay = @as(usize, @intFromFloat(100.0 * 48000.0 / 1000.0));

    // Create impulse input
    var input: [5000]f32 = undefined;
    @memset(&input, 0.0);
    input[0] = 1.0;

    var output: [5000]f32 = undefined;
    delay.process(&input, &output);

    // First samples should be zero (before delay)
    for (output[0..expected_delay]) |sample| {
        try std.testing.expectEqual(@as(f32, 0.0), sample);
    }

    // Sample at delay time should have the impulse
    try std.testing.expect(output[expected_delay] != 0.0);
}

test "Delay feedback creates echoes" {
    const allocator = std.testing.allocator;
    var delay = try Delay.init(allocator, 48000, 1000.0);
    defer delay.deinit();

    delay.setDelayTime(10.0); // 10ms delay (480 samples at 48kHz)
    delay.setWetDry(1.0); // 100% wet
    delay.setFeedback(0.5); // 50% feedback

    // Create impulse
    var input: [2000]f32 = undefined;
    @memset(&input, 0.0);
    input[0] = 1.0;

    var output: [2000]f32 = undefined;
    delay.process(&input, &output);

    const delay_samples = delay.getDelaySamples();

    // Should have multiple echoes due to feedback
    var echo_count: usize = 0;
    for (output, 0..) |sample, i| {
        if (i > 0 and i % delay_samples == 0 and @abs(sample) > 0.01) {
            echo_count += 1;
        }
    }

    try std.testing.expect(echo_count >= 2);
}

test "Delay mute clears buffer" {
    const allocator = std.testing.allocator;
    var delay = try Delay.init(allocator, 48000, 1000.0);
    defer delay.deinit();

    // Fill buffer with data
    const input = [_]f32{1.0} ** 100;
    var output: [100]f32 = undefined;
    delay.process(&input, &output);

    // Mute should clear buffer
    delay.mute();

    for (delay.buffer) |sample| {
        try std.testing.expectEqual(@as(f32, 0.0), sample);
    }

    try std.testing.expectEqual(@as(usize, 0), delay.write_pos);
}
