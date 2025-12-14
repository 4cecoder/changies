const std = @import("std");
const Allocator = std.mem.Allocator;

/// Comb filter with damping for reverb
const CombFilter = struct {
    buffer: []f32,
    index: usize,
    feedback: f32,
    damping: f32,
    filter_state: f32,

    pub fn init(allocator: Allocator, buffer_size: usize) !CombFilter {
        const buffer = try allocator.alloc(f32, buffer_size);
        @memset(buffer, 0.0);

        return CombFilter{
            .buffer = buffer,
            .index = 0,
            .feedback = 0.5,
            .damping = 0.5,
            .filter_state = 0.0,
        };
    }

    pub fn deinit(self: *CombFilter, allocator: Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn process(self: *CombFilter, input: f32) f32 {
        // Read from circular buffer
        const output: f32 = self.buffer[self.index];

        // One-pole lowpass filter for damping (simulates high-frequency absorption)
        self.filter_state = output * (1.0 - self.damping) + self.filter_state * self.damping;

        // Write input + filtered feedback to buffer
        self.buffer[self.index] = input + self.filter_state * self.feedback;

        // Advance circular buffer index
        self.index = (self.index + 1) % self.buffer.len;

        return output;
    }

    pub fn setFeedback(self: *CombFilter, val: f32) void {
        self.feedback = std.math.clamp(val, 0.0, 1.0);
    }

    pub fn setDamping(self: *CombFilter, val: f32) void {
        self.damping = std.math.clamp(val, 0.0, 1.0);
    }

    pub fn mute(self: *CombFilter) void {
        @memset(self.buffer, 0.0);
        self.filter_state = 0.0;
    }
};

/// Allpass filter for diffusion
const AllpassFilter = struct {
    buffer: []f32,
    index: usize,

    pub fn init(allocator: Allocator, buffer_size: usize) !AllpassFilter {
        const buffer = try allocator.alloc(f32, buffer_size);
        @memset(buffer, 0.0);

        return AllpassFilter{
            .buffer = buffer,
            .index = 0,
        };
    }

    pub fn deinit(self: *AllpassFilter, allocator: Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn process(self: *AllpassFilter, input: f32) f32 {
        const buffered: f32 = self.buffer[self.index];

        // Allpass filter equation: y[n] = -x[n] + x[n-D] + g*y[n-D]
        // Using g = 0.5 for stability
        const output: f32 = -input + buffered;
        self.buffer[self.index] = input + buffered * 0.5;

        self.index = (self.index + 1) % self.buffer.len;

        return output;
    }

    pub fn mute(self: *AllpassFilter) void {
        @memset(self.buffer, 0.0);
    }
};

/// Freeverb-style reverb using parallel comb filters and series allpass filters
pub const Reverb = struct {
    sample_rate: u32,
    allocator: Allocator,

    comb_filters: [8]CombFilter,
    allpass_filters: [4]AllpassFilter,

    room_size: f32,
    damping: f32,
    wet_dry: f32,
    enabled: bool,

    // Freeverb tuning constants
    const COMB_TUNING_L1 = 1116;
    const COMB_TUNING_L2 = 1188;
    const COMB_TUNING_L3 = 1277;
    const COMB_TUNING_L4 = 1356;
    const COMB_TUNING_L5 = 1422;
    const COMB_TUNING_L6 = 1491;
    const COMB_TUNING_L7 = 1557;
    const COMB_TUNING_L8 = 1617;

    const ALLPASS_TUNING_L1 = 556;
    const ALLPASS_TUNING_L2 = 441;
    const ALLPASS_TUNING_L3 = 341;
    const ALLPASS_TUNING_L4 = 225;

    const SCALE_WET = 3.0;
    const SCALE_DAMPING = 0.4;
    const SCALE_ROOM = 0.28;
    const OFFSET_ROOM = 0.7;

    pub fn init(allocator: Allocator, sample_rate: u32) !Reverb {
        // Scale delay times based on sample rate (tuned for 44100 Hz)
        const scale: f32 = @as(f32, @floatFromInt(sample_rate)) / 44100.0;

        const comb_sizes = [8]usize{
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNING_L1)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNING_L2)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNING_L3)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNING_L4)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNING_L5)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNING_L6)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNING_L7)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNING_L8)) * scale)),
        };

        const allpass_sizes = [4]usize{
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(ALLPASS_TUNING_L1)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(ALLPASS_TUNING_L2)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(ALLPASS_TUNING_L3)) * scale)),
            @as(usize, @intFromFloat(@as(f32, @floatFromInt(ALLPASS_TUNING_L4)) * scale)),
        };

        var reverb = Reverb{
            .sample_rate = sample_rate,
            .allocator = allocator,
            .comb_filters = undefined,
            .allpass_filters = undefined,
            .room_size = 0.5,
            .damping = 0.5,
            .wet_dry = 0.3,
            .enabled = true,
        };

        // Initialize comb filters
        var initialized_combs: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized_combs) : (i += 1) {
                reverb.comb_filters[i].deinit(allocator);
            }
        }

        for (&reverb.comb_filters, comb_sizes) |*comb, size| {
            comb.* = try CombFilter.init(allocator, size);
            initialized_combs += 1;
        }

        // Initialize allpass filters
        var initialized_allpass: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized_allpass) : (i += 1) {
                reverb.allpass_filters[i].deinit(allocator);
            }
        }

        for (&reverb.allpass_filters, allpass_sizes) |*allpass, size| {
            allpass.* = try AllpassFilter.init(allocator, size);
            initialized_allpass += 1;
        }

        // Set initial parameters
        reverb.updateFilters();

        return reverb;
    }

    pub fn deinit(self: *Reverb) void {
        for (&self.comb_filters) |*comb| {
            comb.deinit(self.allocator);
        }
        for (&self.allpass_filters) |*allpass| {
            allpass.deinit(self.allocator);
        }
    }

    pub fn setRoomSize(self: *Reverb, size: f32) void {
        self.room_size = std.math.clamp(size, 0.0, 1.0);
        self.updateFilters();
    }

    pub fn setDamping(self: *Reverb, damp: f32) void {
        self.damping = std.math.clamp(damp, 0.0, 1.0);
        self.updateFilters();
    }

    pub fn setWetDry(self: *Reverb, mix: f32) void {
        self.wet_dry = std.math.clamp(mix, 0.0, 1.0);
    }

    pub fn setEnabled(self: *Reverb, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn mute(self: *Reverb) void {
        for (&self.comb_filters) |*comb| {
            comb.mute();
        }
        for (&self.allpass_filters) |*allpass| {
            allpass.mute();
        }
    }

    /// Update filter parameters based on room size and damping
    fn updateFilters(self: *Reverb) void {
        const feedback: f32 = self.room_size * SCALE_ROOM + OFFSET_ROOM;
        const damp: f32 = self.damping * SCALE_DAMPING;

        for (&self.comb_filters) |*comb| {
            comb.setFeedback(feedback);
            comb.setDamping(damp);
        }
    }

    /// Process audio through reverb effect
    pub fn process(self: *Reverb, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            @memcpy(output, input);
            return;
        }

        for (input, 0..) |sample, i| {
            // Sum all comb filter outputs
            var comb_sum: f32 = 0.0;
            for (&self.comb_filters) |*comb| {
                comb_sum += comb.process(sample);
            }

            // Pass through allpass filters in series for diffusion
            var reverb_signal: f32 = comb_sum;
            for (&self.allpass_filters) |*allpass| {
                reverb_signal = allpass.process(reverb_signal);
            }

            // Apply wet gain
            reverb_signal *= SCALE_WET;

            // Mix wet/dry
            output[i] = sample * (1.0 - self.wet_dry) + reverb_signal * self.wet_dry;
        }
    }

    /// Process audio in-place
    pub fn processInPlace(self: *Reverb, buffer: []f32) void {
        if (!self.enabled) {
            return;
        }

        for (buffer) |*sample| {
            const input: f32 = sample.*;

            // Sum all comb filter outputs
            var comb_sum: f32 = 0.0;
            for (&self.comb_filters) |*comb| {
                comb_sum += comb.process(input);
            }

            // Pass through allpass filters in series
            var reverb_signal: f32 = comb_sum;
            for (&self.allpass_filters) |*allpass| {
                reverb_signal = allpass.process(reverb_signal);
            }

            // Apply wet gain
            reverb_signal *= SCALE_WET;

            // Mix wet/dry
            sample.* = input * (1.0 - self.wet_dry) + reverb_signal * self.wet_dry;
        }
    }
};

// Basic tests
test "Reverb init and deinit" {
    const allocator = std.testing.allocator;
    var reverb = try Reverb.init(allocator, 48000);
    defer reverb.deinit();

    try std.testing.expect(reverb.enabled == true);
    try std.testing.expect(reverb.room_size == 0.5);
    try std.testing.expect(reverb.damping == 0.5);
}

test "Reverb parameter clamping" {
    const allocator = std.testing.allocator;
    var reverb = try Reverb.init(allocator, 48000);
    defer reverb.deinit();

    reverb.setRoomSize(1.5);
    try std.testing.expect(reverb.room_size == 1.0);

    reverb.setRoomSize(-0.5);
    try std.testing.expect(reverb.room_size == 0.0);

    reverb.setDamping(2.0);
    try std.testing.expect(reverb.damping == 1.0);

    reverb.setWetDry(-1.0);
    try std.testing.expect(reverb.wet_dry == 0.0);
}

test "Reverb bypass when disabled" {
    const allocator = std.testing.allocator;
    var reverb = try Reverb.init(allocator, 48000);
    defer reverb.deinit();

    reverb.setEnabled(false);

    const input = [_]f32{ 0.5, 0.3, -0.2, 0.1 };
    var output: [4]f32 = undefined;

    reverb.process(&input, &output);

    try std.testing.expectEqualSlices(f32, &input, &output);
}

test "Reverb processes audio" {
    const allocator = std.testing.allocator;
    var reverb = try Reverb.init(allocator, 48000);
    defer reverb.deinit();

    // Create impulse input - need enough samples for reverb to develop
    const input = [_]f32{1.0} ++ [_]f32{0.0} ** 4999;
    var output: [5000]f32 = undefined;

    reverb.process(&input, &output);

    // First sample should have some output (dry signal)
    try std.testing.expect(output[0] != 0.0);

    // Later samples should show reverb tail (check around 1000-2000 samples)
    var has_tail = false;
    for (output[1000..2000]) |sample| {
        if (@abs(sample) > 0.001) {
            has_tail = true;
            break;
        }
    }
    try std.testing.expect(has_tail);
}
