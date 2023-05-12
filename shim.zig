const std = @import("std");
const StackOrPageBuffer = @import("allocator.zig").StackOrPageBuffer;
const SimpleBumpAllocator = @import("allocator.zig").SimpleBumpAllocator;

pub const Payload = extern struct {
    exec: [*:0]const u8,
    argc_pre: usize,
    argv_pre: [*]const [*:0]const u8,
};

const payload = Payload{
    .exec = "/bin/echo",
    .argc_pre = 1,
    .argv_pre = &[_][*:0]const u8{"Hello"},
};

fn main() u8 {
    const new_argc = payload.argc_pre + std.os.argv.len;
    const buffer_size = (new_argc + 1) * @sizeOf([*]void);

    const STACK_BUFFER_SIZE: usize = 32768;
    var buffer = StackOrPageBuffer(STACK_BUFFER_SIZE).init(buffer_size) catch {
        return 1;
    };
    // memory will be reclaimed by OS on execve or exit.
    // defer buffer.deinit();
    var allocator = SimpleBumpAllocator.init(buffer.get());

    var new_argv = allocator.allocSentinel(?[*:0]const u8, new_argc, null) catch {
        return 1;
    };
    new_argv[0] = payload.exec;
    std.mem.copy(?[*:0]const u8, new_argv[1..], payload.argv_pre[0..payload.argc_pre]);
    std.mem.copy(?[*:0]const u8, new_argv[1 + payload.argc_pre ..], std.os.argv[1..]);

    const envp = [_:null]?[*:0]const u8{};
    switch (std.os.linux.getErrno(std.os.linux.execve(payload.exec, new_argv, &envp))) {
        .SUCCESS => {},
        else => {
            const msg = "execve failed\n";
            _ = std.os.linux.write(std.os.linux.STDERR_FILENO, msg, msg.len);
        },
    }
    return 1;
}

//////////////////////////////////////////////////////////////////////
// Shrunk version of Zig's std.start
//////////////////////////////////////////////////////////////////////

const builtin = @import("builtin");
const elf = std.elf;
const native_arch = builtin.cpu.arch;
const native_os = builtin.os.tag;

var argc_argv_ptr: [*]usize = undefined;

pub export fn _start() callconv(.Naked) noreturn {
    switch (builtin.zig_backend) {
        .stage2_c => {
            @export(argc_argv_ptr, .{ .name = "argc_argv_ptr" });
            @export(posixCallMainAndExit, .{ .name = "_posixCallMainAndExit" });
            switch (native_arch) {
                .x86_64 => asm volatile (
                    \\ xorl %%ebp, %%ebp
                    \\ movq %%rsp, argc_argv_ptr
                    \\ andq $-16, %%rsp
                    \\ call _posixCallMainAndExit
                ),
                .i386 => asm volatile (
                    \\ xorl %%ebp, %%ebp
                    \\ movl %%esp, argc_argv_ptr
                    \\ andl $-16, %%esp
                    \\ jmp _posixCallMainAndExit
                ),
                .aarch64, .aarch64_be => asm volatile (
                    \\ mov fp, #0
                    \\ mov lr, #0
                    \\ mov x0, sp
                    \\ adrp x1, argc_argv_ptr
                    \\ str x0, [x1, :lo12:argc_argv_ptr]
                    \\ b _posixCallMainAndExit
                ),
                .arm, .armeb, .thumb => asm volatile (
                    \\ mov fp, #0
                    \\ mov lr, #0
                    \\ str sp, argc_argv_ptr
                    \\ and sp, #-16
                    \\ b _posixCallMainAndExit
                ),
                else => @compileError("unsupported arch"),
            }
            unreachable;
        },
        else => switch (native_arch) {
            .x86_64 => {
                argc_argv_ptr = asm volatile (
                    \\ xor %%ebp, %%ebp
                    : [argc] "={rsp}" (-> [*]usize),
                );
            },
            .i386 => {
                argc_argv_ptr = asm volatile (
                    \\ xor %%ebp, %%ebp
                    : [argc] "={esp}" (-> [*]usize),
                );
            },
            .aarch64, .aarch64_be, .arm, .armeb, .thumb => {
                argc_argv_ptr = asm volatile (
                    \\ mov fp, #0
                    \\ mov lr, #0
                    : [argc] "={sp}" (-> [*]usize),
                );
            },
            .riscv64 => {
                argc_argv_ptr = asm volatile (
                    \\ li s0, 0
                    \\ li ra, 0
                    : [argc] "={sp}" (-> [*]usize),
                );
            },
            .mips, .mipsel => {
                // The lr is already zeroed on entry, as specified by the ABI.
                argc_argv_ptr = asm volatile (
                    \\ move $fp, $0
                    : [argc] "={sp}" (-> [*]usize),
                );
            },
            .powerpc => {
                // Setup the initial stack frame and clear the back chain pointer.
                argc_argv_ptr = asm volatile (
                    \\ mr 4, 1
                    \\ li 0, 0
                    \\ stwu 1,-16(1)
                    \\ stw 0, 0(1)
                    \\ mtlr 0
                    : [argc] "={r4}" (-> [*]usize),
                    :
                    : "r0"
                );
            },
            .powerpc64le => {
                // Setup the initial stack frame and clear the back chain pointer.
                // TODO: Support powerpc64 (big endian) on ELFv2.
                argc_argv_ptr = asm volatile (
                    \\ mr 4, 1
                    \\ li 0, 0
                    \\ stdu 0, -32(1)
                    \\ mtlr 0
                    : [argc] "={r4}" (-> [*]usize),
                    :
                    : "r0"
                );
            },
            .sparc64 => {
                // argc is stored after a register window (16 registers) plus stack bias
                argc_argv_ptr = asm (
                    \\ mov %%g0, %%i6
                    \\ add %%o6, 2175, %[argc]
                    : [argc] "=r" (-> [*]usize),
                );
            },
            else => @compileError("unsupported arch"),
        },
    }
    // If LLVM inlines stack variables into _start, they will overwrite
    // the command line argument data.
    @call(.{ .modifier = .never_inline }, posixCallMainAndExit, .{});
}

fn posixCallMainAndExit() callconv(.C) noreturn {
    @setAlignStack(16);

    const argc = argc_argv_ptr[0];
    const argv = @ptrCast([*][*:0]u8, argc_argv_ptr + 1);

    const envp_optional = @ptrCast([*:null]?[*:0]u8, @alignCast(@alignOf(usize), argv + argc + 1));
    var envp_count: usize = 0;
    while (envp_optional[envp_count]) |_| : (envp_count += 1) {}
    const envp = @ptrCast([*][*:0]u8, envp_optional)[0..envp_count];

    if (native_os == .linux) {
        // Find the beginning of the auxiliary vector
        const auxv = @ptrCast([*]elf.Auxv, @alignCast(@alignOf(usize), envp.ptr + envp_count + 1));
        std.os.linux.elf_aux_maybe = auxv;

        if (builtin.position_independent_executable) {
            // We disable Zig's standard support for PIE.
            // std.os.linux.pie.relocate(phdrs);
            @compileError("Cannot be built as position independent executable.");
        }

        // This minimal binary only supports single threaded execution and
        // supports no thread local storage.
        // So, we disable TLS initialization of Zig's default start function.
        // std.os.linux.tls.initStaticTLS(phdrs);

        // The way Linux executables represent stack size is via the PT_GNU_STACK
        // program header. However the kernel does not recognize it; it always gives 8 MiB.
        // For a minimal binary like this that is sufficient stack size, so we
        // skip the stack expansion of Zig's builtin start function.
        // expandStackSize(phdrs);
    }

    std.os.exit(@call(.{ .modifier = .always_inline }, callMainWithArgs, .{ argc, argv, envp }));
}

// We disable Zig's default segfault handler to produce a minimal binary.
pub const enable_segfault_handler = false;

inline fn callMainWithArgs(argc: usize, argv: [*][*:0]u8, envp: [][*:0]u8) u8 {
    std.os.argv = argv[0..argc];
    std.os.environ = envp;

    // We disable Zig's default segfault handler to produce a minimal binary.
    // std.debug.maybeEnableSegfaultHandler();

    // We don't use an event loop in this minimal binary, so we skip event loop
    // initialization of Zig's default start function.
    // return initEventLoopAndCallMain();

    // This is marked inline because for some reason LLVM in release mode fails to inline it,
    // and we want fewer call frames in stack traces.
    return @call(.{ .modifier = .always_inline }, callMain, .{});
}

// This is not marked inline because it is called with @asyncCall when
// there is an event loop.
pub fn callMain() u8 {
    switch (@typeInfo(@typeInfo(@TypeOf(main)).Fn.return_type.?)) {
        .NoReturn => {
            main();
        },
        .Void => {
            main();
            return 0;
        },
        .Int => |info| {
            if (info.bits != 8 or info.signedness == .signed) {
                @compileError(bad_main_ret);
            }
            return main();
        },
        .ErrorUnion => {
            const result = main() catch |err| {
                std.log.err("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                return 1;
            };
            switch (@typeInfo(@TypeOf(result))) {
                .Void => return 0,
                .Int => |info| {
                    if (info.bits != 8 or info.signedness == .signed) {
                        @compileError(bad_main_ret);
                    }
                    return result;
                },
                else => @compileError(bad_main_ret),
            }
        },
        else => @compileError(bad_main_ret),
    }
}

// General error message for a malformed return type
const bad_main_ret = "expected return type of main to be 'void', '!void', 'noreturn', 'u8', or '!u8'";

// Disable Zig's default panic handler
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = ret_addr;
    while (true) {
        @breakpoint();
    }
}
