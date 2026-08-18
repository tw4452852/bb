# bb
An universal BPF Builder

## Motivation
Modern [e]BPF development setup has become complex, due to the following factors:

- You need to install clang compiler. It is usually a part of LLVM package which is very huge.
- You need to either install [libbpf](https://docs.kernel.org/bpf/libbpf/libbpf_overview.html) or compile it yourself.
- You need to install bpftool which seems to be optional, but virtually all the program need it to generate both a [skeleton](https://libbpf.readthedocs.io/en/latest/libbpf_overview.html#bpf-object-skeleton-file) and a [vmlinux.h](https://libbpf.readthedocs.io/en/latest/libbpf_overview.html#bpf-co-re-compile-once-run-everywhere).
- Want to cross-compilation? Damn, you still need a cross-compiler.
- You need a Makefile to assembly all the above to build the finally binary, here is [an example](https://github.com/libbpf/libbpf-bootstrap/blob/master/examples/c/Makefile).

As you can see, a lot of dependencies you need to prepare and steps you have to follow, can we just use only one tool to rule them all?
The answer is obsolutely yes. This is where `bb` (BPF Builder) comes into play. It will simplify the process significantly.

## How to use

You only need to

1. Download the [Zig toolchain](https://ziglang.org/learn/getting-started/).
2. Clone this repository.

Then, you're good to go.

To compile: `zig build -Dbpf=<path/to/your/bpf_program.c> -Duser=<path/to/your/userspace_program.c>`, then all you need is under `./zig-out`:

```
zig-out/
├── bin
│   ├── bootstrap <= User-space program
│   └── bpftool
├── include
│   └── bootstrap.skel.h
└── obj
    └── bootstrap.bpf.o <= BPF program
```

And to cross-compile: Append `-Dtarget=<arch>-<os>-<libc>` (Use `zig targets` to find out all the supported combinations).

BTW, `-Dbpf` and `-Duser` can be specified multiple time to support multiple C files.

## Bonus

- The first time you run `zig build`, all the prerequsites' source codes will be downloaded under `zig-pkg` directory, then you can build offline from now on. You could even transfer the whole directory to another machine to build there without network.

- `-Dbpf` can be used alone without `-Duser`, then it will only compile BPF program.

- Similarly `-Duser` can also be used alone to build a userspace program (but the generated binary will contain libbpf anyway).

Have fun!
