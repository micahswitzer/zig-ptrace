> NOTE: This library is still a work-in-progress, many functions are missing
and incomplete. The API will probably change significantly before the first
stable release.

# zig-ptrace

`zig-ptrace` is a combination [ptrace][1] wrapper library, and high-level
process and thread-tracing library.

## Usage

Clone or copy `zig-ptrace` into a `deps` folder in your source tree and then
add the following code to your `build.zig`:

```zig
const zig_ptrace = std.build.Pkg{
    .name = "ptrace",
    .path = .{ .path = "deps/zig-ptrace/src/main.zig" },
};

exe.addPackage(zig_ptrace);
```

Then import it in your source files like this:

```zig
// for the low-level API
const ptrace = @import("ptrace").PTRACE;

// for the high-level API
const hl = @import("ptrace");
```

## Low-level API

This should be nearly one-to-one with the C API. Constants are namespaced in
place of using underscores (e.g. `PTRACE.O.TRACECLONE` instead of
`PTRACE_O_TRACECLONE`). Each function only returns errors that are relevant to
that specific operation. Note that some operations are only available on
specific architectures. If you need to be able to compile programs consuming
this library for a broad range of architectures, consider using the high-level
API. Otherwise, you can gate the use of platform-specific functions using
`@hasDecl()`:

```zig
const ptrace = @import("ptrace").PTRACE;

if (@hasDecl(ptrace, "getRegs")) {
    const regs = try ptrace.getRegs(pid);
} else {
    // use a platform-independent function
    try ptrace.getRegSet(pid, ...);
}
```

## High-level API

> TODO: The high-level API is not anywhere close to being finalized. I'll start
writing this section when I have a better idea of how I want it to work. For
now see `src/highlevel.zig`.

# What's ptrace?

The ptrace (process trace) API allows a "tracer" process to attach to and
control a "tracee" process. The tracer can pause the tracee, observe and
manipulate its registers, memory, system calls, and signals, and then resume
the tracee. This can be used to implement a debugger, a system call tracer,
dynamic code patching, and many other things. It's an incredibly powerful API!

# References

* [PTRACE(2)][1]


[1]: https://man7.org/linux/man-pages/man2/ptrace.2.html
