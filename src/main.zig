const std = @import("std");
//const ziglyph = @import("ziglyph");
const sdl3 = @cImport({
    @cInclude("SDL3/SDL.h");
    //    @cInclude("SDL3/SDL_main.h");
    @cInclude("SDL3_image/SDL_image.h");
});

const DirOpened = struct {
    path: []const u8,
    dir: std.fs.Dir,
    iter: std.fs.Dir.Iterator,
    load_first_image: bool = false,
};

const DirImageIndexBuilt = struct {};

const ImageLoaded = struct {
    filename: []const u8,
    texture: *sdl3.SDL_Texture,
};

const LoadImageQueued = struct {
    filename: []const u8,
};

const EventTag = enum {
    quit_requested,
    dir_opened,
    dir_image_index_built,
    image_loaded,
    load_image_queued,
};

const Event = union(EventTag) {
    quit_requested: void,
    dir_opened: DirOpened,
    dir_image_index_built: DirImageIndexBuilt,
    image_loaded: ImageLoaded,
    load_image_queued: LoadImageQueued,
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

const LoadImageWorkerResultKind = enum {
    empty,
    ok,
    err,
};

const LoadImageWorkerResult = struct {
    kind: LoadImageWorkerResultKind,
    path: []const u8,
    surface: ?*sdl3.SDL_Surface = null,
    err: anyerror = error.notset,

    fn init(path: []const u8) !*LoadImageWorkerResult {
        const r = try ally.create(LoadImageWorkerResult);
        r.kind = LoadImageWorkerResultKind.empty;
        r.path = path;
        r.surface = null;
        r.err = error.notset;
        return r;
    }
};

const LoadImageWorker = struct {
    dir: std.fs.Dir,
    mu: std.Thread.Mutex = std.Thread.Mutex{},
    cond: std.Thread.Condition = std.Thread.Condition{},
    work_completed_event: std.Thread.ResetEvent = std.Thread.ResetEvent{},

    read_buffer: []u8,

    has_work_waiting: bool = false,

    wip_path: []const u8 = "",
    has_wip: bool = false,
    result: *LoadImageWorkerResult,

    const Self = @This();

    fn init(
        a: std.mem.Allocator,
        dir: std.fs.Dir,
        max_image_size: usize,
    ) !*LoadImageWorker {
        var loadImageWorker = try a.create(LoadImageWorker);
        loadImageWorker.read_buffer = try a.alignedAlloc(u8, @alignOf(u8), max_image_size);
        loadImageWorker.dir = dir;
        loadImageWorker.mu = std.Thread.Mutex{};
        loadImageWorker.cond = std.Thread.Condition{};
        loadImageWorker.work_completed_event = std.Thread.ResetEvent{};
        loadImageWorker.has_work_waiting = false;
        loadImageWorker.wip_path = "";
        loadImageWorker.has_wip = false;
        loadImageWorker.result = try LoadImageWorkerResult.init("");
        return loadImageWorker;
    }

    fn start(self: *Self) !void {
        const load_image_thread = try std.Thread.spawn(.{}, loadImageThreadWorker, .{self});
        load_image_thread.detach();
    }

    fn queue(self: *Self, path: []const u8) !void {
        if (self.has_work_waiting == true) {
            return;
            //            return error.WorkInProgress;
        }

        {
            self.wip_path = path;
            self.mu.lock();
            self.has_work_waiting = true;
            self.mu.unlock();
        }

        self.cond.signal();
    }

    fn last_result(self: *Self) !*LoadImageWorkerResult {
        if (self.work_completed_event.isSet()) {
            self.has_work_waiting = false;
            const result = self.result;
            self.result = try LoadImageWorkerResult.init("");
            self.work_completed_event.reset();
            return result;
        }

        return error.NOT_READY;
    }
};

pub fn loadImageThreadWorker(
    worker: *LoadImageWorker,
) !void {
    while (true) {
        worker.mu.lock();
        defer worker.mu.unlock();
        while (worker.has_work_waiting == false) {
            worker.cond.wait(&worker.mu);
        }
        defer worker.work_completed_event.set();

        worker.result.path = worker.wip_path;
        if (worker.dir.readFile(worker.wip_path, worker.read_buffer)) |file_contents| {
            const contents_io = sdl3.SDL_IOFromConstMem(@ptrCast(file_contents), file_contents.len);
            const img_surface = sdl3.IMG_Load_IO(contents_io, false);
            if (img_surface != null) {
                worker.result.kind = LoadImageWorkerResultKind.ok;
                worker.result.surface = img_surface;
            } else {
                worker.result.kind = LoadImageWorkerResultKind.err;
                worker.result.err = error.SDL;
                std.debug.print("Some sort of file parsing error = {s}\n", .{sdl3.SDL_GetError()});
            }
        } else |err| {
            worker.result.kind = LoadImageWorkerResultKind.err;
            worker.result.err = err;
        }
        worker.has_work_waiting = false;
    }
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
};

pub fn buildImageIndex(
    dir_path: []const u8,
    dir_iter: std.fs.Dir.Iterator,
    image_index: *std.ArrayList([]const u8),
    done_event: *std.Thread.ResetEvent,
    queue_load_first: bool,
    load_image_worker: *LoadImageWorker,
) !void {
    var casted_iter = @as(std.fs.Dir.Iterator, dir_iter);
    var load_first_queued = false;
    while (try casted_iter.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.file) {
            continue;
        }
        const entry_name = try ally.dupe(u8, entry.name);
        const target = try std.fs.path.joinZ(ally, &[_][]const u8{ dir_path, entry_name });
        if (canLoadImage(@ptrCast(target))) {
            try image_index.*.append(entry_name);
            if (queue_load_first and !load_first_queued) {
                try load_image_worker.queue(entry_name);
                load_first_queued = true;
            }
        }
    }
    done_event.set();
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

const PendingImageStage = enum {
    display,
    cache_next,
    cache_prev,
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

const MainContext = struct {
    a: std.mem.Allocator,
    window: *sdl3.SDL_Window,
    renderer: *sdl3.SDL_Renderer,
    frames: u64 = 0,
    current_image: CurrentImage,
    current_image_idx: usize = 0,
    pending_image_index: usize = 0,
    pending_image_stage: PendingImageStage,
    image_load_buffer: []u8,
    image_index_ready: bool = false,
    image_index: std.ArrayList([]const u8),
    image_index_dir: ?std.fs.Dir = null,
    image_index_iter: ?std.fs.Dir.Iterator = null,
    image_index_wip: std.ArrayList([]const u8),
    image_cache: ImageCache,
    wip_completed: std.Thread.ResetEvent,
    fullscreen: bool = true,
    command_in_progress: Command = Command.none,

    load_image_worker: *LoadImageWorker,

    keybinds: std.hash_map.AutoHashMap(u32, Command),
    show_image: bool = false,

    const Self = @This();

    const LoopResult = struct {
        events: EventList,
        quit: bool = false,
    };

    fn init(
        a: std.mem.Allocator,
        window: *sdl3.SDL_Window,
        renderer: *sdl3.SDL_Renderer,
        load_image_worker: *LoadImageWorker,
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
            .image_cache = ImageCache.init(a),
            .wip_completed = std.Thread.ResetEvent{},
            .current_image = CurrentImage{ .filename = "", .texture = undefined },
            .pending_image_stage = PendingImageStage.display,
            .image_load_buffer = image_load_buffer,
            .load_image_worker = load_image_worker,
            .keybinds = keybinds,
            .show_image = false,
        };
    }

    fn handleImageLoaded(self: *Self, ev: ImageLoaded) !void {
        try self.image_cache.put(ev.filename, ev.texture);
        switch (self.pending_image_stage) {
            PendingImageStage.display => {
                self.show_image = true;
                self.current_image_idx = self.pending_image_index;
                self.current_image = CurrentImage{
                    .filename = ev.filename,
                    .texture = ev.texture,
                };
                try showImageTexture(self.renderer, ev.texture);

                self.pending_image_stage = PendingImageStage.cache_next;
                if (self.loadNextImage()) |_| {} else |_| {}
            },
            PendingImageStage.cache_next => {
                std.debug.print("@@@$$$ Cached Image Load = {s}\n", .{ev.filename});
            },
            PendingImageStage.cache_prev => {},
        }
    }

    fn handleDirOpened(self: *Self, ev: DirOpened) !void {
        self.image_index_dir = ev.dir;
        self.image_index_iter = ev.iter;

        const thread = try std.Thread.spawn(.{}, buildImageIndex, .{
            ev.path,
            self.image_index_iter.?,
            &self.image_index_wip,
            &self.wip_completed,
            ev.load_first_image,
            self.load_image_worker,
        });
        thread.detach();
    }

    fn handleDirImageIndexBuilt(self: *Self) !void {
        //        var c = try ziglyph.Collator.init(self.a);
        //        defer c.deinit();

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
                if (self.loadNextImage()) |lev| {
                    self.pending_image_stage = PendingImageStage.display;
                    try new_events.*.append(lev);
                } else |_| {}
            },
            Command.prev_image => {
                if (self.loadPreviousImage()) |lev| {
                    self.pending_image_stage = PendingImageStage.display;
                    try new_events.*.append(lev);
                } else |_| {}
            },
            Command.first_image => {
                if (self.loadFirstImage()) |lev| {
                    self.pending_image_stage = PendingImageStage.display;
                    try new_events.*.append(lev);
                } else |_| {}
            },
            Command.last_image => {
                if (self.loadLastImage()) |lev| {
                    self.pending_image_stage = PendingImageStage.display;
                    try new_events.*.append(lev);
                } else |_| {}
            },
            Command.toggle_fullscreen => {
                _ = sdl3.SDL_SetWindowFullscreen(self.window, !self.fullscreen);
            },
            else => {},
        }
    }

    fn loop(self: *Self, events: *std.ArrayListAligned(Event, null)) !LoopResult {
        var quit = false;
        var new_events = std.ArrayList(Event).init(self.a);

        while (events.pop()) |event| {
            switch (event) {
                .image_loaded => {
                    try self.handleImageLoaded(event.image_loaded);
                },
                .load_image_queued => {},
                .dir_opened => {
                    try self.handleDirOpened(event.dir_opened);
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

        if (self.load_image_worker.last_result()) |result| {
            if (result.kind == LoadImageWorkerResultKind.ok) {
                if (result.surface) |surface| {
                    const tex = try textureFromSurface(self.renderer, surface);
                    sdl3.SDL_DestroySurface(result.surface);
                    try new_events.append(Event{ .image_loaded = ImageLoaded{ .filename = result.path, .texture = tex } });
                }
            }
        } else |_| {}

        if (self.show_image) {
            try showImageTexture(self.renderer, self.current_image.texture);
        }
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

        self.frames += 1;

        return LoopResult{
            .events = new_events,
            .quit = quit,
        };
    }

    fn loadImage(self: *Self, path: []const u8) !Event {
        if (self.image_cache.get(path)) |tex| {
            return Event{ .image_loaded = ImageLoaded{ .filename = path, .texture = tex } };
        } else {
            try self.load_image_worker.queue(path);
            return Event{ .load_image_queued = LoadImageQueued{ .filename = path } };
        }
    }

    fn checkIndex(self: *Self) !void {
        if (self.image_index_ready == false) {
            return error.IMAGE_INDEX_NOT_READY;
        }

        if (self.image_index.items.len == 0) {
            return error.IMAGE_INDEX_EMPTY;
        }
    }

    fn loadFirstImage(self: *Self) !Event {
        try self.checkIndex();
        self.pending_image_index = 0;

        return try self.loadImage(self.image_index.items[self.pending_image_index]);
    }

    fn loadLastImage(self: *Self) !Event {
        try self.checkIndex();
        self.pending_image_index = self.image_index.items.len - 1;

        return try self.loadImage(self.image_index.items[self.pending_image_index]);
    }

    fn loadPreviousImage(self: *Self) !Event {
        try self.checkIndex();

        const idx = self.current_image_idx;
        if (idx > 0) {
            self.pending_image_index = idx - 1;
            return try self.loadImage(self.image_index.items[self.pending_image_index]);
        }

        return error.AwWell;
    }

    fn loadNextImage(self: *Self) !Event {
        try self.checkIndex();
        const idx = self.current_image_idx;
        if (idx < self.image_index.items.len - 1) {
            self.pending_image_index = idx + 1;
            return try self.loadImage(self.image_index.items[self.pending_image_index]);
        }

        return error.AwWell;
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
    switch (target_metadata.kind()) {
        std.fs.File.Kind.file => {
            entry_mode = MainEntryMode.file;
            if (std.fs.path.dirname(target)) |dir_path| {
                dir = try std.fs.openDirAbsolute(dir_path, .{});

                const dir_with_iter = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
                const it = dir_with_iter.iterate();
                const ev = Event{ .dir_opened = DirOpened{
                    .path = dir_path,
                    .dir = dir_with_iter,
                    .iter = it,
                } };
                try events.append(ev);
            } else {
                return error.FAILED_TO_GET_PATH_WE_SUCK_ETC;
            }
        },
        std.fs.File.Kind.directory => {
            entry_mode = MainEntryMode.dir;
            dir = try std.fs.openDirAbsolute(target, .{});
        },
        else => {
            std.debug.print("Unexpected file kind = {}\n", .{target_metadata.kind()});
            return error.UnexpectedFileKind;
        },
    }

    var load_image_worker = try LoadImageWorker.init(ally, dir, 30 * MB);
    try load_image_worker.start();

    if (entry_mode == MainEntryMode.file) {
        try load_image_worker.queue(target);

        //        try load_image_worker.queue("what2");
    } else {
        const dir_with_iter = try std.fs.openDirAbsolute(target, .{ .iterate = true });
        const it = dir_with_iter.iterate();
        const ev = Event{ .dir_opened = DirOpened{
            .path = target,
            .dir = dir_with_iter,
            .iter = it,
            .load_first_image = true,
        } };
        try events.append(ev);
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

    const windowAndRendererResult = try createWindowAndRenderer(
        window_title,
        window_w,
        window_h,
        window_flags,
    );

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
        load_image_worker,
        30 * MB,
    );

    var quit = false;
    while (!quit) {
        const loop_result = try main_context.loop(&events);
        quit = loop_result.quit;
        events.deinit();
        events = loop_result.events;
    }
}
