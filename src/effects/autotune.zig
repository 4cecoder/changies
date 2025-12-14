const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Musical keys (12 notes in chromatic scale)
pub const MusicalKey = enum(u8) {
    C = 0,
    Cs = 1, // C#/Db
    D = 2,
    Ds = 3, // D#/Eb
    E = 4,
    F = 5,
    Fs = 6, // F#/Gb
    G = 7,
    Gs = 8, // G#/Ab
    A = 9,
    As = 10, // A#/Bb
    B = 11,

    pub fn fromString(s: []const u8) ?MusicalKey {
        const map = std.StaticStringMap(MusicalKey).initComptime(.{
            .{ "C", .C },
            .{ "C#", .Cs },
            .{ "Db", .Cs },
            .{ "D", .D },
            .{ "D#", .Ds },
            .{ "Eb", .Ds },
            .{ "E", .E },
            .{ "F", .F },
            .{ "F#", .Fs },
            .{ "Gb", .Fs },
            .{ "G", .G },
            .{ "G#", .Gs },
            .{ "Ab", .Gs },
            .{ "A", .A },
            .{ "A#", .As },
            .{ "Bb", .As },
            .{ "B", .B },
        });
        return map.get(s);
    }
};

/// Musical scales with semitone patterns
pub const MusicalScale = enum {
    Chromatic, // All 12 notes
    Major, // W-W-H-W-W-W-H (Ionian)
    Minor, // W-H-W-W-H-W-W (Aeolian/Natural Minor)
    Dorian, // W-H-W-W-W-H-W
    Phrygian, // H-W-W-W-H-W-W
    Lydian, // W-W-W-H-W-W-H
    Mixolydian, // W-W-H-W-W-H-W

    /// Returns a boolean array indicating which notes are in the scale
    /// Index corresponds to semitone offset from root key (0-11)
    pub fn getNotes(self: MusicalScale, key: MusicalKey) [12]bool {
        var notes = [_]bool{false} ** 12;
        const root: usize = @intFromEnum(key);

        const intervals: []const u8 = switch (self) {
            .Chromatic => &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
            .Major => &[_]u8{ 0, 2, 4, 5, 7, 9, 11 }, // W-W-H-W-W-W-H
            .Minor => &[_]u8{ 0, 2, 3, 5, 7, 8, 10 }, // W-H-W-W-H-W-W
            .Dorian => &[_]u8{ 0, 2, 3, 5, 7, 9, 10 }, // W-H-W-W-W-H-W
            .Phrygian => &[_]u8{ 0, 1, 3, 5, 7, 8, 10 }, // H-W-W-W-H-W-W
            .Lydian => &[_]u8{ 0, 2, 4, 6, 7, 9, 11 }, // W-W-W-H-W-W-H
            .Mixolydian => &[_]u8{ 0, 2, 4, 5, 7, 9, 10 }, // W-W-H-W-W-H-W
        };

        for (intervals) |interval| {
            const note_index: usize = (root + interval) % 12;
            notes[note_index] = true;
        }

        return notes;
    }

    pub fn fromString(s: []const u8) ?MusicalScale {
        const map = std.StaticStringMap(MusicalScale).initComptime(.{
            .{ "chromatic", .Chromatic },
            .{ "major", .Major },
            .{ "minor", .Minor },
            .{ "dorian", .Dorian },
            .{ "phrygian", .Phrygian },
            .{ "lydian", .Lydian },
            .{ "mixolydian", .Mixolydian },
        });
        return map.get(s);
    }
};

/// Professional Auto-Tune effect using YIN pitch detection and PSOLA pitch shifting
pub const AutoTune = struct {
    sample_rate: u32,
    allocator: Allocator,

    // Settings
    key: MusicalKey,
    scale: MusicalScale,
    retune_speed: f32, // 0.0 to 1.0 (0=slow/natural, 1=instant/robotic)
    correction_amount: f32, // 0.0 to 1.0 (mix between original and corrected)
    enabled: bool,

    // YIN pitch detection
    yin_buffer_size: usize,
    yin_buffer: []f32,
    yin_threshold: f32,
    min_freq: f32, // Minimum detectable frequency (Hz)
    max_freq: f32, // Maximum detectable frequency (Hz)

    // PSOLA pitch shifting
    window_size: usize,
    hop_size: usize,
    window: []f32, // Hann window
    input_buffer: []f32,
    output_buffer: []f32,
    buffer_pos: usize,

    // State
    detected_freq: f32,
    target_freq: f32,
    current_shift_ratio: f32,
    prev_phase: f32,

    const YIN_THRESHOLD = 0.15; // Lower = more strict pitch detection
    const MIN_FREQ = 80.0; // Lowest male voice (~E2)
    const MAX_FREQ = 800.0; // Highest normal speech (~G5)

    pub fn init(allocator: Allocator, sample_rate: u32) !AutoTune {
        // Calculate buffer sizes
        const yin_buffer_size: usize = 2048; // Good balance for latency/accuracy
        const window_size: usize = 2048;
        const hop_size: usize = 512; // 75% overlap for smooth PSOLA

        // Allocate YIN buffer
        const yin_buffer = try allocator.alloc(f32, yin_buffer_size);
        errdefer allocator.free(yin_buffer);
        @memset(yin_buffer, 0.0);

        // Allocate and initialize Hann window
        const window = try allocator.alloc(f32, window_size);
        errdefer allocator.free(window);
        for (window, 0..) |*w, i| {
            const i_f32: f32 = @floatFromInt(i);
            const size_f32: f32 = @floatFromInt(window_size);
            w.* = 0.5 - 0.5 * @cos(2.0 * math.pi * i_f32 / size_f32);
        }

        // Allocate processing buffers
        const input_buffer = try allocator.alloc(f32, window_size * 2);
        errdefer allocator.free(input_buffer);
        @memset(input_buffer, 0.0);

        const output_buffer = try allocator.alloc(f32, window_size * 2);
        errdefer allocator.free(output_buffer);
        @memset(output_buffer, 0.0);

        return AutoTune{
            .sample_rate = sample_rate,
            .allocator = allocator,
            .key = .C,
            .scale = .Chromatic,
            .retune_speed = 0.8, // Default: fairly quick correction
            .correction_amount = 1.0, // Default: full correction
            .enabled = true,
            .yin_buffer_size = yin_buffer_size,
            .yin_buffer = yin_buffer,
            .yin_threshold = YIN_THRESHOLD,
            .min_freq = MIN_FREQ,
            .max_freq = MAX_FREQ,
            .window_size = window_size,
            .hop_size = hop_size,
            .window = window,
            .input_buffer = input_buffer,
            .output_buffer = output_buffer,
            .buffer_pos = 0,
            .detected_freq = 0.0,
            .target_freq = 0.0,
            .current_shift_ratio = 1.0,
            .prev_phase = 0.0,
        };
    }

    pub fn deinit(self: *AutoTune) void {
        self.allocator.free(self.yin_buffer);
        self.allocator.free(self.window);
        self.allocator.free(self.input_buffer);
        self.allocator.free(self.output_buffer);
    }

    pub fn setKey(self: *AutoTune, key: MusicalKey) void {
        self.key = key;
    }

    pub fn setScale(self: *AutoTune, scale: MusicalScale) void {
        self.scale = scale;
    }

    pub fn setRetuneSpeed(self: *AutoTune, speed: f32) void {
        self.retune_speed = std.math.clamp(speed, 0.0, 1.0);
    }

    pub fn setCorrection(self: *AutoTune, amount: f32) void {
        self.correction_amount = std.math.clamp(amount, 0.0, 1.0);
    }

    pub fn setEnabled(self: *AutoTune, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Process audio buffer with auto-tune effect
    pub fn process(self: *AutoTune, input: []const f32, output: []f32) void {
        if (!self.enabled or input.len != output.len) {
            @memcpy(output, input);
            return;
        }

        // For small buffers, just copy (we need enough samples for pitch detection)
        if (input.len < self.hop_size) {
            @memcpy(output, input);
            return;
        }

        // 1. Detect pitch using YIN algorithm
        const detected_freq = self.detectPitch(input);

        if (detected_freq > 0.0) {
            self.detected_freq = detected_freq;

            // 2. Find target note in scale
            const target_note = self.findNearestNote(detected_freq);
            self.target_freq = noteToFrequency(target_note);

            // 3. Calculate shift ratio with smoothing (retune speed)
            const ideal_ratio: f32 = self.target_freq / detected_freq;
            self.current_shift_ratio = lerp(
                self.current_shift_ratio,
                ideal_ratio,
                self.retune_speed,
            );
        }

        // 4. Apply pitch shift using PSOLA
        self.shiftPitch(input, output, self.current_shift_ratio);

        // 5. Mix with original based on correction_amount
        if (self.correction_amount < 1.0) {
            for (output, 0..) |*out, i| {
                out.* = lerp(input[i], out.*, self.correction_amount);
            }
        }
    }

    /// YIN algorithm for fundamental frequency detection
    /// Returns frequency in Hz, or 0.0 if unvoiced/unpitched
    fn detectPitch(self: *AutoTune, buffer: []const f32) f32 {
        const buf_len = @min(buffer.len, self.yin_buffer_size);
        if (buf_len < 100) return 0.0; // Too short for meaningful detection

        // Calculate difference function
        const half_len = buf_len / 2;
        var diff_sum: f32 = 0.0;

        // Tau = 0 special case
        self.yin_buffer[0] = 1.0;

        // Calculate cumulative mean normalized difference
        for (1..half_len) |tau| {
            var diff: f32 = 0.0;
            for (0..half_len) |i| {
                if (i + tau < buf_len) {
                    const delta: f32 = buffer[i] - buffer[i + tau];
                    diff += delta * delta;
                }
            }

            diff_sum += diff;
            if (diff_sum > 0.0) {
                const tau_f32: f32 = @floatFromInt(tau);
                self.yin_buffer[tau] = diff * tau_f32 / diff_sum;
            } else {
                self.yin_buffer[tau] = 1.0;
            }
        }

        // Find first minimum below threshold
        var tau_estimate: usize = 0;
        const sample_rate_f32: f32 = @floatFromInt(self.sample_rate);
        const min_tau: usize = @intFromFloat(sample_rate_f32 / self.max_freq);
        const max_tau: usize = @intFromFloat(sample_rate_f32 / self.min_freq);

        for (min_tau..@min(max_tau, half_len - 1)) |tau| {
            if (self.yin_buffer[tau] < self.yin_threshold) {
                // Check if this is a local minimum
                if (tau > 0 and tau < half_len - 1) {
                    if (self.yin_buffer[tau] < self.yin_buffer[tau - 1] and
                        self.yin_buffer[tau] < self.yin_buffer[tau + 1])
                    {
                        tau_estimate = tau;
                        break;
                    }
                }
            }
        }

        if (tau_estimate == 0) {
            return 0.0; // No pitch detected (unvoiced)
        }

        // Parabolic interpolation for sub-sample precision
        const tau_f32: f32 = @floatFromInt(tau_estimate);
        var refined_tau = tau_f32;

        if (tau_estimate > 0 and tau_estimate < half_len - 1) {
            const prev: f32 = self.yin_buffer[tau_estimate - 1];
            const curr: f32 = self.yin_buffer[tau_estimate];
            const next: f32 = self.yin_buffer[tau_estimate + 1];
            refined_tau = tau_f32 + (next - prev) / (2.0 * (2.0 * curr - next - prev));
        }

        const freq: f32 = sample_rate_f32 / refined_tau;
        return if (freq >= self.min_freq and freq <= self.max_freq) freq else 0.0;
    }

    /// Find nearest note in the current key/scale
    fn findNearestNote(self: *AutoTune, freq: f32) u8 {
        if (freq <= 0.0) return 69; // Default to A4

        // Convert frequency to continuous MIDI note number
        const midi_note_continuous: f32 = 12.0 * math.log2(freq / 440.0) + 69.0;
        const base_note: u8 = @intFromFloat(@round(midi_note_continuous));

        // Get scale notes
        const scale_notes = self.scale.getNotes(self.key);

        // For chromatic scale, just return the nearest note
        if (self.scale == .Chromatic) {
            return base_note;
        }

        // Find nearest note in scale
        var best_note = base_note;
        var min_distance: f32 = 12.0; // Start with octave distance

        // Check notes within +/- 6 semitones
        var offset: i16 = -6;
        while (offset <= 6) : (offset += 1) {
            const test_note_signed: i16 = @as(i16, base_note) + offset;
            if (test_note_signed < 0 or test_note_signed > 127) continue;

            const test_note: u8 = @intCast(test_note_signed);
            const note_class: usize = test_note % 12;

            if (scale_notes[note_class]) {
                const offset_f32: f32 = @floatFromInt(offset);
                const distance: f32 = @abs(offset_f32);
                if (distance < min_distance) {
                    min_distance = distance;
                    best_note = test_note;
                }
            }
        }

        return best_note;
    }

    /// PSOLA-based pitch shifting
    /// Preserves formants and naturalness better than simple resampling
    fn shiftPitch(self: *AutoTune, input: []const f32, output: []f32, ratio: f32) void {
        // Clamp ratio to reasonable bounds
        const safe_ratio: f32 = std.math.clamp(ratio, 0.5, 2.0);

        if (@abs(safe_ratio - 1.0) < 0.001) {
            // No shift needed
            @memcpy(output, input);
            return;
        }

        // Simple time-domain pitch shifting using overlap-add
        // This is a simplified PSOLA implementation
        const window_size_f32: f32 = @floatFromInt(self.window_size);
        const hop_size_f32: f32 = @floatFromInt(self.hop_size);

        var read_pos: f32 = 0.0;
        var write_pos: usize = 0;

        @memset(output, 0.0);

        while (write_pos < output.len) {
            const read_index: usize = @intFromFloat(@floor(read_pos));

            if (read_index + self.window_size >= input.len) {
                break;
            }

            // Apply windowed grain
            for (0..self.window_size) |i| {
                if (write_pos + i >= output.len) break;

                const sample = input[read_index + i];
                const windowed = sample * self.window[i];

                output[write_pos + i] += windowed;
            }

            // Advance pointers
            // Read advances slower/faster based on pitch shift ratio
            read_pos += hop_size_f32 / safe_ratio;
            write_pos += self.hop_size;
        }

        // Normalize output to prevent amplitude changes
        const max_overlap: f32 = window_size_f32 / hop_size_f32;
        const scale: f32 = 1.0 / max_overlap;
        for (output) |*sample| {
            sample.* *= scale;
        }
    }
};

/// Convert MIDI note number to frequency in Hz
/// MIDI note 69 = A4 = 440 Hz
fn noteToFrequency(note: u8) f32 {
    const note_f32: f32 = @floatFromInt(note);
    return 440.0 * math.pow(f32, 2.0, (note_f32 - 69.0) / 12.0);
}

/// Linear interpolation
fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

// Tests
test "MusicalScale.getNotes - Major scale" {
    const scale = MusicalScale.Major;
    const notes = scale.getNotes(.C);

    // C Major: C D E F G A B
    try std.testing.expect(notes[0]); // C
    try std.testing.expect(!notes[1]); // C#
    try std.testing.expect(notes[2]); // D
    try std.testing.expect(!notes[3]); // D#
    try std.testing.expect(notes[4]); // E
    try std.testing.expect(notes[5]); // F
    try std.testing.expect(!notes[6]); // F#
    try std.testing.expect(notes[7]); // G
    try std.testing.expect(!notes[8]); // G#
    try std.testing.expect(notes[9]); // A
    try std.testing.expect(!notes[10]); // A#
    try std.testing.expect(notes[11]); // B
}

test "MusicalScale.getNotes - Minor scale" {
    const scale = MusicalScale.Minor;
    const notes = scale.getNotes(.A);

    // A Minor: A B C D E F G
    try std.testing.expect(notes[9]); // A
    try std.testing.expect(!notes[10]); // A#
    try std.testing.expect(notes[11]); // B
    try std.testing.expect(notes[0]); // C
    try std.testing.expect(!notes[1]); // C#
    try std.testing.expect(notes[2]); // D
    try std.testing.expect(!notes[3]); // D#
    try std.testing.expect(notes[4]); // E
    try std.testing.expect(notes[5]); // F
    try std.testing.expect(!notes[6]); // F#
    try std.testing.expect(notes[7]); // G
    try std.testing.expect(!notes[8]); // G#
}

test "noteToFrequency - A4 = 440 Hz" {
    const freq = noteToFrequency(69);
    try std.testing.expectApproxEqAbs(440.0, freq, 0.01);
}

test "noteToFrequency - C4 = 261.63 Hz" {
    const freq = noteToFrequency(60); // Middle C
    try std.testing.expectApproxEqAbs(261.63, freq, 0.01);
}

test "AutoTune - init and deinit" {
    const allocator = std.testing.allocator;
    var autotune = try AutoTune.init(allocator, 48000);
    defer autotune.deinit();

    try std.testing.expect(autotune.enabled);
    try std.testing.expectEqual(MusicalKey.C, autotune.key);
    try std.testing.expectEqual(MusicalScale.Chromatic, autotune.scale);
}

test "AutoTune - setters" {
    const allocator = std.testing.allocator;
    var autotune = try AutoTune.init(allocator, 48000);
    defer autotune.deinit();

    autotune.setKey(.Fs);
    try std.testing.expectEqual(MusicalKey.Fs, autotune.key);

    autotune.setScale(.Major);
    try std.testing.expectEqual(MusicalScale.Major, autotune.scale);

    autotune.setRetuneSpeed(0.5);
    try std.testing.expectApproxEqAbs(0.5, autotune.retune_speed, 0.001);

    autotune.setCorrection(0.75);
    try std.testing.expectApproxEqAbs(0.75, autotune.correction_amount, 0.001);

    autotune.setEnabled(false);
    try std.testing.expect(!autotune.enabled);
}
