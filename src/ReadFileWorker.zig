const std = @import("std");

const ReadFileWorker = @This();

pub const Error = error{
    TaskInProgress,
    ResultNotReady,
};

a: std.mem.Allocator,
io: std.Io,
dir: std.Io.Dir,
mu: std.Io.Mutex,
cond: std.Io.Condition,
task: *Task,
task_waiting: bool,
task_completed_event: std.Io.Event,
task_result: *Result,
ready: bool = true,

const Task = struct {
    filename: []const u8,

    fn init(a: std.mem.Allocator, filename: []const u8) !*Task {
        const task = try a.create(Task);
        task.filename = filename;
        return task;
    }
};

pub const Result = struct {
    kind: Kind,
    filename: []const u8,
    content: []const u8,
    err: anyerror,

    started_at: std.Io.Timestamp,
    completed_at: std.Io.Timestamp,

    pub const Kind = enum {
        ok,
        err,
    };

    fn init(a: std.mem.Allocator) !*Result {
        const rfr = try a.create(Result);
        rfr.kind = Kind.err;
        return rfr;
    }
};

pub fn init(
    a: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
) !*ReadFileWorker {
    const worker = try a.create(ReadFileWorker);
    worker.ready = true;
    worker.a = a;
    worker.io = io;
    worker.dir = dir;
    worker.mu = .init;
    worker.cond = .init;
    worker.task = try Task.init(a, "");
    worker.task_waiting = false;
    worker.task_completed_event = .unset;
    worker.task_completed_event.reset();
    worker.task_result = try Result.init(a);

    const file_reader_thread = try std.Thread.spawn(.{}, readFileWorkerThread, .{ worker, a });
    file_reader_thread.detach();

    return worker;
}

pub fn queue(self: *ReadFileWorker, path: []const u8) !void {
    if (!self.ready) {
        return Error.TaskInProgress;
    }
    self.task_completed_event.reset();
    self.ready = false;
    try self.mu.lock(self.io);
    self.task.filename = path;
    self.task_waiting = true;
    self.mu.unlock(self.io);
    self.cond.signal(self.io);
}

pub fn lastResult(self: *ReadFileWorker) !*Result {
    const completed = self.task_completed_event.isSet();
    if (completed) {
        const result = self.task_result;
        self.task = try Task.init(self.a, "");
        self.ready = true;

        self.task_completed_event.reset();
        return result;
    }

    return Error.ResultNotReady;
}

pub fn isBusy(self: *ReadFileWorker) bool {
    return !self.ready;
}

fn readFile(worker: *ReadFileWorker) ![]const u8 {
    const file = try worker.dir.openFile(worker.io, worker.task.filename, .{});
    const stat = try file.stat(worker.io);
    const buffer: []u8 = try worker.a.alloc(u8, stat.size);
    const bytes_read = try file.readPositionalAll(worker.io, buffer, 0);
    std.debug.assert(bytes_read == stat.size);
    return buffer;
}

fn readFileWorkerThread(worker: *ReadFileWorker, a: std.mem.Allocator) !void {
    while (true) {
        try worker.mu.lock(worker.io);
        defer worker.mu.unlock(worker.io);
        while (worker.task_waiting == false) {
            try worker.cond.wait(worker.io, &worker.mu);
        }
        worker.task_result = try Result.init(a);
        worker.task_result.filename = worker.task.filename;
        worker.task_result.started_at = std.Io.Clock.awake.now(worker.io);
        if (readFile(worker)) |file_content| {
            worker.task_result.kind = Result.Kind.ok;
            worker.task_result.content = file_content;
        } else |err| {
            worker.task_result.kind = Result.Kind.err;
            worker.task_result.err = err;
        }
        worker.task_result.completed_at = std.Io.Clock.awake.now(worker.io);

        worker.task_waiting = false;
        worker.task_completed_event.set(worker.io);
    }
}
