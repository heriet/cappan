const std = @import("std");
const builtin = @import("builtin");
const cappan_core = @import("cappan_core");

const Font = cappan_core.font.Font;

pub const FontEntry = struct {
    path: []const u8,
    family: ?[]const u8,
    subfamily: ?[]const u8,
    full_name: ?[]const u8,
    font_index: u32,
};

pub const FontList = struct {
    entries: std.ArrayListUnmanaged(FontEntry) = .empty,
    allocator: std.mem.Allocator,
    path_strings: std.ArrayListUnmanaged([]u8) = .empty,
    name_strings: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *FontList) void {
        for (self.path_strings.items) |path| self.allocator.free(path);
        for (self.name_strings.items) |name| self.allocator.free(name);
        self.entries.deinit(self.allocator);
        self.path_strings.deinit(self.allocator);
        self.name_strings.deinit(self.allocator);
    }

    pub fn findByFamily(self: *const FontList, family: []const u8) ?FontEntry {
        for (self.entries.items) |entry| {
            if (entry.family) |entry_family| {
                if (std.ascii.eqlIgnoreCase(entry_family, family)) return entry;
            }
        }
        return null;
    }

    pub fn findByName(self: *const FontList, name: []const u8) ?FontEntry {
        // Priority: 1 = exact family match, 2 = exact full_name match, 3 = partial family match
        var best: ?FontEntry = null;
        var best_priority: u8 = 4; // lower = better
        for (self.entries.items) |entry| {
            if (entry.family) |family| {
                if (std.mem.eql(u8, family, name)) {
                    if (best_priority > 1) {
                        best = entry;
                        best_priority = 1;
                    }
                    continue;
                }
            }
            if (best_priority > 2) {
                if (entry.full_name) |full_name| {
                    if (std.mem.eql(u8, full_name, name)) {
                        best = entry;
                        best_priority = 2;
                        continue;
                    }
                }
            }
            if (best_priority > 3) {
                if (entry.family) |family| {
                    if (std.mem.indexOf(u8, family, name) != null) {
                        best = entry;
                        best_priority = 3;
                    }
                }
            }
        }
        return best;
    }
};

pub fn scanSystemFonts(allocator: std.mem.Allocator, io: std.Io) !FontList {
    return scanSystemFontsWithHome(allocator, io, null);
}

pub fn scanSystemFontsWithHome(allocator: std.mem.Allocator, io: std.Io, home_dir: ?[]const u8) !FontList {
    var list: FontList = .{ .allocator = allocator };
    errdefer list.deinit();

    switch (builtin.os.tag) {
        .macos => {
            try scanFontDir(allocator, io, &list, "/System/Library/Fonts");
            try scanFontDir(allocator, io, &list, "/Library/Fonts");

            if (home_dir) |home| {
                const user_fonts = std.fs.path.join(allocator, &.{ home, "Library", "Fonts" }) catch null;
                if (user_fonts) |path| {
                    defer allocator.free(path);
                    try scanFontDir(allocator, io, &list, path);
                }
            }
        },
        .windows => {
            try scanFontDir(allocator, io, &list, "C:\\Windows\\Fonts");
        },
        else => {
            // Linux and other Unix-like systems
            try scanFontDir(allocator, io, &list, "/usr/share/fonts");
            try scanFontDir(allocator, io, &list, "/usr/local/share/fonts");

            if (home_dir) |home| {
                const user_fonts = std.fs.path.join(allocator, &.{ home, ".fonts" }) catch null;
                if (user_fonts) |path| {
                    defer allocator.free(path);
                    try scanFontDir(allocator, io, &list, path);
                }

                const user_local_fonts = std.fs.path.join(allocator, &.{ home, ".local", "share", "fonts" }) catch null;
                if (user_local_fonts) |path| {
                    defer allocator.free(path);
                    try scanFontDir(allocator, io, &list, path);
                }
            }
        },
    }

    return list;
}

fn scanFontDir(allocator: std.mem.Allocator, io: std.Io, list: *FontList, root_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, root_path, .{ .access_sub_paths = true, .iterate = true }) catch return;
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!hasFontExtension(entry.basename)) continue;

        const data = dir.readFileAlloc(io, entry.path, allocator, .limited(50 * 1024 * 1024)) catch continue;
        defer allocator.free(data);

        const full_path = std.fs.path.join(allocator, &.{ root_path, entry.path }) catch continue;
        defer allocator.free(full_path);

        if (cappan_core.font.parser.isTtcFile(data)) {
            const count = Font.countFontsInCollection(allocator, data) catch continue;
            for (0..count) |idx| {
                var font = Font.initCollectionIndex(allocator, data, @intCast(idx), null) catch continue;
                defer font.deinit();
                addFontEntry(allocator, list, full_path, &font, @intCast(idx)) catch continue;
            }
        } else {
            var font = Font.init(allocator, data, null) catch continue;
            defer font.deinit();
            addFontEntry(allocator, list, full_path, &font, 0) catch continue;
        }
    }
}

fn addFontEntry(allocator: std.mem.Allocator, list: *FontList, path: []const u8, font: *const Font, font_index: u32) !void {
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    try list.path_strings.append(allocator, path_copy);
    errdefer _ = list.path_strings.pop();

    const family = try dupeOptionalName(allocator, list, try font.getFontFamily(allocator));
    errdefer freeOptionalTrackedName(allocator, list, family);

    const subfamily = try dupeOptionalName(allocator, list, try font.getFontSubfamily(allocator));
    errdefer freeOptionalTrackedName(allocator, list, subfamily);

    const full_name = try dupeOptionalName(allocator, list, try font.getFullFontName(allocator));
    errdefer freeOptionalTrackedName(allocator, list, full_name);

    try list.entries.append(allocator, .{
        .path = path_copy,
        .family = family,
        .subfamily = subfamily,
        .full_name = full_name,
        .font_index = font_index,
    });
}

fn dupeOptionalName(allocator: std.mem.Allocator, list: *FontList, maybe_name: ?[]u8) !?[]const u8 {
    const name = maybe_name orelse return null;
    defer allocator.free(name);

    const copy = try allocator.dupe(u8, name);
    errdefer allocator.free(copy);
    try list.name_strings.append(allocator, copy);
    return copy;
}

fn freeOptionalTrackedName(allocator: std.mem.Allocator, list: *FontList, maybe_name: ?[]const u8) void {
    const name = maybe_name orelse return;
    if (list.name_strings.items.len > 0) {
        _ = list.name_strings.pop();
    }
    allocator.free(name);
}

pub fn hasFontExtension(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".ttf") or
        std.ascii.eqlIgnoreCase(ext, ".otf") or
        std.ascii.eqlIgnoreCase(ext, ".ttc") or
        std.ascii.eqlIgnoreCase(ext, ".woff") or
        std.ascii.eqlIgnoreCase(ext, ".woff2");
}
