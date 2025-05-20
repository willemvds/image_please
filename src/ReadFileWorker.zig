const std = @import("std");

const ReadFileWorker = @This();

pub const Error = error{
    TaskInProgress,
    ResultNotReady,
};

a: std.mem.Allocator,
dir: std.fs.Dir,
mu: std.Thread.Mutex,
cond: std.Thread.Condition,
task: *Task,
task_waiting: bool,
task_completed_event: std.Thread.ResetEvent,
task_result: *Result,

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

    started_at: std.time.Instant,
    completed_at: std.time.Instant,

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
    dir: std.fs.Dir,
) !*ReadFileWorker {
    const worker = try a.create(ReadFileWorker);
    worker.a = a;
    worker.dir = dir;
    worker.mu = std.Thread.Mutex{};
    worker.cond = std.Thread.Condition{};
    worker.task = try Task.init(a, "");
    worker.task_waiting = false;
    worker.task_completed_event = std.Thread.ResetEvent{};
    worker.task_result = try Result.init(a);

    const file_reader_thread = try std.Thread.spawn(.{}, readFileWorkerThread, .{ worker, a });
    file_reader_thread.detach();

    return worker;
}

pub fn queue(self: *ReadFileWorker, path: []const u8) !void {
    if (self.task_waiting == true) {
        return Error.TaskInProgress;
    }
    self.task.filename = path;
    self.mu.lock();
    self.task_waiting = true;
    self.mu.unlock();
    self.cond.signal();
}

pub fn last_result(self: *ReadFileWorker) !*Result {
    if (self.task_completed_event.isSet()) {
        const result = self.task_result;
        self.task = try Task.init(self.a, "");
        self.task_completed_event.reset();
        self.task_waiting = false;
        return result;
    }

    return Error.ResultNotReady;
}

fn readFile(worker: *ReadFileWorker) ![]const u8 {
    const file = try worker.dir.openFile(worker.task.filename, .{});
    const stat = try file.stat();
    const contents = try file.readToEndAllocOptions(worker.a, stat.size, stat.size, @alignOf(u8), null);
    return contents;
}

fn readFileWorkerThread(worker: *ReadFileWorker, a: std.mem.Allocator) !void {
    while (true) {
        worker.mu.lock();
        while (worker.task_waiting == false) {
            worker.cond.wait(&worker.mu);
        }
        worker.task_result = try Result.init(a);
        worker.task_result.filename = worker.task.filename;
        worker.task_result.started_at = try std.time.Instant.now();
        if (readFile(worker)) |file_content| {
            worker.task_result.kind = Result.Kind.ok;
            worker.task_result.content = file_content;
        } else |err| {
            worker.task_result.kind = Result.Kind.err;
            worker.task_result.err = err;
        }
        worker.task_result.completed_at = try std.time.Instant.now();

        worker.task_waiting = false;
        worker.task_completed_event.set();
        worker.mu.unlock();
    }
}
