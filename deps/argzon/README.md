# argzon

## Command-line argument parsing library using ZON.

### Usage

1. Add `argzon` dependency to `build.zig.zon`:

```sh
zig fetch --save git+https://codeberg.org/tensorush/argzon.git
```

2. Use `argzon` dependency in `build.zig`:

```zig
const argzon_dep = b.dependency("argzon", .{
    .target = target,
    .optimize = optimize,
});
const argzon_mod = argzon_dep.module("argzon");

const root_mod = b.createModule(.{
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "argzon", .module = argzon_mod },
    },
});
```
