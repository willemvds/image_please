const std = @import("std");

const ReadFileWorker = @import("ReadFileWorker.zig");

//const ziglyph = @import("ziglyph");
const sdl3 = @cImport({
    @cInclude("SDL3/SDL.h");
    //    @cInclude("SDL3/SDL_main.h");
    @cInclude("SDL3_image/SDL_image.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

const EventTag = enum {
    quit_requested,
};

const Event = union(EventTag) {
    quit_requested: void,
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
    var arg_it = try std.process.argsWithAllocator(a);
    while (arg_it.next()) |arg| {
        try process_args.append(arg);
    }

    return process_args;
}

// caller owns the surface and needs to clean it up after use
fn textureFromSurface(renderer: *sdl3.SDL_Renderer, surface: *sdl3.SDL_Surface) !*sdl3.SDL_Texture {
    const texture = sdl3.SDL_CreateTextureFromSurface(renderer, surface);
    if (texture == null) {
        return error.SDL;
    }

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

const ParseImageResultTag = enum {
    ok,
    err,
};

const ParseImageResult = union(ParseImageResultTag) {
    ok: *sdl3.SDL_Surface,
    err: anyerror,

    fn init(a: std.mem.Allocator) !*ParseImageResult {
        const r = try a.create(ParseImageResult);
        return r;
    }
};

pub fn parseImage(
    filename: []const u8,
    content: []const u8,
    result: *ParseImageResult,
    done_event: *std.Thread.ResetEvent,
) void {
    const content_io = sdl3.SDL_IOFromConstMem(@ptrCast(content), content.len);
    const img_surface = sdl3.IMG_Load_IO(content_io, SDL_CLOSE_IO);
    ally.free(content);
    if (img_surface != null) {
        result.* = ParseImageResult{ .ok = img_surface };
    } else {
        // TODO: Return the error string since we can't call SDL_GetError on a different thread
        std.debug.print("image load FAILED {s}={s}\n", .{ filename, sdl3.SDL_GetError() });
        result.* = ParseImageResult{ .err = error.sdl_temp };
    }
    done_event.set();
}

const ImageCache = struct {
    a: std.mem.Allocator,
    textures: std.StringHashMap(*sdl3.SDL_Texture),

    const Self = @This();

    fn init(
        a: std.mem.Allocator,
    ) ImageCache {
        const textures = std.StringHashMap(*sdl3.SDL_Texture).init(a);
        return ImageCache{
            .a = a,
            .textures = textures,
        };
    }

    fn put(self: *Self, path: []const u8, texture: *sdl3.SDL_Texture) !void {
        try self.textures.put(path, texture);
    }

    fn get(self: *Self, path: []const u8) ?*sdl3.SDL_Texture {
        return self.textures.get(path);
    }

    fn contains(self: *Self, path: []const u8) bool {
        return self.textures.contains(path);
    }
};

pub fn buildImageIndex(
    dir_path: []const u8,
    //    dir_iter: std.fs.Dir.Iterator,
    image_index: *std.ArrayList([]const u8),
    done_event: *std.Thread.ResetEvent,
    queue_load_first: bool,
    read_file_worker: *ReadFileWorker,
) !void {
    const started_at = try std.time.Instant.now();

    const dir_with_iter = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    var iter = dir_with_iter.iterate();

    var load_first_queued = false;
    while (try iter.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.file) {
            continue;
        }
        const target = try std.fs.path.joinZ(ally, &[_][]const u8{ dir_path, entry.name });
        defer ally.free(target);
        if (canLoadImage(target)) {
            const entry_name = try ally.dupe(u8, entry.name);
            try image_index.*.append(entry_name);
            if (queue_load_first and !load_first_queued) {
                try read_file_worker.queue(entry_name);
                load_first_queued = true;
            }
        }
    }
    const completed_at = try std.time.Instant.now();
    done_event.set();
    std.debug.print("buildImageIndex #images={d} ns={d}\n", .{ image_index.items.len, completed_at.since(started_at) });
}

pub fn showImageTexture(renderer: *sdl3.SDL_Renderer, tex: *sdl3.SDL_Texture) !void {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl3.SDL_GetCurrentRenderOutputSize(renderer, &w, &h);
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
    }
}

const EventList = std.ArrayList(Event);

const CurrentImage = struct {
    filename: []const u8 = "",
    texture: *sdl3.SDL_Texture,
};

const Command = enum {
    none,
    next_image,
    prev_image,
    first_image,
    last_image,
    quit,
    toggle_fullscreen,
    clipboard_copy,
    clipboard_paste,
};

var parse_image_worker_pool: std.Thread.Pool = undefined;
var image_index_work_completed_event: std.Thread.ResetEvent = std.Thread.ResetEvent{};
var starting_image_index: std.ArrayList([]const u8) = undefined;

const ViewChunk = struct {
    texture: *sdl3.SDL_Texture,
    dst_rect: sdl3.SDL_FRect,
};

const PendingImageTask = struct {
    filename: []const u8,
    completed_event: *std.Thread.ResetEvent,
    result: *ParseImageResult,
};

const MainContext = struct {
    a: std.mem.Allocator,
    window: *sdl3.SDL_Window,
    renderer: *sdl3.SDL_Renderer,
    frames: u64 = 0,
    current_image: CurrentImage,
    current_image_idx: usize = 0,
    current_image_index_slot: usize = 0,
    pending_image_index: usize = 0,
    pending_image_index_slot: usize = 0,

    pending_image_tasks: std.ArrayList(PendingImageTask),

    read_file_worker: *ReadFileWorker,

    image_load_buffer: []u8,
    image_index_ready: bool = false,
    image_index: std.ArrayList([]const u8),
    image_index_dir: ?std.fs.Dir = null,
    image_index_iter: ?std.fs.Dir.Iterator = null,
    image_index_wip: std.ArrayList([]const u8),
    image_cache: ImageCache,
    wanted_image_path: []const u8 = "",
    wip_completed: *std.Thread.ResetEvent,
    fullscreen: bool = true,
    command_in_progress: Command = Command.none,
    preload_index: usize = 0,

    showing_image_texture: ?*sdl3.SDL_Texture,

    //    load_image_worker: *LoadImageWorker,
    next_worker_task: []const u8 = "",

    keybinds: std.hash_map.AutoHashMap(u32, Command),
    show_image: bool = false,
    view_mode: ViewMode = ViewMode.init(),

    labels: std.ArrayList(ViewChunk),
    view_changed: bool = false,

    const Self = @This();

    const ViewModeTag = enum {
        waiting_for_image,
        showing_image,
        showing_error,
    };
    const ViewMode = union(ViewModeTag) {
        waiting_for_image: usize,
        showing_image: usize,
        showing_error: anyerror,

        fn init() ViewMode {
            return ViewMode{ .showing_error = error.Empty };
        }
    };

    const NamelessResult = enum {
        done,
        queued,
        worker_busy,
    };

    const LoopResult = struct {
        events: EventList,
        quit: bool = false,
    };

    fn init(
        a: std.mem.Allocator,
        window: *sdl3.SDL_Window,
        renderer: *sdl3.SDL_Renderer,
        read_file_worker: *ReadFileWorker,
        max_image_size: usize,
        image_index_completed_event: *std.Thread.ResetEvent,
        image_index_wip: std.ArrayList([]const u8),
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

        const n_parse_threads = std.Thread.getCpuCount() catch 2;
        try parse_image_worker_pool.init(.{
            .allocator = std.heap.page_allocator,
            .n_jobs = n_parse_threads,
        });
        std.debug.print("number of parse threads = {d}\n", .{n_parse_threads});

        return MainContext{
            .a = a,
            .window = window,
            .renderer = renderer,
            .image_index = std.ArrayList([]const u8).init(a),
            .image_index_wip = image_index_wip,
            .image_cache = ImageCache.init(a),
            .wip_completed = image_index_completed_event,
            .current_image = CurrentImage{ .filename = "", .texture = undefined },
            .showing_image_texture = null,
            .image_load_buffer = image_load_buffer,
            .read_file_worker = read_file_worker,
            .keybinds = keybinds,
            .show_image = false,
            .labels = std.ArrayList(ViewChunk).init(a),
            .pending_image_tasks = std.ArrayList(PendingImageTask).init(a),
            //            .parse_image_worker_pool = parse_image_worker_pool,
        };
    }

    fn handleKeyDown(self: *Self, ev: sdl3.SDL_KeyboardEvent, new_events: *std.ArrayList(Event)) !void {
        if (self.keybinds.get(ev.key)) |command| {
            if (self.dispatchCommand(command, new_events)) |_| {} else |_| {
                //                std.debug.print("dispatch command={any}, err={?}\n", .{command, err});
            }
        }
    }

    fn dispatchCommand(self: *Self, cmd: Command, new_events: *std.ArrayList(Event)) !void {
        switch (cmd) {
            Command.quit => {
                try new_events.append(Event{ .quit_requested = undefined });
            },
            Command.next_image => {
                try self.nextImage();
            },
            Command.prev_image => {
                try self.prevImage();
            },
            Command.first_image => {
                try self.firstImage();
            },
            Command.last_image => {
                try self.lastImage();
            },
            Command.toggle_fullscreen => {
                _ = sdl3.SDL_SetWindowFullscreen(self.window, !self.fullscreen);
            },
            else => {},
        }
    }

    fn handleParseImageWorker(self: *Self) !void {
        for (self.pending_image_tasks.items, 0..) |_, idx| {
            if (self.pending_image_tasks.items[idx].completed_event.isSet()) {
                const task = self.pending_image_tasks.items[idx];
                self.pending_image_tasks.items[idx].completed_event.reset();
                self.view_mode = ViewMode{ .showing_image = 0 };
                self.view_changed = true;
                self.showing_image_texture = sdl3.SDL_CreateTextureFromSurface(self.renderer, self.pending_image_tasks.items[idx].result.ok);

                sdl3.SDL_DestroySurface(self.pending_image_tasks.items[idx].result.ok);
                try self.image_cache.put(task.filename, self.showing_image_texture.?);
            }
        }
    }

    fn handleReadFileWorker(self: *Self) !void {
        if (self.read_file_worker.last_result()) |result| {
            if (result.kind == ReadFileWorker.Result.Kind.ok) {
                const re = try self.a.create(std.Thread.ResetEvent);
                const task = PendingImageTask{
                    .filename = result.filename,
                    .completed_event = re,
                    .result = try ParseImageResult.init(self.a),
                };
                try parse_image_worker_pool.spawn(parseImage, .{
                    result.filename,
                    result.content,
                    task.result,
                    task.completed_event,
                });
                try self.pending_image_tasks.append(task);
            }
            if (self.next_worker_task.len > 0) {
                try self.read_file_worker.queue(self.next_worker_task);
                self.next_worker_task = "";
            }
        } else |_| {}
    }

    fn handleImageIndexWorker(self: *Self) void {
        if (self.wip_completed.isSet()) {
            self.wip_completed.reset();

            self.image_index.deinit();
            self.image_index = self.image_index_wip;
            self.image_index_wip = std.ArrayList([]const u8).init(self.a);

            //        std.mem.sort([]const u8, self.image_index.items, c, ziglyph.Collator.ascending);
            for (self.image_index.items, 0..) |iname, idx| {
                std.debug.print("idx {d} = {s}\n", .{ idx, iname });
                if (std.mem.eql(u8, iname, self.current_image.filename)) {
                    self.current_image_idx = idx;
                }
            }

            self.image_index_ready = true;
        }
    }

    fn createTextLabel(self: *Self, text: []const u8, x: f32, y: f32) !ViewChunk {
        const text_colour = sdl3.SDL_Color{
            .r = 30,
            .g = 240,
            .b = 60,
        };
        const text_surface = sdl3.TTF_RenderText_Blended(font, @ptrCast(text), text.len, text_colour);
        if (text_surface == null) {
            return error.SDL;
        }

        const text_tex = sdl3.SDL_CreateTextureFromSurface(self.renderer, text_surface);

        const rect = sdl3.SDL_FRect{
            .x = x,
            .y = y,
            .w = @floatFromInt(text_tex.*.w),
            .h = @floatFromInt(text_tex.*.h),
        };
        //            _ = sdl3.SDL_RenderTexture(self.renderer, text_tex, null, &rect);
        _ = sdl3.SDL_DestroySurface(text_surface);

        return ViewChunk{
            .texture = text_tex,
            .dst_rect = rect,
        };
    }

    fn buildView(self: *Self) !void {
        switch (self.view_mode) {
            .waiting_for_image => |_| {
                //                const msg = try std.fmt.allocPrint(self.a, "Waiting for image {d} to get loaded...", .{slot});
                //                try self.labels.append(try self.createTextLabel(msg, 10, 10));
            },
            .showing_image => |_| {
                if (self.showing_image_texture) |shown_image_texture| {
                    try showImageTexture(self.renderer, shown_image_texture);
                }
            },
            .showing_error => |_| {},
        }
    }

    fn loop(self: *Self, events: *std.ArrayListAligned(Event, null)) !LoopResult {
        self.view_changed = false;
        var quit = false;
        var new_events = std.ArrayList(Event).init(self.a);

        self.handleImageIndexWorker();
        try self.handleReadFileWorker();
        try self.handleParseImageWorker();

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
                },
                sdl3.SDL_EVENT_WINDOW_ENTER_FULLSCREEN => {
                    self.fullscreen = true;
                },
                sdl3.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN => {
                    self.fullscreen = false;
                },
                else => {},
            }
        }

        for (events.items) |event| {
            switch (event) {
                .quit_requested => {
                    quit = true;
                },
            }
        }

        const red = 0;
        const green = 0;
        const blue = 0;
        const alpha = 0;

        if (self.view_changed) {
            _ = sdl3.SDL_SetRenderDrawColor(self.renderer, red, green, blue, alpha);
            _ = sdl3.SDL_RenderClear(self.renderer);

            self.labels.clearRetainingCapacity();
            try self.buildView();

            for (self.labels.items) |label| {
                _ = sdl3.SDL_RenderTexture(self.renderer, label.texture, null, &label.dst_rect);
            }

            _ = sdl3.SDL_RenderPresent(self.renderer);
        }

        self.frames += 1;
        return LoopResult{
            .events = new_events,
            .quit = quit,
        };
    }

    fn checkIndex(self: *Self, slot: usize) !void {
        if (self.image_index_ready == false) {
            return error.ImageIndexNotReady;
        }

        if (self.image_index.items.len == 0) {
            return error.ImageIndexEmpty;
        }

        if (slot >= self.image_index.items.len) {
            return error.ImageIndexSlotOutOfBounds;
        }
    }

    fn nameless(self: *Self, filename: []const u8) !NamelessResult {
        //        const filename = self.image_index.items[slot];
        if (self.image_cache.get(filename)) |cached_texture| {
            self.showing_image_texture = cached_texture;
            self.show_image = true;
            self.current_image = CurrentImage{
                .filename = filename,
                .texture = cached_texture,
            };
            return NamelessResult.done;
        } else {
            if (self.read_file_worker.queue(filename)) |_| {
                return NamelessResult.queued;
            } else |_| {
                //            self.pending_image_index_slot = slot;
                return NamelessResult.worker_busy;
            }
        }
    }

    fn changeImageToSlot(self: *Self, slot: usize) !void {
        try self.checkIndex(slot);
        self.view_changed = true;
        const filename = self.image_index.items[slot];
        const r = try self.nameless(filename);
        switch (r) {
            NamelessResult.done => {
                //                self.current_image_index_slot = slot;
            },
            NamelessResult.queued => {
                self.pending_image_index_slot = slot;
                self.view_mode = ViewMode{ .waiting_for_image = slot };
            },
            NamelessResult.worker_busy => {
                self.next_worker_task = filename;

                self.view_mode = ViewMode{ .waiting_for_image = slot };
            },
        }
        self.current_image_index_slot = slot;
    }

    fn firstImage(self: *Self) !void {
        return self.changeImageToSlot(0);
    }

    fn nextImage(self: *Self) !void {
        return self.changeImageToSlot(self.current_image_index_slot + 1);
    }

    fn prevImage(self: *Self) !void {
        if (self.current_image_index_slot > 0) {
            return self.changeImageToSlot(self.current_image_index_slot - 1);
        }

        return error.ImageIndexOutOfBounds;
    }

    fn lastImage(self: *Self) !void {
        return self.changeImageToSlot(self.image_index.items.len - 1);
    }
};

const MainEntryMode = enum {
    cwd,
    dir,
    file,
};

const createWindowAndRendererResult = struct {
    window: *sdl3.SDL_Window,
    renderer: *sdl3.SDL_Renderer,
};

fn createWindowAndRenderer(
    window_title: [*c]const u8,
    window_w: c_int,
    window_h: c_int,
    window_flags: u64,
) !createWindowAndRendererResult {
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

    if (window) |w| {
        if (renderer) |r| {
            return createWindowAndRendererResult{
                .window = w,
                .renderer = r,
            };
        }
    }

    unreachable();
}

var font: *sdl3.TTF_Font = undefined;

pub fn gfxpls_main(_: @TypeOf(std.time.nanoTimestamp())) !void {
    var events = std.ArrayList(Event).init(ally);
    defer events.deinit();

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

    var entry_mode = MainEntryMode.cwd;

    const target_handle = try std.fs.openFileAbsolute(target, .{});
    const target_metadata = try target_handle.metadata();
    var dir: std.fs.Dir = undefined;
    var dir_path: []const u8 = "";
    switch (target_metadata.kind()) {
        std.fs.File.Kind.file => {
            entry_mode = MainEntryMode.file;
            if (std.fs.path.dirname(target)) |path| {
                dir_path = path;
                dir = try std.fs.openDirAbsolute(dir_path, .{});

                //                const dir_with_iter = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
                //                const it = dir_with_iter.iterate();
                //                const ev = Event{ .dir_opened = DirOpened{
                //                    .path = dir_path,
                //                    .dir = dir_with_iter,
                //                    .iter = it,
                //                } };
                //                try events.append(ev);

            } else {
                return error.FAILED_TO_GET_PATH_WE_SUCK_ETC;
            }
        },
        std.fs.File.Kind.directory => {
            entry_mode = MainEntryMode.dir;
            dir_path = target;
            dir = try std.fs.openDirAbsolute(target, .{});
        },
        else => {
            std.debug.print("Unexpected file kind = {}\n", .{target_metadata.kind()});
            return error.UnexpectedFileKind;
        },
    }

    const read_file_worker = try ReadFileWorker.init(ally, dir);

    var load_first_image = false;
    if (entry_mode == MainEntryMode.file) {} else {
        load_first_image = true;
    }

    starting_image_index = std.ArrayList([]const u8).init(ally);
    const thread = try std.Thread.spawn(.{}, buildImageIndex, .{
        dir_path,
        &starting_image_index,
        &image_index_work_completed_event,
        load_first_image,
        read_file_worker,
    });
    thread.detach();

    const sdl_init_started_at = try std.time.Instant.now();
    if (sdl3.SDL_Init(sdl3.SDL_INIT_VIDEO) == false) {
        return error.SDL;
    }
    if (sdl3.TTF_Init() == false) {
        return error.SDL;
    }

    if (sdl3.TTF_OpenFont("/usr/share/fonts/SauceCodeProNerdFontMono-Regular.ttf", 32)) |f| {
        font = f;
    } else {
        return error.SDL;
    }

    const sdl_init_completed_at = try std.time.Instant.now();
    std.debug.print("SDL_Init ns={d}\n", .{sdl_init_completed_at.since(sdl_init_started_at)});

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

    const sdl_create_wr_started_at = try std.time.Instant.now();
    const windowAndRendererResult = try createWindowAndRenderer(
        window_title,
        window_w,
        window_h,
        window_flags,
    );
    const sdl_create_wr_completed_at = try std.time.Instant.now();
    std.debug.print("SDL_CreateWindowAndRenderer ns={d}\n", .{sdl_create_wr_completed_at.since(sdl_create_wr_started_at)});

    //const stdout_file = std.io.getStdOut().writer();
    //var bw = std.io.bufferedWriter(stdout_file);
    //const stdout = bw.writer();

    std.debug.print("renderer = {}\n", .{windowAndRendererResult.renderer});

    std.debug.print(">> DisplayContentScale={}\n", .{sdl3.SDL_GetDisplayContentScale(1)});
    std.debug.print(">> WindowDisplayScale={}\n", .{sdl3.SDL_GetWindowDisplayScale(windowAndRendererResult.window)});

    var main_context = try MainContext.init(
        ally,
        windowAndRendererResult.window,
        windowAndRendererResult.renderer,
        read_file_worker,
        30 * MB,
        &image_index_work_completed_event,
        starting_image_index,
    );

    var quit = false;
    while (!quit) {
        const loop_result = try main_context.loop(&events);
        quit = loop_result.quit;
        events.deinit();
        events = loop_result.events;
    }
}
