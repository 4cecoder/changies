const std = @import("std");

/// Vocal Rider - Automatic gain control that maintains consistent vocal levels
///
/// Similar to Waves Vocal Rider, this effect analyzes the incoming audio
/// and automatically adjusts gain to keep vocals at a target level.
/// Uses RMS-based level detection with smooth gain changes.
pub const VocalRider = struct {
    sample_rate: u32,

    /// Target RMS level (0.0-1.0)
    target_level: f32,

    /// How quickly to respond to level changes (0.0-1.0)
    /// Lower = slower, more natural; Higher = faster, more aggressive
    sensitivity: f32,

    /// Current gain multiplier
    current_gain: f32,

    /// RMS calculation buffer
    rms_buffer: [4800]f32, // 100ms at 48kHz
    rms_index: usize,
    rms_sum: f32,

    /// Attack time coefficient (how fast gain increases)
    attack_coeff: f32,

    /// Release time coefficient (how fast gain decreases)
    release_coeff: f32,

    /// Enable/disable the effect
    enabled: bool,

    /// Range limiting (min/max gain)
    min_gain: f32,
    max_gain: f32,

    pub fn init(sample_rate: u32) VocalRider {
        const sample_rate_f: f32 = @floatFromInt(sample_rate);

        // Attack: 50ms, Release: 200ms
        const attack_time: f32 = 0.050;
        const release_time: f32 = 0.200;

        return .{
            .sample_rate = sample_rate,
            .target_level = 0.3, // -10 dBFS target
            .sensitivity = 0.5, // Medium sensitivity
            .current_gain = 1.0,
            .rms_buffer = undefined,
            .rms_index = 0,
            .rms_sum = 0.0,
            .attack_coeff = 1.0 - @exp(-1.0 / (attack_time * sample_rate_f)),
            .release_coeff = 1.0 - @exp(-1.0 / (release_time * sample_rate_f)),
            .enabled = false,
            .min_gain = 0.1, // -20 dB minimum
            .max_gain = 10.0, // +20 dB maximum
        };
    }

    pub fn reset(self: *VocalRider) void {
        @memset(&self.rms_buffer, 0.0);
        self.rms_index = 0;
        self.rms_sum = 0.0;
        self.current_gain = 1.0;
    }

    /// Set target level (0.0-1.0)
    pub fn setTargetLevel(self: *VocalRider, level: f32) void {
        self.target_level = std.math.clamp(level, 0.01, 1.0);
    }

    /// Set sensitivity (0.0-1.0)
    pub fn setSensitivity(self: *VocalRider, sensitivity: f32) void {
        self.sensitivity = std.math.clamp(sensitivity, 0.0, 1.0);
    }

    /// Set gain range
    pub fn setGainRange(self: *VocalRider, min_gain: f32, max_gain: f32) void {
        self.min_gain = std.math.clamp(min_gain, 0.01, 1.0);
        self.max_gain = std.math.clamp(max_gain, 1.0, 20.0);
    }

    pub fn setEnabled(self: *VocalRider, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) {
            self.reset();
        }
    }

    pub fn isEnabled(self: *const VocalRider) bool {
        return self.enabled;
    }

    pub fn getTargetLevel(self: *const VocalRider) f32 {
        return self.target_level;
    }

    pub fn getSensitivity(self: *const VocalRider) f32 {
        return self.sensitivity;
    }

    pub fn getCurrentGain(self: *const VocalRider) f32 {
        return self.current_gain;
    }

    /// Process audio buffer
    pub fn process(self: *VocalRider, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            if (output.ptr != input.ptr) @memcpy(output, input);
            return;
        }

        for (input, 0..) |sample, i| {
            // Update RMS calculation (sliding window)
            const old_sample = self.rms_buffer[self.rms_index];
            self.rms_buffer[self.rms_index] = sample * sample;
            self.rms_sum = self.rms_sum - old_sample + self.rms_buffer[self.rms_index];
            self.rms_index = (self.rms_index + 1) % self.rms_buffer.len;

            // Calculate current RMS level
            const buffer_len_f: f32 = @floatFromInt(self.rms_buffer.len);
            const current_rms = @sqrt(self.rms_sum / buffer_len_f);

            // Calculate target gain (avoid division by zero)
            const target_gain = if (current_rms > 0.001)
                self.target_level / current_rms
            else
                1.0;

            // Clamp target gain to range
            const clamped_target = std.math.clamp(target_gain, self.min_gain, self.max_gain);

            // Smooth gain changes (attack/release)
            const coeff = if (clamped_target > self.current_gain)
                self.attack_coeff * self.sensitivity
            else
                self.release_coeff * self.sensitivity;

            self.current_gain += (clamped_target - self.current_gain) * coeff;

            // Apply gain
            output[i] = sample * self.current_gain;
        }
    }

    /// Process audio buffer in place
    pub fn processInPlace(self: *VocalRider, buffer: []f32) void {
        if (!self.enabled) return;

        for (buffer) |*sample| {
            const original = sample.*;

            // Update RMS
            const old_sample = self.rms_buffer[self.rms_index];
            self.rms_buffer[self.rms_index] = original * original;
            self.rms_sum = self.rms_sum - old_sample + self.rms_buffer[self.rms_index];
            self.rms_index = (self.rms_index + 1) % self.rms_buffer.len;

            // Calculate RMS and target gain
            const buffer_len_f: f32 = @floatFromInt(self.rms_buffer.len);
            const current_rms = @sqrt(self.rms_sum / buffer_len_f);
            const target_gain = if (current_rms > 0.001)
                self.target_level / current_rms
            else
                1.0;

            const clamped_target = std.math.clamp(target_gain, self.min_gain, self.max_gain);

            const coeff = if (clamped_target > self.current_gain)
                self.attack_coeff * self.sensitivity
            else
                self.release_coeff * self.sensitivity;

            self.current_gain += (clamped_target - self.current_gain) * coeff;

            sample.* = original * self.current_gain;
        }
    }
};

// Tests
test "VocalRider initialization" {
    const vr = VocalRider.init(48000);
    try std.testing.expectEqual(@as(f32, 0.3), vr.target_level);
    try std.testing.expectEqual(@as(f32, 0.5), vr.sensitivity);
    try std.testing.expectEqual(@as(f32, 1.0), vr.current_gain);
    try std.testing.expectEqual(false, vr.enabled);
}

test "VocalRider bypass when disabled" {
    var vr = VocalRider.init(48000);
    vr.setEnabled(false);

    const input = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    var output: [4]f32 = undefined;

    vr.process(&input, &output);

    for (input, output) |in_sample, out_sample| {
        try std.testing.expectEqual(in_sample, out_sample);
    }
}

test "VocalRider gain adjustment" {
    var vr = VocalRider.init(48000);
    vr.setEnabled(true);
    vr.setTargetLevel(0.5);

    // Low level input should increase gain over time
    const input = [_]f32{0.1} ** 1000;
    var output: [1000]f32 = undefined;

    vr.process(&input, &output);

    // Later samples should have higher gain applied
    try std.testing.expect(output[999] > input[999]);
}
