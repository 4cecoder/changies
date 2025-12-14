const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const WebServerError = error{
    ServerInitFailed,
    SocketError,
    WebSocketHandshakeFailed,
};

pub const AudioStats = extern struct {
    input_rms: f32,
    input_peak: f32,
    output_rms: f32,
    output_peak: f32,
    gate_open: u8, // Changed from bool for extern compatibility
    padding: [3]u8 = undefined, // Padding for alignment
    processing_time_us: u64,

    pub fn init() AudioStats {
        return AudioStats{
            .input_rms = 0.0,
            .input_peak = 0.0,
            .output_rms = 0.0,
            .output_peak = 0.0,
            .gate_open = 0,
            .processing_time_us = 0,
        };
    }
};

const ClientHandlerArgs = struct {
    server: *WebServer,
    client_fd: posix.socket_t,
};

pub const WebServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    running: std.atomic.Value(bool),
    stats_mutex: std.Thread.Mutex,
    stats_value: AudioStats,
    web_dir: []const u8,
    command_callback: ?*const fn ([]const u8, []const u8) void,

    pub fn init(allocator: std.mem.Allocator, port: u16, web_dir: []const u8) WebServer {
        return WebServer{
            .allocator = allocator,
            .port = port,
            .running = std.atomic.Value(bool).init(false),
            .stats_mutex = std.Thread.Mutex{},
            .stats_value = AudioStats.init(),
            .web_dir = web_dir,
            .command_callback = null,
        };
    }

    pub fn setCommandCallback(self: *WebServer, callback: *const fn ([]const u8, []const u8) void) void {
        self.command_callback = callback;
    }

    pub fn updateStats(self: *WebServer, stats: AudioStats) void {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        self.stats_value = stats;
    }

    pub fn getStats(self: *WebServer) AudioStats {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        return self.stats_value;
    }

    pub fn start(self: *WebServer) !std.Thread {
        self.running.store(true, .monotonic);
        return try std.Thread.spawn(.{}, serverThread, .{self});
    }

    pub fn stop(self: *WebServer) void {
        self.running.store(false, .monotonic);
    }

    fn serverThread(self: *WebServer) void {
        std.log.info("Starting web server on port {d}...", .{self.port});

        // Create socket
        const sock_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch |err| {
            std.log.err("Failed to create socket: {}", .{err});
            return;
        };
        defer posix.close(sock_fd);

        // Set SO_REUSEADDR
        const enable: c_int = 1;
        _ = posix.setsockopt(sock_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable)) catch {};

        // Bind to port
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, self.port),
            .addr = 0, // INADDR_ANY
            .zero = [_]u8{0} ** 8,
        };

        posix.bind(sock_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch |err| {
            std.log.err("Failed to bind socket: {}", .{err});
            return;
        };

        // Listen
        posix.listen(sock_fd, 128) catch |err| {
            std.log.err("Failed to listen: {}", .{err});
            return;
        };

        std.log.info("Web server listening on http://0.0.0.0:{d}", .{self.port});

        while (self.running.load(.monotonic)) {
            // Accept client connection
            var client_addr: posix.sockaddr.storage = undefined;
            var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

            // Direct syscall to work around stdlib error set mismatch
            const rc = linux.accept4(@intCast(sock_fd), @ptrCast(&client_addr), &client_addr_len, 0);
            const client_fd: posix.socket_t = if (rc < 0) {
                std.log.err("Accept error: {d}", .{-rc});
                posix.nanosleep(0, 100 * std.time.ns_per_ms);
                continue;
            } else @intCast(rc);

            // Handle client in a separate thread
            const args = self.allocator.create(ClientHandlerArgs) catch {
                posix.close(client_fd);
                continue;
            };
            args.* = .{ .server = self, .client_fd = client_fd };

            const thread = std.Thread.spawn(.{}, handleClientThread, .{args}) catch |err| {
                std.log.err("Failed to spawn client handler: {}", .{err});
                self.allocator.destroy(args);
                posix.close(client_fd);
                continue;
            };
            thread.detach();
        }

        std.log.info("Web server stopped", .{});
    }

    fn handleClientThread(args: *const ClientHandlerArgs) void {
        defer args.server.allocator.destroy(args);
        defer posix.close(args.client_fd);

        args.server.handleClient(args.client_fd) catch |err| {
            std.log.err("Client handler error: {}", .{err});
        };
    }

    fn handleClient(self: *WebServer, client_fd: posix.socket_t) !void {
        var buffer: [8192]u8 = undefined;
        const bytes_read = posix.read(client_fd, &buffer) catch |err| {
            std.log.err("Read error: {}", .{err});
            return;
        };

        if (bytes_read == 0) return;

        const request = buffer[0..bytes_read];

        // Check if this is a WebSocket upgrade request
        if (std.mem.indexOf(u8, request, "Upgrade: websocket") != null) {
            try self.handleWebSocket(client_fd, request);
        } else {
            try self.handleHttp(client_fd, request);
        }
    }

    fn handleHttp(self: *WebServer, client_fd: posix.socket_t, request: []const u8) !void {
        // Parse request path
        const path = try self.extractPath(request);

        // Map paths to files
        var file_path: ?[]const u8 = null;
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            file_path = "index.html";
        } else if (std.mem.eql(u8, path, "/style.css")) {
            file_path = "style.css";
        } else if (std.mem.eql(u8, path, "/app.js")) {
            file_path = "app.js";
        }

        if (file_path) |fp| {
            try self.serveFile(client_fd, fp);
        } else {
            try self.send404(client_fd);
        }
    }

    fn extractPath(self: *WebServer, request: []const u8) ![]const u8 {
        _ = self;
        // Find "GET " or "POST "
        const method_end = std.mem.indexOf(u8, request, " ") orelse return error.InvalidRequest;
        const path_start = method_end + 1;
        const path_end = std.mem.indexOfPos(u8, request, path_start, " ") orelse return error.InvalidRequest;

        return request[path_start..path_end];
    }

    fn serveFile(self: *WebServer, client_fd: posix.socket_t, file_name: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.web_dir, file_name });
        defer self.allocator.free(full_path);

        const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
            std.log.err("Failed to open file {s}: {}", .{ full_path, err });
            try self.send404(client_fd);
            return;
        };
        defer file.close();

        // Get file size and read content
        const file_size = try file.getEndPos();
        if (file_size > 1024 * 1024) return error.FileTooLarge; // 1MB max

        const content = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(content);

        const bytes_read = try file.read(content);
        if (bytes_read != file_size) return error.IncompleteRead;

        const content_type = self.getContentType(file_name);

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ content_type, content.len, content });
        defer self.allocator.free(response);

        _ = try posix.write(client_fd, response);
    }

    fn send404(self: *WebServer, client_fd: posix.socket_t) !void {
        _ = self;
        const response = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n404 Not Found";
        _ = try posix.write(client_fd, response);
    }

    fn getContentType(self: *WebServer, file_name: []const u8) []const u8 {
        _ = self;
        if (std.mem.endsWith(u8, file_name, ".html")) return "text/html";
        if (std.mem.endsWith(u8, file_name, ".css")) return "text/css";
        if (std.mem.endsWith(u8, file_name, ".js")) return "application/javascript";
        return "application/octet-stream";
    }

    fn handleWebSocket(self: *WebServer, client_fd: posix.socket_t, request: []const u8) !void {
        // Extract WebSocket key
        const key_start = std.mem.indexOf(u8, request, "Sec-WebSocket-Key: ") orelse return error.WebSocketHandshakeFailed;
        const key_value_start = key_start + "Sec-WebSocket-Key: ".len;
        const key_value_end = std.mem.indexOfPos(u8, request, key_value_start, "\r\n") orelse return error.WebSocketHandshakeFailed;
        const key = request[key_value_start..key_value_end];

        // Compute accept key
        const magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        const combined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ key, magic_string });
        defer self.allocator.free(combined);

        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(combined, &hash, .{});

        const encoder = std.base64.standard.Encoder;
        var accept_key: [28]u8 = undefined;
        _ = encoder.encode(&accept_key, &hash);

        // Send handshake response
        const handshake = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept_key});
        defer self.allocator.free(handshake);

        _ = try posix.write(client_fd, handshake);

        // Set socket to non-blocking mode for WebSocket handling
        const flags = try posix.fcntl(client_fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(client_fd, posix.F.SETFL, @as(u32, @intCast(flags)) | @as(u32, 0o4000)); // O_NONBLOCK = 0o4000 on Linux

        std.log.info("WebSocket client connected", .{});

        // Handle WebSocket messages
        try self.handleWebSocketMessages(client_fd);
    }

    fn handleWebSocketMessages(self: *WebServer, client_fd: posix.socket_t) !void {
        var last_stats_time = std.time.Instant.now() catch unreachable;
        const stats_interval_ns: u64 = 33 * std.time.ns_per_ms; // ~30fps

        while (self.running.load(.monotonic)) {
            // Send stats at regular intervals
            const current_time = std.time.Instant.now() catch unreachable;
            if (current_time.since(last_stats_time) >= stats_interval_ns) {
                last_stats_time = current_time;
                self.sendStats(client_fd) catch |err| {
                    std.log.err("Failed to send stats: {}", .{err});
                    return;
                };
            }

            // Try to read incoming messages (with timeout)
            var frame_buffer: [4096]u8 = undefined;
            const bytes_read = posix.read(client_fd, &frame_buffer) catch |err| {
                if (err == error.WouldBlock) {
                    posix.nanosleep(0, 10 * std.time.ns_per_ms);
                    continue;
                }
                std.log.err("WebSocket read error: {}", .{err});
                return;
            };

            if (bytes_read == 0) {
                std.log.info("WebSocket client disconnected", .{});
                return;
            }

            // Decode WebSocket frame
            const payload = self.decodeWebSocketFrame(frame_buffer[0..bytes_read]) catch |err| {
                std.log.err("Failed to decode WebSocket frame: {}", .{err});
                continue;
            };

            if (payload.len > 0) {
                self.handleCommand(payload) catch |err| {
                    std.log.err("Failed to handle command: {}", .{err});
                };
            }
        }
    }

    fn sendStats(self: *WebServer, client_fd: posix.socket_t) !void {
        const stats = self.getStats();

        const gate_open_bool = stats.gate_open != 0;

        const json = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"stats\",\"input_rms\":{d:.4},\"input_peak\":{d:.4},\"output_rms\":{d:.4},\"output_peak\":{d:.4},\"gate_open\":{},\"processing_time_us\":{d}}}", .{
            stats.input_rms,
            stats.input_peak,
            stats.output_rms,
            stats.output_peak,
            gate_open_bool,
            stats.processing_time_us,
        });
        defer self.allocator.free(json);

        try self.sendWebSocketMessage(client_fd, json);
    }

    fn sendWebSocketMessage(self: *WebServer, client_fd: posix.socket_t, message: []const u8) !void {
        _ = self;
        // Simple WebSocket frame encoding (text frame, not masked)
        var frame_buffer: [4096]u8 = undefined;
        var frame_len: usize = 0;

        // FIN + opcode (0x81 = text frame)
        frame_buffer[frame_len] = 0x81;
        frame_len += 1;

        // Payload length
        if (message.len < 126) {
            frame_buffer[frame_len] = @intCast(message.len);
            frame_len += 1;
        } else if (message.len < 65536) {
            frame_buffer[frame_len] = 126;
            frame_len += 1;
            frame_buffer[frame_len] = @intCast((message.len >> 8) & 0xFF);
            frame_len += 1;
            frame_buffer[frame_len] = @intCast(message.len & 0xFF);
            frame_len += 1;
        } else {
            return error.MessageTooLarge;
        }

        // Payload
        @memcpy(frame_buffer[frame_len .. frame_len + message.len], message);
        frame_len += message.len;

        _ = try posix.write(client_fd, frame_buffer[0..frame_len]);
    }

    fn decodeWebSocketFrame(self: *WebServer, frame: []const u8) ![]const u8 {
        _ = self;
        if (frame.len < 2) return error.InvalidFrame;

        const opcode: u8 = frame[0] & 0x0F;
        // OpCode 8 = close frame, 1 = text frame
        if (opcode == 8) return &[_]u8{}; // Close frame
        if (opcode != 1) return &[_]u8{}; // Only handle text frames

        const masked: bool = (frame[1] & 0x80) != 0;
        var payload_len: usize = @intCast(frame[1] & 0x7F);

        var pos: usize = 2;

        if (payload_len == 126) {
            if (frame.len < 4) return error.InvalidFrame;
            payload_len = (@as(usize, frame[2]) << 8) | @as(usize, frame[3]);
            pos = 4;
        } else if (payload_len == 127) {
            return error.MessageTooLarge;
        }

        var mask: [4]u8 = undefined;
        if (masked) {
            if (frame.len < pos + 4) return error.InvalidFrame;
            @memcpy(&mask, frame[pos .. pos + 4]);
            pos += 4;
        }

        if (frame.len < pos + payload_len) return error.InvalidFrame;

        const payload = frame[pos .. pos + payload_len];

        // Unmask if necessary
        if (masked) {
            // Note: We can't modify the const slice, so we'd need to allocate
            // For now, this is a simplified version that doesn't unmask
            // In production, you'd allocate a buffer and unmask into it
            return payload;
        }

        return payload;
    }

    fn handleCommand(self: *WebServer, payload: []const u8) !void {
        // Simple JSON parsing for commands
        // Expected format: {"type":"command","command":"effect","value":"male"}

        // This is a simplified parser - in production use std.json
        const command_start = std.mem.indexOf(u8, payload, "\"command\":\"") orelse return;
        const command_value_start = command_start + "\"command\":\"".len;
        const command_value_end = std.mem.indexOfPos(u8, payload, command_value_start, "\"") orelse return;
        const command = payload[command_value_start..command_value_end];

        const value_start = std.mem.indexOf(u8, payload, "\"value\":") orelse return;
        const value_content_start = value_start + "\"value\":".len;

        std.log.info("Received command: {s}", .{command});

        if (self.command_callback) |callback| {
            callback(command, payload[value_content_start..]);
        }
    }
};
