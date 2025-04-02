const std = @import("std");
const clap = @import("clap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Get command line arguments
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
        .assignment_separators = "=",
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // Print help
    if (res.args.help != 0) {
        try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        return;
    }

    // Open output file if specified
    var file_opt: ?std.fs.File = null;
    var file_writer_opt: ?std.fs.File.Writer = null;
    defer if (file_opt) |f| f.close();

    if (res.args.file) |file_path| {
        file_opt = try std.fs.cwd().createFile(
            file_path,
            .{ .read = true, .truncate = true },
        );
        file_writer_opt = file_opt.?.writer();
    }

    var generator = try Generator.init(gpa.allocator(), res);
    defer generator.deinit();

    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));

    var ctx = try Context.init(gpa.allocator(), seed);
    defer ctx.deinit();

    const count = res.args.count orelse 1;

    const template = if (res.positionals[0].len > 0) res.positionals[0][0] else return error.MissingTemplate;

    for (0..count) |i| {
        // Generate random json values
        const result = try generator.generate(i, template, &ctx);

        // Print to stdout
        const stdout = std.io.getStdOut().writer();
        try std.json.stringify(result, .{}, stdout);
        try stdout.writeAll("\n");

        // Write to file
        if (file_writer_opt) |file_writer| {
            try std.json.stringify(result, .{}, file_writer);
            try file_writer.writeAll("\n");
        }
    }
}

/// Parsers for clap arguments
const parsers = .{
    .COUNT = clap.parsers.int(usize, 10),
    .VARIABLE = clap.parsers.string,
    .PREFIX = clap.parsers.string,
    .FILE = clap.parsers.string,
    .TEMPLATE = clap.parsers.string,
};

/// Command line arguments that users can use with this tool
const params = clap.parseParamsComptime(
    \\-h, --help                   Print help
    \\-c, --count <COUNT>          Number of JSON values to generate [default: 1]
    \\-v, --variable <VARIABLE>...      User-defined variables
    \\-p, --prefix <PREFIX>        Prefix for variable and generator names [default: $]
    \\-f, --file <FILE>            File to output
    \\<TEMPLATE>...                Json template used to generate values
);

const Args = clap.Result(clap.Help, &params, parsers);

/// Context manages state for JSON evaluation.
/// It maintains a stack to prevent recursive circular references
/// and provides random number generation.
const Context = struct {
    prng: std.Random.DefaultPrng,
    eval_stack: std.ArrayList([]const u8),
    arena: *std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, seed: u64) !Self {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);

        return Self{ .prng = std.Random.DefaultPrng.init(seed), .eval_stack = std.ArrayList([]const u8).init(arena.allocator()), .arena = arena };
    }

    pub fn deinit(self: *Self) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

/// The generator that serves as the starting point for random JSON value generation.
const Generator = struct {
    prefix: []const u8,
    vars: std.StringHashMap(std.json.Value),
    arena: *std.heap.ArenaAllocator,

    const Self = @This();

    const GeneratorType = enum {
        i,
        int,
        oneof,
        str,
        arr,
        obj,
        option,
    };

    pub fn init(alloc: std.mem.Allocator, args: Args) !Self {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);

        var g = Self{
            .arena = arena,
            .prefix = args.args.prefix orelse "$",
            .vars = std.StringHashMap(std.json.Value).init(arena.allocator()),
        };

        const predefined_vars = [_]struct { []const u8, std.json.Value }{ .{ "i", std.json.Value{ .integer = 0 } }, .{ "u8", try integer(g.allocator(), 0, std.math.maxInt(u8), g.prefix) }, .{
            "u16",
            try integer(g.allocator(), 0, std.math.maxInt(u16), g.prefix),
        }, .{ "u32", try integer(g.allocator(), 0, std.math.maxInt(u32), g.prefix) }, .{
            "i8", try integer(g.allocator(), std.math.minInt(i8), std.math.maxInt(i8), g.prefix),
        }, .{
            "i16", try integer(g.allocator(), std.math.minInt(i16), std.math.maxInt(i16), g.prefix),
        }, .{
            "i32", try integer(g.allocator(), std.math.minInt(i32), std.math.maxInt(i32), g.prefix),
        }, .{
            "i64", try integer(g.allocator(), std.math.minInt(i64), std.math.maxInt(i64), g.prefix),
        }, .{
            "digit", try integer(g.allocator(), 0, 9, g.prefix),
        }, .{
            "bool",
            try oneof(g.allocator(), try arrayToJsonValue(g.allocator(), &[_]std.json.Value{ std.json.Value{ .bool = true }, std.json.Value{ .bool = false } }), g.prefix),
        }, .{ "alpha", try oneof(g.allocator(), std.json.Value{ .string = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" }, g.prefix) } };

        for (predefined_vars) |entry| {
            const key = try std.fmt.allocPrint(g.allocator(), "{?s}{?s}", .{ g.prefix, entry.@"0" });
            try g.vars.put(key, entry.@"1");
        }

        for (args.args.variable) |v| {
            var iter = std.mem.splitSequence(u8, v, "=");
            const key = iter.next().?;
            const actual_key = try std.fmt.allocPrint(g.allocator(), "{?s}{?s}", .{ g.prefix, key });

            const json_str = iter.next().?;
            const json = try std.json.parseFromSlice(std.json.Value, g.allocator(), json_str, .{});
            try g.vars.put(actual_key, json.value);
        }

        return g;
    }

    pub fn deinit(self: *Self) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }

    fn allocator(self: *@This()) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Generate random JSON based on a user-defined JSON template
    pub fn generate(self: *@This(), i: usize, json_template: []const u8, ctx: *Context) !std.json.Value {

        // Update IterateGenerator field with the new iterate value
        const key = try std.fmt.allocPrint(self.allocator(), "{s}i", .{self.prefix});
        defer self.allocator().free(key);
        const i_value = std.json.Value{ .integer = @as(i64, @intCast(i)) };
        try self.vars.put(key, i_value);

        const json = try std.json.parseFromSlice(std.json.Value, self.allocator(), json_template, .{});
        defer json.deinit();

        return try self.eval_json(ctx, json.value);
    }

    /// Evaluates and returns a value based on the given JSON template.
    pub fn eval_json(self: *@This(), ctx: *Context, json: std.json.Value) anyerror!std.json.Value {
        switch (json) {
            .null => return std.json.Value{ .null = json.null },
            .bool => return std.json.Value{ .bool = json.bool },
            .integer => return std.json.Value{ .integer = json.integer },
            .float => return std.json.Value{ .float = json.float },
            .string => return try self.eval_string(ctx, json.string),
            .array => {
                var resolved_array = std.json.Array.init(self.allocator());
                errdefer resolved_array.deinit();

                for (json.array.items) |item| {
                    const resolved_item = try self.eval_json(ctx, item);
                    try resolved_array.append(resolved_item);
                }
                return std.json.Value{ .array = resolved_array };
            },
            .object => return try self.eval_object(ctx, json.object),
            else => return error.InvalidValueType,
        }
    }

    fn eval_object(self: *@This(), ctx: *Context, object: std.json.ObjectMap) anyerror!std.json.Value {
        // Handle Predefined Generators
        if (object.count() == 1) {
            var it = object.iterator();
            const kv = it.next().?;
            const value = try self.eval_json(ctx, kv.value_ptr.*);

            if (std.mem.startsWith(u8, kv.key_ptr.*, "$")) {
                const trimed_key = std.mem.trimLeft(u8, kv.key_ptr.*, self.prefix);

                const variable = std.meta.stringToEnum(GeneratorType, trimed_key);
                if (variable) |var_type| {
                    switch (var_type) {
                        .i => {
                            const key = try std.fmt.allocPrint(self.allocator(), "{s}i", .{self.prefix});
                            defer self.allocator().free(key);

                            const i_opt = self.vars.get(key);

                            if (i_opt) |i| {
                                return i;
                            } else {
                                return error.NoIterateValue;
                            }
                        },
                        .int => {
                            const gen = try IntegerGenerator.fromJson(value);
                            return gen.generate(ctx);
                        },
                        .str => {
                            const gen = try StringGenerator.fromJson(self.allocator(), value);
                            return gen.generate(self.allocator());
                        },
                        .arr => {
                            const gen = try ArrayGenerator.fromJson(kv.value_ptr.*, ctx, self);
                            return gen.generate(self.allocator(), self, ctx);
                        },
                        .obj => {
                            const gen = try ObjectGenerator.fromJson(self.allocator(), value);
                            return gen.generate(self, ctx);
                        },
                        .oneof => {
                            const gen = try OneofGenerator.fromJson(self.allocator(), value);
                            return gen.generate(ctx);
                        },
                        .option => {
                            const gen = OptionGenerator.fromJson(value);
                            return try gen.generate(self, ctx);
                        },
                    }
                } else {
                    return error.InvalidValueType;
                }
            }
        }

        var result = std.json.ObjectMap.init(self.allocator());
        var it = object.iterator();
        while (it.next()) |kv| {
            const resolved_key = try self.eval_json(ctx, std.json.Value{ .string = kv.key_ptr.* });
            const resolved_value = try self.eval_json(ctx, kv.value_ptr.*);
            try result.put(resolved_key.string, resolved_value);
        }
        return std.json.Value{ .object = result };
    }

    fn eval_string(self: *@This(), ctx: *Context, s: []const u8) anyerror!std.json.Value {
        if (!std.mem.startsWith(u8, s, self.prefix)) {
            const owned_string = try self.allocator().dupe(u8, s);
            return std.json.Value{ .string = owned_string };
        }

        return try self.resolve_var(ctx, s);
    }

    fn resolve_var(self: *@This(), ctx: *Context, name: []const u8) anyerror!std.json.Value {
        if (containsVariable(ctx.eval_stack, name)) {
            return error.CircularReference;
        }
        try ctx.eval_stack.append(name);
        defer {
            // Find and remove the item we just added
            for (ctx.eval_stack.items, 0..) |item, i| {
                if (std.mem.eql(u8, item, name)) {
                    _ = ctx.eval_stack.orderedRemove(i);
                    break;
                }
            }
        }

        if (self.vars.get(name)) |v| {
            return try self.eval_json(ctx, v);
        }

        return error.UndefinedVar;
    }

    fn containsVariable(list: std.ArrayList([]const u8), target: []const u8) bool {
        for (list.items) |item| {
            if (std.mem.eql(u8, item, target)) {
                return true;
            }
        }
        return false;
    }
};

fn oneof(allocator: std.mem.Allocator, value: std.json.Value, prefix: []const u8) !std.json.Value {
    var array: std.json.Array = undefined;

    if (value == .string) {
        array = try stringToJsonArray(allocator, value.string);
    } else if (value == .array) {
        array = value.array;
    } else {
        return error.InvalidOneofValue;
    }

    var outer_obj = std.json.ObjectMap.init(allocator);
    errdefer outer_obj.deinit();

    const key = try std.fmt.allocPrint(allocator, "{?s}oneof", .{prefix});
    errdefer allocator.free(key);

    try outer_obj.put(key, std.json.Value{ .array = array });
    return std.json.Value{ .object = outer_obj };
}

fn stringToJsonArray(allocator: std.mem.Allocator, str: []const u8) !std.json.Array {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    for (str) |char| {
        const char_str = try allocator.dupe(u8, &[_]u8{char});
        try array.append(std.json.Value{ .string = char_str });
    }

    return array;
}

fn arrayToJsonValue(allocator: std.mem.Allocator, items: []const std.json.Value) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    for (items) |item| {
        try array.append(item);
    }

    return std.json.Value{ .array = array };
}

const OneofGenerator = struct {
    list: []std.json.Value,

    pub fn init() !OneofGenerator {
        return OneofGenerator{
            .list = &[_]std.json.Value{},
        };
    }

    pub fn toJson(self: *@This(), allocator: std.mem.Allocator, prefix: []const u8) anyerror!std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer obj.deinit();

        var array = try std.json.Array.initCapacity(allocator, self.*.len);
        errdefer array.deinit();

        for (self.list) |item| {
            try array.append(item);
        }

        const key = try std.fmt.allocPrint(allocator, "{?s}oneof", .{prefix});
        errdefer allocator.free(key);

        try obj.put(key, std.json.Value{ .array = array });
        return std.json.Value{ .object = obj };
    }

    pub fn fromJson(allocator: std.mem.Allocator, json_value: std.json.Value) anyerror!OneofGenerator {
        if (json_value == .array) {
            if (json_value.array.items.len > 0) {
                return OneofGenerator{ .list = try allocator.dupe(std.json.Value, json_value.array.items) };
            } else {
                return error.EmptyArray;
            }
        }

        return error.NotAnArray;
    }

    pub fn validate(self: *@This()) anyerror!void {
        if (self.list.len == 0) {
            return error.EmptyArray;
        }
    }

    pub fn generate(self: @This(), ctx: *Context) std.json.Value {
        const random = ctx.prng.random();
        const ix = random.uintLessThan(usize, self.list.len);
        return self.list[ix];
    }
};

fn integer(allocator: std.mem.Allocator, min: i64, max: i64, prefix: []const u8) anyerror!std.json.Value {
    var gen = IntegerGenerator.init(min, max);
    try gen.validate();
    return try gen.toJson(allocator, prefix);
}

const IntegerGenerator = struct {
    min: i64,
    max: i64,

    const Self = @This();

    pub fn init(min: i64, max: i64) IntegerGenerator {
        return .{
            .min = min,
            .max = max,
        };
    }

    pub fn toJson(self: *Self, allocator: std.mem.Allocator, prefix: []const u8) anyerror!std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer obj.deinit();

        try obj.put("min", std.json.Value{ .integer = self.min });
        try obj.put("max", std.json.Value{ .integer = self.max });

        var outer_obj = std.json.ObjectMap.init(allocator);
        errdefer outer_obj.deinit();

        const key = try std.fmt.allocPrint(allocator, "{?s}int", .{prefix});
        errdefer allocator.free(key);

        try outer_obj.put(key, std.json.Value{ .object = obj });

        return std.json.Value{ .object = outer_obj };
    }

    pub fn fromJson(json_value: std.json.Value) anyerror!IntegerGenerator {
        if (json_value != .object) {
            return error.NotAnObject;
        }

        const min = json_value.object.get("min") orelse return error.MissingMinField;
        const max = json_value.object.get("max") orelse return error.MissingMaxField;

        if (min != .integer or max != .integer) {
            return error.MinOrMaxShouldBeAnInteger;
        }

        const generator = IntegerGenerator.init(min.integer, max.integer);
        try generator.validate();

        return generator;
    }

    pub fn validate(self: Self) anyerror!void {
        if (self.min > self.max) {
            return error.MinGraterThanMax;
        }
    }

    fn generate(self: Self, ctx: *Context) std.json.Value {
        const random = ctx.prng.random();
        return std.json.Value{ .integer = random.intRangeAtMost(i64, self.min, self.max) };
    }
};

const StringGenerator = struct {
    list: []std.json.Value,

    pub fn fromJson(allocator: std.mem.Allocator, json_value: std.json.Value) anyerror!StringGenerator {
        if (json_value == .array) {
            if (json_value.array.items.len > 0) {
                return StringGenerator{ .list = try allocator.dupe(std.json.Value, json_value.array.items) };
            } else {
                return error.EmptyArray;
            }
        } else if (json_value == .string) {
            var array = std.json.Array.init(allocator);
            errdefer array.deinit();

            try array.append(json_value);
            return StringGenerator{ .list = try allocator.dupe(std.json.Value, array.items) };
        }
        return error.InvalidValueType;
    }

    pub fn generate(self: @This(), allocator: std.mem.Allocator) anyerror!std.json.Value {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        for (self.list) |item| {
            if (item == .string) {
                try buffer.appendSlice(item.string);
            } else if (item == .integer) {
                const int_str = try std.fmt.allocPrint(allocator, "{d}", .{item.integer});
                defer allocator.free(int_str);
                try buffer.appendSlice(int_str);
            } else if (item == .float) {
                const float_str = try std.fmt.allocPrint(allocator, "{d}", .{item.float});
                defer allocator.free(float_str);
                try buffer.appendSlice(float_str);
            } else if (item == .bool) {
                const bool_str = try std.fmt.allocPrint(allocator, "{}", .{item.bool});
                defer allocator.free(bool_str);
                try buffer.appendSlice(bool_str);
            }
        }

        const result_str = try allocator.dupe(u8, buffer.items);
        return std.json.Value{ .string = result_str };
    }
};

const ArrayGenerator = struct {
    len: i64,
    val: std.json.Value,

    pub fn fromJson(json_value: std.json.Value, ctx: *Context, g: *Generator) anyerror!ArrayGenerator {
        if (json_value != .object) {
            return error.InvalidArrayObject;
        }

        var len = json_value.object.get("len") orelse return error.NoLenField;
        len = try g.eval_json(ctx, len);

        const val = json_value.object.get("val") orelse return error.NoValField;

        if (len != .integer) return error.InvalidLenType;

        return ArrayGenerator{ .len = len.integer, .val = val };
    }

    pub fn generate(self: @This(), allocator: std.mem.Allocator, g: *Generator, ctx: *Context) anyerror!std.json.Value {
        var array = std.json.Array.init(allocator);
        errdefer array.deinit();

        if (self.len < 0) return error.NegativeLength;
        const length = @as(usize, @intCast(self.len));

        var i: usize = 0;

        while (i < length) : (i += 1) {
            const resolved = try g.eval_json(ctx, self.val);
            try array.append(resolved);
        }

        return std.json.Value{ .array = array };
    }
};

const ObjectGenerator = struct {
    list: []std.json.Value,

    pub fn fromJson(allocator: std.mem.Allocator, json_value: std.json.Value) anyerror!ObjectGenerator {
        if (json_value.array.items.len > 0) {
            return ObjectGenerator{ .list = try allocator.dupe(std.json.Value, json_value.array.items) };
        }
        return error.EmptyArray;
    }

    pub fn generate(self: @This(), g: *Generator, ctx: *Context) anyerror!std.json.Value {
        var obj = std.json.ObjectMap.init(g.allocator());
        errdefer obj.deinit();
        for (self.list) |item| {
            if (item == .null) continue;
            if (item != .object) {
                return error.InvalidObjectMember;
            }

            const name = item.object.get("name") orelse return error.NoNameField;
            const val = item.object.get("val") orelse return error.NoValField;

            const resolved_name = try g.eval_json(ctx, name);
            const resolved_val = try g.eval_json(ctx, val);
            if (resolved_name != .string) {
                return error.FailedToResolveNameForObj;
            }
            try obj.put(resolved_name.string, resolved_val);
        }
        return std.json.Value{ .object = obj };
    }
};

const OptionGenerator = struct {
    val: std.json.Value,

    pub fn fromJson(value: std.json.Value) OptionGenerator {
        return OptionGenerator{ .val = value };
    }

    pub fn generate(self: @This(), g: *Generator, ctx: *Context) anyerror!std.json.Value {
        const resolved = try g.eval_json(ctx, self.val);

        const which = try g.eval_json(ctx, std.json.Value{ .string = "$bool" });
        if (which.bool) {
            return resolved;
        }
        return std.json.Value{ .null = {} };
    }
};
