const std = @import("std");

pub const Severity = enum { info, warning, @"error" };

pub const Location = struct {
    table_tag: ?[4]u8 = null,
    glyph_id: ?u16 = null,
    offset: ?usize = null,
};

pub const DiagnosticEntry = struct {
    severity: Severity,
    location: Location,
    message: []const u8,
};

pub const Diagnostics = struct {
    entries: std.ArrayListUnmanaged(DiagnosticEntry) = .empty,

    pub fn add(self: *Diagnostics, allocator: std.mem.Allocator, severity: Severity, location: Location, message: []const u8) !void {
        const msg = try allocator.dupe(u8, message);
        errdefer allocator.free(msg);
        try self.entries.append(allocator, .{
            .severity = severity,
            .location = location,
            .message = msg,
        });
    }

    pub fn addError(self: *Diagnostics, allocator: std.mem.Allocator, location: Location, message: []const u8) !void {
        try self.add(allocator, .@"error", location, message);
    }

    pub fn addWarning(self: *Diagnostics, allocator: std.mem.Allocator, location: Location, message: []const u8) !void {
        try self.add(allocator, .warning, location, message);
    }

    pub fn addInfo(self: *Diagnostics, allocator: std.mem.Allocator, location: Location, message: []const u8) !void {
        try self.add(allocator, .info, location, message);
    }

    pub fn hasErrors(self: Diagnostics) bool {
        for (self.entries.items) |entry| {
            if (entry.severity == .@"error") return true;
        }
        return false;
    }

    pub fn deinit(self: *Diagnostics, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.message);
        }
        self.entries.deinit(allocator);
    }
};

pub fn formatLocation(allocator: std.mem.Allocator, loc: Location) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (loc.table_tag) |tag| {
        const trimmed = std.mem.trimEnd(u8, &tag, " ");
        try buf.appendSlice(allocator, trimmed);
        if (loc.glyph_id) |gid| {
            try buf.print(allocator, "[{d}]", .{gid});
        }
    } else if (loc.glyph_id) |gid| {
        try buf.print(allocator, "glyph[{d}]", .{gid});
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn formatEntry(allocator: std.mem.Allocator, entry: DiagnosticEntry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const has_location = entry.location.table_tag != null or entry.location.glyph_id != null;
    if (has_location) {
        if (entry.location.table_tag) |tag| {
            const trimmed = std.mem.trimEnd(u8, &tag, " ");
            try buf.appendSlice(allocator, trimmed);
            if (entry.location.glyph_id) |gid| {
                try buf.print(allocator, "[{d}]", .{gid});
            }
        } else if (entry.location.glyph_id) |gid| {
            try buf.print(allocator, "glyph[{d}]", .{gid});
        }
        try buf.appendSlice(allocator, ": ");
    }

    const sev_str: []const u8 = switch (entry.severity) {
        .info => "info: ",
        .warning => "warning: ",
        .@"error" => "error: ",
    };
    try buf.appendSlice(allocator, sev_str);
    try buf.appendSlice(allocator, entry.message);

    return try buf.toOwnedSlice(allocator);
}

test "Diagnostics add and check" {
    const allocator = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(allocator);

    try std.testing.expect(!diag.hasErrors());

    try diag.addWarning(allocator, .{ .table_tag = "head".* }, "units_per_em is outside recommended range");
    try std.testing.expect(!diag.hasErrors());

    try diag.addError(allocator, .{ .table_tag = "loca".* }, "loca offset exceeds glyf table size");
    try std.testing.expect(diag.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), diag.entries.items.len);
}

test "formatEntry with location" {
    const allocator = std.testing.allocator;
    const entry = DiagnosticEntry{
        .severity = .@"error",
        .location = .{ .table_tag = "glyf".*, .glyph_id = 42 },
        .message = "compound glyph exceeds maximum recursion depth",
    };
    const result = try formatEntry(allocator, entry);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "glyf[42]: error:") != null);
}

test "formatEntry without location" {
    const allocator = std.testing.allocator;
    const entry = DiagnosticEntry{
        .severity = .warning,
        .location = .{},
        .message = "units_per_em is outside recommended range",
    };
    const result = try formatEntry(allocator, entry);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "warning: "));
}
