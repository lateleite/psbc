# psbc

psbc is a SPIR-V to PlayStation's Shader Binary compiler, built on top of Mesa.

**CAVEATS:**

- This has only been tested on a couple shaders so far, under a base PS4. Bugs and missing features are sure to be found within;
- Only Vertex and Pixel/Fragment shaders are supported;
- All resources must use descriptor set at index 0;
- Resources must be laid out in memory as a descriptor table;
- Shader reflection information is missing, along with some other Shader binary metadata;
- Shaders build with this probably won't work with emulators that depend on Shader Binary metadata to be present and correct;
- While you can build this as a library, it may not work well since Mesa's code may handle errors by aborting programs.

## Building as a standalone tool

With Zig 0.17.0-dev, run in your command line

```bash
zig build --release=fast
```

If successful, you will have your compiler at `zig-out/bin/psbc`.

## Building as a Zig Build package

Run in your Zig project:
```sh
zig fetch --save git+https://github.com/lateleite/psbc.git
```

Then in your `build.zig` file:
```zig
pub fn build(b: *std.Build) void {
    // ...

    // Get your system's native target, so the compiler can be used
    const native_target = b.graph.host;

    // Fetch it from your dependency list...
    const dep_psbc = b.dependency("psbc", .{
        .target = native_target,
        .optimize = .fast,
    });
    const exe_psbc = dep_psbc.artifact("psbc");

    // Then run it with any SPIR-V files you want
    const psb_cmd = b.addRunFile(exe_psbc.getEmittedBin());
    psb_cmd.addArgs(&.{ "-s", "vertex" });
    psb_cmd.addFileArg(b.path("my_vertex_shader.spv"));

    const sb_file = psb_cmd.addOutputFileArg2("my_vertex_shader.sb", .{});
    // `sb_file` is your final PlayStation Shader Binary.
    // Use it anywhere you want.

    // ...
}
```

## Usage example

To build a vertex shader:

```sh
psbc -s vertex ./input_vertex.spv ./output_vertex.sb 
```

To build a vertex shader:

```sh
psbc -s fragment ./input_frag.spv ./output_frag.sb 
```

## License

Most of this project's code is from Mesa, licensed under the MIT license. You may find more information in their respective source files.

Any other original `psbc` source files are also released under the MIT license, see [LICENSE](LICENSE) for more information.
