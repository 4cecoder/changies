const std = @import("std");

/// Bit Crusher effect - reduces bit depth and sample rate for lo-fi distortion
///
/// Creates retro digital artifacts by quantizing the signal to fewer bits
/// and reducing the effective sample rate through sample-and-hold.
pub const BitCrusher = struct {
    /// Bit depth (1-16 bits)
    bit_depth: u32,

    /// Sample rate reduction divisor (1 = no reduction, 32 = maximum)
    sample_rate_divisor: u32,

    /// Counter for sample rate reduction
    sample_counter: u32,

    /// Last held sample (for sample rate reduction)
    held_sample: f32,

    /// Wet/dry mix (0.0 = dry, 1.0 = wet)
    wet_dry: f32,

    /// Enable/disable the effect
    enabled: bool,

    /// Initialize bit crusher with default settings
    pub fn init() BitCrusher {
        return .{
            .bit_depth = 16,
            .sample_rate_divisor = 1,
            .sample_counter = 0,
            .held_sample = 0.0,
            .wet_dry = 0.5,
            .enabled = false,
        };
    }

    /// Set bit depth (1-16 bits)
    pub fn setBitDepth(self: *BitCrusher, bits: u32) void {
        self.bit_depth = std.math.clamp(bits, 1, 16);
    }

    /// Set sample rate divisor (1-32)
    pub fn setSampleRateDivisor(self: *BitCrusher, divisor: u32) void {
        self.sample_rate_divisor = std.math.clamp(divisor, 1, 32);
    }

    /// Set wet/dry mix (0.0-1.0)
    pub fn setWetDry(self: *BitCrusher, mix: f32) void {
        self.wet_dry = std.math.clamp(mix, 0.0, 1.0);
    }

    /// Enable or disable the effect
    pub fn setEnabled(self: *BitCrusher, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Get current bit depth
    pub fn getBitDepth(self: *const BitCrusher) u32 {
        return self.bit_depth;
    }

    /// Get current sample rate divisor
    pub fn getSampleRateDivisor(self: *const BitCrusher) u32 {
        return self.sample_rate_divisor;
    }

    /// Get current wet/dry mix
    pub fn getWetDry(self: *const BitCrusher) f32 {
        return self.wet_dry;
    }

    /// Get enabled state
    pub fn isEnabled(self: *const BitCrusher) bool {
        return self.enabled;
    }

    /// Reset the effect state
    pub fn reset(self: *BitCrusher) void {
        self.sample_counter = 0;
        self.held_sample = 0.0;
    }

    /// Process audio buffer with bit crushing
    ///
    /// input: input audio samples
    /// output: output buffer (same size as input)
    pub fn process(self: *BitCrusher, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            @memcpy(output, input);
            return;
        }

        // Calculate quantization levels
        const levels_shift: u5 = @intCast(self.bit_depth);
        const max_val: f32 = @floatFromInt(@as(u32, 1) << levels_shift);

        for (input, 0..) |sample, i| {
            var crushed: f32 = undefined;

            // Sample rate reduction (sample and hold)
            if (self.sample_counter == 0) {
                // Bit depth reduction (quantization)
                // Clamp input to [-1.0, 1.0]
                const clamped: f32 = std.math.clamp(sample, -1.0, 1.0);

                // Quantize to the specified bit depth
                const normalized: f32 = (clamped + 1.0) / 2.0; // Map to [0.0, 1.0]
                const quantized_level: f32 = @floor(normalized * (max_val - 1.0));
                crushed = (quantized_level / (max_val - 1.0)) * 2.0 - 1.0; // Map back to [-1.0, 1.0]

                self.held_sample = crushed;
            } else {
                // Hold the previous sample
                crushed = self.held_sample;
            }

            // Increment and wrap counter
            self.sample_counter = (self.sample_counter + 1) % self.sample_rate_divisor;

            // Mix wet and dry signals
            output[i] = sample * (1.0 - self.wet_dry) + crushed * self.wet_dry;
        }
    }

    /// Process audio buffer in place
    pub fn processInPlace(self: *BitCrusher, buffer: []f32) void {
        if (!self.enabled) {
            return;
        }

        const levels_shift: u5 = @intCast(self.bit_depth);
        const max_val: f32 = @floatFromInt(@as(u32, 1) << levels_shift);

        for (buffer) |*sample| {
            const original: f32 = sample.*;
            var crushed: f32 = undefined;

            if (self.sample_counter == 0) {
                const clamped: f32 = std.math.clamp(original, -1.0, 1.0);
                const normalized: f32 = (clamped + 1.0) / 2.0;
                const quantized_level: f32 = @floor(normalized * (max_val - 1.0));
                crushed = (quantized_level / (max_val - 1.0)) * 2.0 - 1.0;
                self.held_sample = crushed;
            } else {
                crushed = self.held_sample;
            }

            self.sample_counter = (self.sample_counter + 1) % self.sample_rate_divisor;

            sample.* = original * (1.0 - self.wet_dry) + crushed * self.wet_dry;
        }
    }
};

// Tests
test "BitCrusher initialization" {
    const bc = BitCrusher.init();
    try std.testing.expectEqual(@as(u32, 16), bc.bit_depth);
    try std.testing.expectEqual(@as(u32, 1), bc.sample_rate_divisor);
    try std.testing.expectEqual(@as(u32, 0), bc.sample_counter);
    try std.testing.expectEqual(@as(f32, 0.5), bc.wet_dry);
    try std.testing.expectEqual(false, bc.enabled);
}

test "BitCrusher parameter setters" {
    var bc = BitCrusher.init();

    bc.setBitDepth(8);
    try std.testing.expectEqual(@as(u32, 8), bc.bit_depth);

    // Test clamping
    bc.setBitDepth(32);
    try std.testing.expectEqual(@as(u32, 16), bc.bit_depth);

    bc.setBitDepth(0);
    try std.testing.expectEqual(@as(u32, 1), bc.bit_depth);

    bc.setSampleRateDivisor(4);
    try std.testing.expectEqual(@as(u32, 4), bc.sample_rate_divisor);

    bc.setWetDry(0.75);
    try std.testing.expectEqual(@as(f32, 0.75), bc.wet_dry);

    bc.setEnabled(true);
    try std.testing.expectEqual(true, bc.enabled);
}

test "BitCrusher bypass when disabled" {
    var bc = BitCrusher.init();
    bc.setEnabled(false);

    const input = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    var output: [4]f32 = undefined;

    bc.process(&input, &output);

    for (input, output) |in_sample, out_sample| {
        try std.testing.expectEqual(in_sample, out_sample);
    }
}

test "BitCrusher sample rate reduction" {
    var bc = BitCrusher.init();
    bc.setEnabled(true);
    bc.setBitDepth(16); // No bit crushing
    bc.setSampleRateDivisor(2); // Hold every other sample
    bc.setWetDry(1.0); // 100% wet

    const input = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var output: [4]f32 = undefined;

    bc.process(&input, &output);

    // First sample should be processed, second held
    try std.testing.expect(output[0] != 0.0);
    try std.testing.expectEqual(output[0], output[1]);
}
