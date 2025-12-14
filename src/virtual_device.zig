const std = @import("std");

pub const ChangiesError = error{
    DeviceCreationFailed,
    DeviceDestructionFailed,
};

pub const VirtualDevice = struct {
    sink_name: [:0]const u8,
    created: bool,

    pub fn create() !VirtualDevice {
        // Create null sink using pactl command
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{
                "pactl",
                "load-module",
                "module-null-sink",
                "sink_name=changies_output",
                "sink_properties=device.description=Changies_Voice_Changer",
            },
        }) catch |err| {
            std.log.err("Failed to execute pactl: {}", .{err});
            return ChangiesError.DeviceCreationFailed;
        };
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.log.err("pactl failed with exit code: {}", .{result.term.Exited});
            std.log.err("stderr: {s}", .{result.stderr});
            return ChangiesError.DeviceCreationFailed;
        }

        std.log.info("Virtual audio device created successfully", .{});
        std.log.info("Discord users: Select 'Monitor of Changies Voice Changer' as input", .{});

        return VirtualDevice{
            .sink_name = "changies_output",
            .created = true,
        };
    }

    pub fn destroy(self: *VirtualDevice) void {
        if (!self.created) return;

        // Unload the module by sink name
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{
                "pactl",
                "unload-module",
                "module-null-sink",
            },
        }) catch {
            std.log.warn("Failed to unload virtual device (may already be removed)", .{});
            return;
        };
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        self.created = false;
        std.log.info("Virtual audio device destroyed", .{});
    }

    pub fn getSinkName(self: VirtualDevice) [:0]const u8 {
        _ = self;
        return "changies_output";
    }
};
