const std = @import("std");
const ziglyph = @import("ziglyph");
const sdl3 = @cImport({
    @cInclude("SDL3/SDL.h");
    //    @cInclude("SDL3/SDL_main.h");
    @cInclude("SDL3_image/SDL_image.h");
});

const DirOpened = struct {
    path: []const u8,
    dir: std.fs.Dir,
    iter: std.fs.Dir.Iterator,
    idx_this: []const u8 = "",
};

const DirImageIndexBuilt = struct {};

const ImageLoaded = struct {
    filename: []const u8,
    texture: *sdl3.SDL_Texture,
};

const EventTag = enum {
    quit_requested,
    dir_opened,
    dir_image_index_built,
    image_loaded,
};

const Event = union(EventTag) {
    quit_requested: void,
    dir_opened: DirOpened,
    dir_image_index_built: DirImageIndexBuilt,
    image_loaded: ImageLoaded,
};

const SDL_CLOSE_IO = true;
const SDL_NO_CLOSE_IO = false;

const BYTE = 1;
const KB = 1000 * BYTE;
const MB = 1000 * KB;
const GB = 1000 * MB;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var ally = gpa.allocator();

pub fn main() !void {
    const start = std.time.nanoTimestamp();
    gfxpls_main(start) catch |err| {
        switch (err) {
            error.SDL => {
                std.debug.print("exit err = {s}\n", .{sdl3.SDL_GetError()});
            },
            else => {
                std.debug.print("exit err = {!}\n", .{err});
            },
        }
    };
    const end = std.time.nanoTimestamp();
    const runtimeNano = end - start;
    const runtimeSec = @as(f64, @floatFromInt(runtimeNano)) / 1000 / 1000 / 1000;
    std.debug.print("gfxpls ran for {d}s\n", .{runtimeSec});
}

// process here is the noun (the instance of the app) not the verb (like do_x)
fn processArgs(a: std.mem.Allocator) !std.ArrayList([]const u8) {
    var process_args = std.ArrayList([]const u8).init(a);

    std.debug.print("{?}\n", .{@TypeOf(a)});
    var arg_it = try std.process.argsWithAllocator(a);
    while (arg_it.next()) |arg| {
        try process_args.append(arg);
    }

    return process_args;
}

// caller owns the surface and needs to clean it up after use
fn loadImageSurface(target: []const u8) !*sdl3.SDL_Surface {
    const target_fh = try std.fs.openFileAbsolute(target, .{});
    const contents = try target_fh.readToEndAlloc(ally, 10 * MB);
    const contents_sdl = sdl3.SDL_IOFromConstMem(@ptrCast(contents), contents.len);
    if (contents_sdl == null) {
        return error.SDL;
    }

    const img = sdl3.IMG_Load_IO(contents_sdl, SDL_CLOSE_IO);
    if (img == null) {
        return error.SDL;
    }

    return img;
}

fn textureFromSurface(renderer: *sdl3.SDL_Renderer, surface: *sdl3.SDL_Surface) !*sdl3.SDL_Texture {
    const texture = sdl3.SDL_CreateTextureFromSurface(renderer, surface);
    if (texture == null) {
        return error.SDL;
    }

    return texture;
}

fn loadImageTextureFromFile(renderer: *sdl3.SDL_Renderer, target: []const u8) !*sdl3.SDL_Texture {
    const surface = try loadImageSurface(target);
    const texture = try textureFromSurface(renderer, surface);

    return texture;
}

const LoadFirstImageFromDirResultTag = enum {
    no_image_loaded,
    image_loaded,
};

const LoadFirstImageFromDirResult = union(LoadFirstImageFromDirResultTag) {
    no_image_loaded: void,
    image_loaded: LoadFirstImageFromDirImageLoaded,
};

const LoadFirstImageFromDirImageLoaded = struct {
    img_surface: *sdl3.SDL_Surface,
    img_file_name: []const u8,
    dir_handle: std.fs.Dir,
    dir_it: std.fs.Dir.Iterator,
};

pub fn loadFirstImageFromDir(target_path: []const u8) !LoadFirstImageFromDirResult {
    std.debug.print("target_path = {s}\n", .{target_path});

    const dd = try std.fs.openDirAbsolute(target_path, .{ .iterate = true });

    var it = dd.iterate();
    while (try it.next()) |dir_entry| {
        if (dir_entry.kind != std.fs.File.Kind.file) {
            continue;
        }
        if (dd.readFileAlloc(ally, dir_entry.name, 10 * MB)) |file_contents| {
            const contents_sdl = sdl3.SDL_IOFromConstMem(@ptrCast(file_contents), file_contents.len);
            const img_surface = sdl3.IMG_Load_IO(contents_sdl, SDL_CLOSE_IO);
            if (img_surface != null) {
                return LoadFirstImageFromDirResult{ .image_loaded = LoadFirstImageFromDirImageLoaded{
                    .img_surface = img_surface,
                    .img_file_name = try ally.dupe(u8, dir_entry.name),
                    .dir_handle = dd,
                    .dir_it = it,
                } };
            } else {
                std.debug.print("NOT AN IMAGE {s}\n", .{dir_entry.name});
            }
        } else |err| {
            std.debug.print("^err = {?}\n", .{err});
            continue;
        }
    }
    return LoadFirstImageFromDirResult{ .no_image_loaded = undefined };
}

const supported_image_formats = [_](*const fn (*sdl3.SDL_IOStream) callconv(.C) bool){
    sdl3.IMG_isAVIF,
    sdl3.IMG_isCUR,
    sdl3.IMG_isICO,
    sdl3.IMG_isBMP,
    sdl3.IMG_isGIF,
    sdl3.IMG_isJPG,
    sdl3.IMG_isJXL,
    sdl3.IMG_isLBM,
    sdl3.IMG_isPCX,
    sdl3.IMG_isPNG,
    sdl3.IMG_isPNM,
    sdl3.IMG_isSVG,
    sdl3.IMG_isTIF,
    sdl3.IMG_isXCF,
    sdl3.IMG_isXPM,
    sdl3.IMG_isXV,
    sdl3.IMG_isWEBP,
    sdl3.IMG_isQOI,
};

pub fn canLoadImage(src: []const u8) bool {
    if (sdl3.SDL_IOFromFile(@ptrCast(src), "rb")) |iostream| {
        for (supported_image_formats) |is_supported_image| {
            if (is_supported_image(iostream)) {
                return true;
            }
        }
    }

    return false;
}

pub fn buildImageIndex(
    dir_path: []const u8,
    dir_iter: std.fs.Dir.Iterator,
    image_index: *std.ArrayList([]const u8),
    done_event: *std.Thread.ResetEvent,
) !void {
    var casted_iter = @as(std.fs.Dir.Iterator, dir_iter);
    while (try casted_iter.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.file) {
            continue;
        }
        const entry_name = try ally.dupe(u8, entry.name);
        const target = try std.fs.path.joinZ(ally, &[_][]const u8{ dir_path, entry_name });
        if (canLoadImage(@ptrCast(target))) {
            try image_index.*.append(entry_name);
        }
    }
    done_event.set();
}

pub fn showImageTexture(renderer: *sdl3.SDL_Renderer, tex: *sdl3.SDL_Texture) !void {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl3.SDL_GetCurrentRenderOutputSize(renderer, &w, &h);
    //    std.debug.print("rendering w,h = {}, {}\n", .{ w, h });
    //    std.debug.print("tex w,h = {}, {}\n", .{ tex.w, tex.h });
    if ((tex.w > w) or (tex.h > h)) {
        const wf = @as(f32, @floatFromInt(w));
        const hf = @as(f32, @floatFromInt(h));
        const tex_w = @as(f32, @floatFromInt(tex.w));
        const tex_h = @as(f32, @floatFromInt(tex.h));
        const w_ratio = tex_w / wf;
        const h_ratio = tex_h / hf;

        var ratio = w_ratio;
        if (ratio < h_ratio) {
            ratio = h_ratio;
        }

        const target_w = tex_w * 1 / ratio;
        const target_h = tex_h * 1 / ratio;

        const dst_x = (wf - target_w) / 2.0;
        const dst_y = (hf - target_h) / 2.0;

        const dst_rect = sdl3.SDL_FRect{
            .x = dst_x,
            .y = dst_y,
            .w = target_w,
            .h = target_h,
        };

        _ = sdl3.SDL_RenderTexture(renderer, tex, null, &dst_rect);
        //std.debug.print("render(scaled) result = {}\n", .{rr});
    } else {
        const wf = @as(f32, @floatFromInt(w));
        const hf = @as(f32, @floatFromInt(h));
        const tex_w = @as(f32, @floatFromInt(tex.w));
        const tex_h = @as(f32, @floatFromInt(tex.h));
        const dst_x = (wf - tex_w) / 2.0;
        const dst_y = (hf - tex_h) / 2.0;
        const dst_rect = sdl3.SDL_FRect{
            .x = dst_x,
            .y = dst_y,
            .w = tex_w,
            .h = tex_h,
        };

        _ = sdl3.SDL_RenderTexture(renderer, tex, null, &dst_rect);
        //std.debug.print("render result = {}\n", .{rr});
    }
}

const EventList = std.ArrayList(Event);

const CurrentImage = struct {
    filename: []const u8 = "",
    texture: *sdl3.SDL_Texture,
};

const Command = enum {
    next_image,
    prev_image,
    first_image,
    last_image,
    quit,
    toggle_fullscreen,
    clipboard_copy,
    clipboard_paste,
};

const MainContext = struct {
    a: std.mem.Allocator,
    window: *sdl3.SDL_Window,
    renderer: *sdl3.SDL_Renderer,
    frames: u64 = 0,
    current_image: CurrentImage,
    current_image_idx: usize = 0,
    image_load_buffer: []u8,
    image_index_ready: bool = false,
    image_index: std.ArrayList([]const u8),
    image_index_dir: ?std.fs.Dir = null,
    image_index_iter: ?std.fs.Dir.Iterator = null,
    image_index_wip: std.ArrayList([]const u8),
    wip_completed: std.Thread.ResetEvent,
    fullscreen: bool = true,

    keybinds: std.hash_map.AutoHashMap(u32, Command),

    const Self = @This();

    const LoopResult = struct {
        events: EventList,
        quit: bool = false,
    };

    fn init(
        a: std.mem.Allocator,
        window: *sdl3.SDL_Window,
        renderer: *sdl3.SDL_Renderer,
        max_image_size: usize,
    ) !MainContext {
        const image_load_buffer = try a.alignedAlloc(u8, @alignOf(u8), max_image_size);
        var keybinds = std.hash_map.AutoHashMap(u32, Command).init(a);
        try keybinds.put(sdl3.SDLK_ESCAPE, Command.quit);
        try keybinds.put(sdl3.SDLK_RIGHT, Command.next_image);
        try keybinds.put(sdl3.SDLK_PAGEDOWN, Command.next_image);
        try keybinds.put(sdl3.SDLK_LEFT, Command.prev_image);
        try keybinds.put(sdl3.SDLK_PAGEUP, Command.prev_image);
        try keybinds.put(sdl3.SDLK_HOME, Command.first_image);
        try keybinds.put(sdl3.SDLK_END, Command.last_image);
        try keybinds.put(sdl3.SDLK_F11, Command.toggle_fullscreen);
        try keybinds.put(sdl3.SDLK_V, Command.clipboard_paste);

        return MainContext{
            .a = a,
            .window = window,
            .renderer = renderer,
            .image_index = std.ArrayList([]const u8).init(a),
            .image_index_wip = std.ArrayList([]const u8).init(a),
            .wip_completed = std.Thread.ResetEvent{},
            .current_image = CurrentImage{ .filename = "", .texture = undefined },
            .image_load_buffer = image_load_buffer,
            .keybinds = keybinds,
        };
    }

    fn handleImageLoaded(self: *Self, ev: ImageLoaded) void {
        sdl3.SDL_DestroyTexture(self.current_image.texture);
        self.current_image = CurrentImage{
            .filename = ev.filename,
            .texture = ev.texture,
        };
        try showImageTexture(self.renderer, ev.texture);
    }

    fn handleDirOpened(self: *Self, ev: DirOpened) !void {
        self.image_index_dir = ev.dir;
        self.image_index_iter = ev.iter;

        const thread = try std.Thread.spawn(.{}, buildImageIndex, .{ ev.path, self.image_index_iter.?, &self.image_index_wip, &self.wip_completed });
        thread.detach();
    }

    fn handleDirImageIndexBuilt(self: *Self) !void {
        var c = try ziglyph.Collator.init(self.a);
        defer c.deinit();

        self.image_index.deinit();
        self.image_index = self.image_index_wip;
        self.image_index_wip = std.ArrayList([]const u8).init(self.a);

        std.mem.sort([]const u8, self.image_index.items, c, ziglyph.Collator.ascending);
        for (self.image_index.items, 0..) |iname, idx| {
            std.debug.print("idx {d} = {s}\n", .{ idx, iname });
            if (std.mem.eql(u8, iname, self.current_image.filename)) {
                self.current_image_idx = idx;
            }
        }

        self.image_index_ready = true;
    }

    fn handleKeyDown(self: *Self, ev: sdl3.SDL_KeyboardEvent, new_events: *std.ArrayList(Event)) !void {
        if (self.keybinds.get(ev.key)) |command| {
            try self.dispatchCommand(command, new_events);
        }
    }

    fn dispatchCommand(self: *Self, cmd: Command, new_events: *std.ArrayList(Event)) !void {
        switch (cmd) {
            Command.quit => {
                try new_events.append(Event{ .quit_requested = undefined });
            },
            Command.next_image => {
                if (self.loadImageAfter(self.current_image.filename)) |lev| {
                    try new_events.*.append(lev);
                } else |_| {}
            },
            Command.prev_image => {
                if (self.loadImageBefore(self.current_image.filename)) |lev| {
                    try new_events.*.append(lev);
                } else |_| {}
            },
            Command.first_image => {
                if (self.loadFirstImage()) |lev| {
                    try new_events.*.append(lev);
                } else |_| {}
            },
            Command.last_image => {
                if (self.loadLastImage()) |lev| {
                    try new_events.*.append(lev);
                } else |_| {}
            },
            Command.toggle_fullscreen => {
                _ = sdl3.SDL_SetWindowFullscreen(self.window, !self.fullscreen);
            },
            Command.clipboard_paste => {
                var num_available_mime_types: usize = 0;
                const clipboard_available_mime_types = sdl3.SDL_GetClipboardMimeTypes(&num_available_mime_types);
                if (clipboard_available_mime_types == null) {
                    std.debug.print("CLIPBOARD FAILURE = {s}\n", .{sdl3.SDL_GetError()});
                }
                std.debug.print("Number of available mime types = {d}\n", .{num_available_mime_types});
                for (0..num_available_mime_types) |idx| {
                    std.debug.print("available mime type#{d} = {s}\n", .{ idx, clipboard_available_mime_types[idx] });
                }
                std.debug.print("mime types = {*}\n", .{clipboard_available_mime_types});
            },
            else => {},
        }
    }

    fn loop(self: *Self, events: *std.ArrayListAligned(Event, null)) !LoopResult {
        var quit = false;
        var new_events = std.ArrayList(Event).init(self.a);

        while (events.popOrNull()) |event| {
            switch (event) {
                .image_loaded => {
                    //                    _ = sdl3.SDL_RenderClear(self.renderer);
                    self.handleImageLoaded(event.image_loaded);
                    //                    if (sdl3.SDL_RenderPresent(self.renderer) == false) return error.SDL;
                },
                .dir_opened => {
                    try self.handleDirOpened(event.dir_opened);
                    //if (event.dir_opened.idx_this.len > 0) {
                    //    try self.image_index.append(event.dir_opened.idx_this);
                    //}
                },
                .dir_image_index_built => {
                    try self.handleDirImageIndexBuilt();
                },
                .quit_requested => {
                    quit = true;
                },
            }
        }

        const red = 0;
        const green = 0;
        const blue = 0;
        const alpha = 0;

        _ = sdl3.SDL_SetRenderDrawColor(self.renderer, red, green, blue, alpha);
        _ = sdl3.SDL_RenderClear(self.renderer);

        if (self.wip_completed.isSet()) {
            self.wip_completed.reset();
            try new_events.append(Event{ .dir_image_index_built = DirImageIndexBuilt{} });
        }

        //    _ = sdl3.SDL_SetRenderDrawColor(self.renderer, 0, 255, 0, 255);
        //    _ = sdl3.SDL_RenderDebugText(self.renderer, 10, 10, "Building image index...");

        try showImageTexture(self.renderer, self.current_image.texture);
        _ = sdl3.SDL_RenderPresent(self.renderer);

        var e: sdl3.SDL_Event = undefined;
        while (sdl3.SDL_PollEvent(&e)) {
            switch (e.type) {
                sdl3.SDL_EVENT_QUIT => {
                    try new_events.append(Event{ .quit_requested = undefined });
                },
                sdl3.SDL_EVENT_KEY_DOWN => {
                    try self.handleKeyDown(e.key, &new_events);
                },
                sdl3.SDL_EVENT_WINDOW_RESIZED => {
                    const wev = e.window;
                    std.debug.print("RESIZE = {} {} {} {}\n", .{ wev.type, wev.windowID, wev.data1, wev.data2 });

                    const rcr = sdl3.SDL_RenderClear(self.renderer);
                    std.debug.print("Render Clear Result = {}\n", .{rcr});
                    try showImageTexture(self.renderer, self.current_image.texture);
                    const rpr = sdl3.SDL_RenderPresent(self.renderer);
                    std.debug.print("Render Present Result = {}\n", .{rpr});
                },
                sdl3.SDL_EVENT_WINDOW_ENTER_FULLSCREEN => {
                    self.fullscreen = true;
                },
                sdl3.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN => {
                    self.fullscreen = false;
                },
                //                sdl3.SDL_EVENT_CLIPBOARD_UPDATE => {
                //                    const cbev = e.clipboard;
                //                    const n: usize = @intCast(cbev.n_mime_types);
                //                    std.debug.print("number of mime types = {d}\n", .{cbev.n_mime_types});
                //                    for (0..n) |mime_idx| {
                //                        std.debug.print("available mime type #{d} = {s}\n", .{ mime_idx, cbev.mime_types[mime_idx] });
                //                    }
                //                },
                else => {},
            }
        }

        self.frames += 1;

        return LoopResult{
            .events = new_events,
            .quit = quit,
        };
    }

    fn loadFirstImage(self: *Self) !Event {
        if (self.image_index_ready == false) {
            return error.IMAGE_INDEX_NOT_READY;
        }

        if (self.image_index.items.len == 0) {
            return error.IMAGE_INDEX_EMPTY;
        }

        const idx = 0;
        //std.sort.binarySearch([]const u8, name, self.image_index.items, name, ziglyph.Collator.ascending);

        const indexed_name = self.image_index.items[idx];
        std.debug.print("-- (first) want to load {d} {s}\n", .{ idx, indexed_name });

        if (self.image_index_dir) |iid| {
            if (iid.readFile(indexed_name, self.image_load_buffer)) |file_contents| {
                const contents_io = sdl3.SDL_IOFromConstMem(@ptrCast(file_contents), file_contents.len);
                const img_surface = sdl3.IMG_Load_IO(contents_io, SDL_CLOSE_IO);
                if (img_surface != null) {
                    const texture = try textureFromSurface(self.renderer, img_surface);
                    sdl3.SDL_DestroySurface(img_surface);
                    self.current_image_idx = idx;
                    return Event{ .image_loaded = ImageLoaded{ .filename = indexed_name, .texture = texture } };
                }
            } else |_| {}
        }

        return error.AWWELL;
    }

    fn loadLastImage(self: *Self) !Event {
        if (self.image_index_ready == false) {
            return error.IMAGE_INDEX_NOT_READY;
        }

        if (self.image_index.items.len == 0) {
            return error.IMAGE_INDEX_EMPTY;
        }

        const idx = self.image_index.items.len - 1;
        //std.sort.binarySearch([]const u8, name, self.image_index.items, name, ziglyph.Collator.ascending);

        const indexed_name = self.image_index.items[idx];
        std.debug.print("-- (last) want to load {d} {s}\n", .{ idx, indexed_name });

        if (self.image_index_dir) |iid| {
            if (iid.readFile(indexed_name, self.image_load_buffer)) |file_contents| {
                const contents_io = sdl3.SDL_IOFromConstMem(@ptrCast(file_contents), file_contents.len);
                const img_surface = sdl3.IMG_Load_IO(contents_io, SDL_CLOSE_IO);
                if (img_surface != null) {
                    const texture = try textureFromSurface(self.renderer, img_surface);
                    sdl3.SDL_DestroySurface(img_surface);
                    self.current_image_idx = idx;
                    return Event{ .image_loaded = ImageLoaded{ .filename = indexed_name, .texture = texture } };
                }
            } else |_| {}
        }

        return error.AWWELL;
    }

    fn loadImageBefore(self: *Self, name: []const u8) !Event {
        if (self.image_index_ready == false) {
            return error.IMAGE_INDEX_NOT_READY;
        }

        if (self.image_index.items.len == 0) {
            return error.IMAGE_INDEX_EMPTY;
        }

        _ = name;
        const idx = self.current_image_idx;
        //std.sort.binarySearch([]const u8, name, self.image_index.items, name, ziglyph.Collator.ascending);

        if (idx > 0) {
            const indexed_name = self.image_index.items[idx - 1];
            std.debug.print("-- (before) want to load {d} {s}\n", .{ idx - 1, indexed_name });

            if (self.image_index_dir) |iid| {
                if (iid.readFile(indexed_name, self.image_load_buffer)) |file_contents| {
                    const contents_io = sdl3.SDL_IOFromConstMem(@ptrCast(file_contents), file_contents.len);
                    const img_surface = sdl3.IMG_Load_IO(contents_io, SDL_CLOSE_IO);
                    if (img_surface != null) {
                        const texture = try textureFromSurface(self.renderer, img_surface);
                        sdl3.SDL_DestroySurface(img_surface);
                        self.current_image_idx = idx - 1;
                        return Event{ .image_loaded = ImageLoaded{ .filename = indexed_name, .texture = texture } };
                    }
                } else |_| {}
            }
        }

        return error.AWWELL;
    }

    fn loadImageAfter(self: *Self, name: []const u8) !Event {
        if (self.image_index_ready == false) {
            return error.IMAGE_INDEX_NOT_READY;
        }

        if (self.image_index.items.len == 0) {
            return error.IMAGE_INDEX_EMPTY;
        }

        _ = name;
        const idx = self.current_image_idx;

        if (idx < self.image_index.items.len - 1) {
            const indexed_name = self.image_index.items[idx + 1];
            std.debug.print("-- (after) want to load {d} {s}\n", .{ idx + 1, indexed_name });

            if (self.image_index_dir) |iid| {
                if (iid.readFile(indexed_name, self.image_load_buffer)) |file_contents| {
                    const contents_io = sdl3.SDL_IOFromConstMem(@ptrCast(file_contents), file_contents.len);
                    const img_surface = sdl3.IMG_Load_IO(contents_io, SDL_CLOSE_IO);
                    if (img_surface != null) {
                        const texture = try textureFromSurface(self.renderer, img_surface);
                        sdl3.SDL_DestroySurface(img_surface);
                        self.current_image_idx = idx + 1;
                        return Event{ .image_loaded = ImageLoaded{ .filename = indexed_name, .texture = texture } };
                    }
                } else |_| {}
            }
        }

        return error.AWWELL;
    }
};

pub fn gfxpls_main(start: @TypeOf(std.time.nanoTimestamp())) !void {
    const process_args = try processArgs(ally);
    const starting_wd_path = try std.fs.cwd().realpathAlloc(ally, ".");

    var target: []const u8 = starting_wd_path;
    if (process_args.items.len == 2) {
        // working with user input, so this could be absolutely anything
        const user_provided_path = process_args.items[1];
        if (std.fs.path.isAbsolute(user_provided_path)) {
            target = user_provided_path;
        } else {
            target = try std.fs.path.join(ally, &[_][]const u8{ starting_wd_path, user_provided_path });
        }
    }

    if (sdl3.SDL_Init(sdl3.SDL_INIT_VIDEO) == false) {
        return error.SDL;
    }

    var num_displays: c_int = 0;
    const displays: [*c]sdl3.SDL_DisplayID = sdl3.SDL_GetDisplays(&num_displays);
    if (num_displays < 1) {
        return error.SDL;
    }

    var window_w: c_int = 1920;
    var window_h: c_int = 1080;
    const display_mode = sdl3.SDL_GetDesktopDisplayMode(@as(sdl3.SDL_DisplayID, displays[0]));
    if (display_mode) |dm| {
        const dmo = dm.*;
        std.debug.print("display mode = {}, {}, {}, {} {}\n", .{ dmo.w, dmo.h, dmo.pixel_density, dmo.refresh_rate, dmo.format });
        window_w = dmo.w;
        window_h = dmo.h;
    } else {
        std.debug.print("sdl err = {s}\n", .{sdl3.SDL_GetError()});
    }
    const window_title = "gfxpls";
    const window_flags =

        //sdl3.SDL_WINDOW_TRANSPARENT |
        sdl3.SDL_WINDOW_BORDERLESS |
        sdl3.SDL_WINDOW_FULLSCREEN |
        //sdl3.SDL_WINDOW_HIGH_PIXEL_DENSITY |
        sdl3.SDL_WINDOW_INPUT_FOCUS |
        sdl3.SDL_WINDOW_RESIZABLE;

    var window: ?*sdl3.SDL_Window = undefined;
    var renderer: ?*sdl3.SDL_Renderer = undefined;

    if (!sdl3.SDL_CreateWindowAndRenderer(
        window_title,
        window_w,
        window_h,
        window_flags,
        &window,
        &renderer,
    )) {
        return error.SDL;
    }

    // SDL_GetDisplayForWindow
    //
    //const stdout_file = std.io.getStdOut().writer();
    //var bw = std.io.bufferedWriter(stdout_file);
    //const stdout = bw.writer();

    var events = std.ArrayList(Event).init(ally);
    defer events.deinit();

    if (window) |w| {
        if (renderer) |r| {
            std.debug.print("renderer = {}\n", .{r});

            std.debug.print(">> DisplayContentScale={}\n", .{sdl3.SDL_GetDisplayContentScale(1)});
            std.debug.print(">> WindowDisplayScale={}\n", .{sdl3.SDL_GetWindowDisplayScale(w)});
            if (loadImageTextureFromFile(r, target)) |tex| {
                const filename = std.fs.path.basename(target);
                try events.append(Event{ .image_loaded = ImageLoaded{
                    .filename = filename,
                    .texture = tex,
                } });

                if (std.fs.path.dirname(target)) |dir_path| {
                    const dh = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
                    try events.append(Event{ .dir_opened = DirOpened{
                        .path = target,
                        .dir = dh,
                        .iter = dh.iterate(),
                        .idx_this = "",
                    } });
                } else {
                    std.debug.print("How can we have a loaded image but not get the dir?\n", .{});
                }
            } else |err| {
                switch (err) {
                    error.IsDir, error.SDL => {
                        const load_first_result = try loadFirstImageFromDir(target);
                        switch (load_first_result) {
                            .image_loaded => {
                                const image_loaded_result = load_first_result.image_loaded;
                                const tex = try textureFromSurface(r, image_loaded_result.img_surface);
                                try events.append(Event{ .image_loaded = ImageLoaded{ .filename = image_loaded_result.img_file_name, .texture = tex } });
                                try events.append(Event{ .dir_opened = DirOpened{
                                    .path = target,
                                    .dir = image_loaded_result.dir_handle,
                                    .iter = image_loaded_result.dir_it,
                                    .idx_this = try ally.dupe(u8, image_loaded_result.img_file_name),
                                } });
                            },
                            .no_image_loaded => {},
                        }
                    },
                    else => {
                        return err;
                    },
                }
            }

            const render_at = std.time.nanoTimestamp();
            std.debug.print("First render at {d}\n", .{render_at - start});

            var main_context = try MainContext.init(ally, w, r, 20 * MB);

            var quit = false;
            while (!quit) {
                const loop_result = try main_context.loop(&events);
                quit = loop_result.quit;
                events.deinit();
                events = loop_result.events;
            }
        }
    }
}
