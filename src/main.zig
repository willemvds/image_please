const std = @import("std");

const sdl3 = @cImport({
    @cInclude("SDL3/SDL.h");
    //    @cInclude("SDL3/SDL_main.h");
    @cInclude("SDL3_image/SDL_image.h");
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var ally = gpa.allocator();

const stdoutXX = std.io.GetStdOut().writer();

pub fn main() !void {
    const start = std.time.nanoTimestamp();
    gfxpls_main(start) catch |err| {
        std.debug.print("{!}\n", .{err});
    };
    const end = std.time.nanoTimestamp();
    const runtimeNano = end - start;
    const runtimeSec = @as(f64, @floatFromInt(runtimeNano)) / 1000 / 1000 / 1000;
    std.debug.print("gfxpls ran for {d}s\n", .{runtimeSec});
}

pub fn gfxpls_main(start: @TypeOf(std.time.nanoTimestamp())) !void {
    //    const start = std.time.nanoTimestamp();

    std.debug.print("STARTED AT = {?}\n", .{start});

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var dirlist = std.ArrayList([]const u8).init(ally);
    defer dirlist.deinit();

    try stdout.print("TYPE OF DIRLIST = {?}", .{dirlist});
    try bw.flush();

    const dd = try std.fs.openDirAbsolute("/home/willem/projects/gfxpls", .{ .iterate = true });

    var it = dd.iterate();
    while (try it.next()) |item| {
        try stdout.print("Dir Entry: kind={?} name={s}\n", .{ item.kind, item.name });
        try dirlist.append(item.name);
    }

    if (sdl3.SDL_Init(sdl3.SDL_INIT_VIDEO) == false) {
        try stdout.print("sdl init failed\n", .{});
        try bw.flush();

        const sdlErr = sdl3.SDL_GetError();
        try stdout.print("sdl err = {s}", .{sdlErr});
        try bw.flush();
        return;
    }

    const window = sdl3.SDL_CreateWindow(
        "ZIGGY",
        800,
        600,
        sdl3.SDL_WINDOW_VULKAN,
    );

    if (window == null) {
        try stdout.print("window {?}\n", .{window});

        try stdout.print("sdl err = {s}\n", .{sdl3.SDL_GetError()});

        try bw.flush();

        return;
    }

    const img = sdl3.IMG_Load("/home/willem/projects/gfxpls/dothackslash.png");
    try stdout.print("img result = {*}, err = {s}\n", .{ img, sdl3.SDL_GetError() });
    try bw.flush();

    const surface = sdl3.SDL_GetWindowSurface(window);
    _ = sdl3.SDL_BlitSurface(img, null, surface, null);
    _ = sdl3.SDL_UpdateWindowSurface(window);

    var quit = false;

    while (!quit) {
        var e: sdl3.SDL_Event = undefined;
        while (sdl3.SDL_PollEvent(&e)) {
            if (e.type == sdl3.SDL_EVENT_QUIT) {
                quit = true;
            } else if (e.type == sdl3.SDL_EVENT_KEY_UP) {
                try stdout.print("key event = {?}\n", .{e});
                if (e.key.key == sdl3.SDLK_ESCAPE) {
                    quit = true;
                } else if (e.key.key == sdl3.SDLK_PAGEDOWN) {
                    for (dirlist.items) |entry| {
                        try stdout.print("D -> {s}\n", .{entry});
                    }
                }
            }
            try bw.flush();
        }
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
