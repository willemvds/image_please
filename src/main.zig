const std = @import("std");

const sdl3 = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_image/SDL_image.h");
});

const gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const iter = try std.fs.cwd().openIterableDir(".", .{});
    var it = iter.iterate();
    while (try it.next()) |item| {
        try stdout.print("Dir Entry: kind={?} name={s}\n", .{ item.kind, item.name });
    }

    if (sdl3.SDL_Init(sdl3.SDL_INIT_VIDEO) != 0) {
        try stdout.print("sdl init failed\n", .{});
        return;
    }

    var window = sdl3.SDL_CreateWindow(
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

    var img = sdl3.IMG_Load("/home/willem/projects/gfxpls/dothackslash.png");
    try stdout.print("img result = {*}, err = {s}\n", .{ img, sdl3.SDL_GetError() });
    try bw.flush();

    var surface = sdl3.SDL_GetWindowSurface(window);
    _ = sdl3.SDL_BlitSurface(img, null, surface, null);
    _ = sdl3.SDL_UpdateWindowSurface(window);

    var quit = false;
    var e: sdl3.SDL_Event = undefined;

    while (!quit) {
        while (sdl3.SDL_PollEvent(&e) != 0) {
            if (e.type == sdl3.SDL_EVENT_QUIT) {
                quit = true;
            }
        }
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
