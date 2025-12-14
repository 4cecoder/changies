const std = @import("std");

/// Ring Modulator effect - creates metallic/robotic sounds through amplitude modulation
///
/// The ring modulator multiplies the input signal with a sine wave carrier,
/// producing sum and difference frequencies that create distinctive metallic timbres.
pub const RingModulator = struct {
    /// Carrier frequency in Hz (20-5000 Hz)
    carrier_freq: f32,

    /// Current phase of the carrier oscillator (0.0-1.0)
    carrier_phase: f32,

    /// Wet/dry mix (0.0 = dry, 1.0 = wet)
    wet_dry: f32,

    /// Enable/disable the effect
    enabled: bool,

    /// Sample rate for accurate phase calculation
    sample_rate: u32,

    /// Initialize ring modulator with default settings
    pub fn init(sample_rate: u32) RingModulator {
        return .{
            .carrier_freq = 100.0,
            .carrier_phase = 0.0,
            .wet_dry = 0.5,
            .enabled = false,
            .sample_rate = sample_rate,
        };
    }

    /// Set carrier frequency (20-5000 Hz)
    pub fn setCarrierFreq(self: *RingModulator, freq: f32) void {
        self.carrier_freq = std.math.clamp(freq, 20.0, 5000.0);
    }

    /// Set wet/dry mix (0.0-1.0)
    pub fn setWetDry(self: *RingModulator, mix: f32) void {
        self.wet_dry = std.math.clamp(mix, 0.0, 1.0);
    }

    /// Enable or disable the effect
    pub fn setEnabled(self: *RingModulator, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Get current carrier frequency
    pub fn getCarrierFreq(self: *const RingModulator) f32 {
        return self.carrier_freq;
    }

    /// Get current wet/dry mix
    pub fn getWetDry(self: *const RingModulator) f32 {
        return self.wet_dry;
    }

    /// Get enabled state
    pub fn isEnabled(self: *const RingModulator) bool {
        return self.enabled;
    }

    /// Reset the effect state
    pub fn reset(self: *RingModulator) void {
        self.carrier_phase = 0.0;
    }

    /// Process audio buffer with ring modulation
    ///
    /// input: input audio samples
    /// output: output buffer (same size as input)
    pub fn process(self: *RingModulator, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            @memcpy(output, input);
            return;
        }

        const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
        const two_pi: f32 = 2.0 * std.math.pi;
        const phase_increment: f32 = self.carrier_freq / sample_rate_f;

        for (input, 0..) |sample, i| {
            // Generate carrier sine wave
            const carrier: f32 = @sin(self.carrier_phase * two_pi);

            // Ring modulation: multiply input by carrier
            const modulated: f32 = sample * carrier;

            // Mix wet and dry signals
            output[i] = sample * (1.0 - self.wet_dry) + modulated * self.wet_dry;

            // Advance carrier phase
            self.carrier_phase += phase_increment;

            // Wrap phase to [0.0, 1.0)
            if (self.carrier_phase >= 1.0) {
                self.carrier_phase -= 1.0;
            }
        }
    }

    /// Process audio buffer in place
    pub fn processInPlace(self: *RingModulator, buffer: []f32) void {
        if (!self.enabled) {
            return;
        }

        const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
        const two_pi: f32 = 2.0 * std.math.pi;
        const phase_increment: f32 = self.carrier_freq / sample_rate_f;

        for (buffer) |*sample| {
            // Generate carrier sine wave
            const carrier: f32 = @sin(self.carrier_phase * two_pi);

            // Ring modulation
            const modulated: f32 = sample.* * carrier;

            // Mix
            sample.* = sample.* * (1.0 - self.wet_dry) + modulated * self.wet_dry;

            // Advance phase
            self.carrier_phase += phase_increment;
            if (self.carrier_phase >= 1.0) {
                self.carrier_phase -= 1.0;
            }
        }
    }
};

// Tests
test "RingModulator initialization" {
    const rm = RingModulator.init(48000);
    try std.testing.expectEqual(@as(f32, 100.0), rm.carrier_freq);
    try std.testing.expectEqual(@as(f32, 0.0), rm.carrier_phase);
    try std.testing.expectEqual(@as(f32, 0.5), rm.wet_dry);
    try std.testing.expectEqual(false, rm.enabled);
}

test "RingModulator parameter setters" {
    var rm = RingModulator.init(48000);

    rm.setCarrierFreq(440.0);
    try std.testing.expectEqual(@as(f32, 440.0), rm.carrier_freq);

    // Test clamping
    rm.setCarrierFreq(10000.0);
    try std.testing.expectEqual(@as(f32, 5000.0), rm.carrier_freq);

    rm.setCarrierFreq(5.0);
    try std.testing.expectEqual(@as(f32, 20.0), rm.carrier_freq);

    rm.setWetDry(0.75);
    try std.testing.expectEqual(@as(f32, 0.75), rm.wet_dry);

    rm.setEnabled(true);
    try std.testing.expectEqual(true, rm.enabled);
}

test "RingModulator bypass when disabled" {
    var rm = RingModulator.init(48000);
    rm.setEnabled(false);

    const input = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    var output: [4]f32 = undefined;

    rm.process(&input, &output);

    for (input, output) |in_sample, out_sample| {
        try std.testing.expectEqual(in_sample, out_sample);
    }
}
