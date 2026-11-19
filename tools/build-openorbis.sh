#!/usr/bin/env bash
# WinePS4 Enhanced: rebuild the OpenOrbis PS4 toolchain that ps4-kit expects at /opt/pacbrew/ps4/openorbis,
# from source, following PacBrew's recipes (github.com/PacBrew/ps4-openorbis, PKGBUILDs) with the same pinned
# commits. Every source is fetched with git (no release downloads), so it runs where only git access to GitHub
# works (Claude Code cloud sessions).
#
# Differences from PacBrew, on purpose:
#   - the host's clang 21 (apt.llvm.org) instead of PacBrew's own clang 12.0.1 build: ps4-kit compiles with
#     clang 21 anyway (toolchain/env.sh CLANG_VER=21); clang 21 knows the x86_64-scei-ps4 triple;
#   - compiler-rt builtins and libunwind from LLVM 21.1.6 (the libc++ version ps4-kit builds) instead of 12.0.1.
#
#   tools/build-openorbis.sh [step...]     steps: fetch headers musl llvmrt fself vars libs pkgtool (default: all)
set -euo pipefail
OO="${OPENORBIS:-/opt/pacbrew/ps4/openorbis}"
SRC="${OO_SRC:-$HOME/oo-src}"
PACBREW_RECIPES="${PACBREW_RECIPES:-$SRC/ps4-openorbis}"
CLANG="${CLANG:-clang-21}"
LLVM_VER="${LLVM_VER:-21.1.6}"
JOBS="${JOBS:-$(nproc)}"
mkdir -p "$SRC" "$OO/bin/linux" "$OO/lib" "$OO/usr/lib" "$OO/usr/include" "$OO/cmake" "$OO/usr/bin"

# fetch <dir> <url> <commit or tag>: a shallow checkout of exactly that revision
fetch() {
    local dir="$SRC/$1" url="$2" rev="$3"
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$(git -C "$dir" rev-parse "$rev^{commit}" 2>/dev/null)" ]; then return; fi
    rm -rf "$dir"; git init -q "$dir"; git -C "$dir" remote add origin "$url"
    GIT_LFS_SKIP_SMUDGE=1 git -C "$dir" fetch -q --depth 1 origin "$rev"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    echo "fetched $1 at $(git -C "$dir" rev-parse --short HEAD)"
}

step_fetch() {
    fetch ps4-openorbis   https://github.com/PacBrew/ps4-openorbis.git            16f27e38760ea21eaf1187d0edbf4342c4a44021
    fetch headers         https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain.git cd480230b946239f758333ef0dff40d67c5f0c20
    fetch musl            https://github.com/PacBrew/ps4-openorbis-musl.git       140a653299ffcb1457bc63a5ab1f507d7bb37c54
    # create-fself: not PacBrew's 30d2e10 (2021), which writes the data PT_LOAD twice when .data.rel.ro is large
    # (the console refuses the eboot, CE-41839-5; ps4-kit.cmake and check-oelf.cmake): OpenOrbis fixed it in d35679f
    fetch create-fself    https://github.com/OpenOrbis/create-fself.git           f2da6229684ce320f673c06fceac9c218f621788
    fetch create-gp4      https://github.com/OpenOrbis/create-gp4.git             bf8e66e9e9bdd92e41e1697893bc8098a151fa24
    fetch liborbispkg     https://github.com/OpenOrbis/LibOrbisPkg.git            594021fdc435409f755a6ae0781b65ec6cec846c
}

# headers (PacBrew ps4-openorbis-headers 0.5.2): include/, link.x, samples/, lib/crtlib.o
step_headers() {
    local h="$SRC/headers"
    cp -r "$h/include" "$OO/"
    cp -r "$h/samples" "$OO/"
    install -m644 "$h/link.x" "$OO/link.x"
    "$CLANG" --target=x86_64-pc-freebsd12-elf -fPIC -isystem "$OO/include" -c -o "$OO/lib/crtlib.o" "$h/src/crt/crtlib.c"
    echo "headers: include, samples, link.x, crtlib.o"
}

# musl (PacBrew ps4-openorbis-musl 1.5): libc.a, crt1.o, crti.o, crtn.o, the C headers
step_musl() {
    cd "$SRC/musl"
    make distclean >/dev/null 2>&1 || true
    ./configure --target=x86_64-scei-ps4 --prefix="$OO" --disable-shared \
        CC="$CLANG" CFLAGS="--target=x86_64-scei-ps4 -fPIC -DPS4 -D_LIBUNWIND_IS_BAREMETAL=1 -DPS4_FLEXIBLE_MEMORY=1" > "$SRC/musl-configure.log" 2>&1
    make --quiet -j"$JOBS" > "$SRC/musl-build.log" 2>&1
    make install > "$SRC/musl-install.log" 2>&1
    ls -la "$OO/lib/libc.a" "$OO/lib/crt1.o"
}

# create-fself (PacBrew 1.2, OpenOrbis 30d2e10), built with Go 1.17.5 as PacBrew does
step_fself() {
    local go="$SRC/go1.17.5"
    if [ ! -x "$go/bin/go" ]; then
        mkdir -p "$go.tmp" && curl -sSfL https://go.dev/dl/go1.17.5.linux-amd64.tar.gz | tar -xz -C "$go.tmp"
        mv "$go.tmp/go" "$go" && rmdir "$go.tmp"
    fi
    cd "$SRC/create-fself/cmd/create-fself"
    GOPATH="$SRC/gopath" GOFLAGS=-mod=mod "$go/bin/go" build -o create-fself -modfile=go-linux.mod
    install -m755 create-fself "$OO/bin/create-fself"
    ln -sf ../create-fself "$OO/bin/linux/create-fself"
    # create-gp4 (PacBrew 1.0, OpenOrbis bf8e66e): the package layout file PkgTool builds from
    cd "$SRC/create-gp4/cmd/create-gp4"
    GOPATH="$SRC/gopath" GOFLAGS=-mod=mod "$go/bin/go" build -o create-gp4
    install -m755 create-gp4 "$OO/bin/create-gp4"
    ln -sf ../create-gp4 "$OO/bin/linux/create-gp4"
    echo "create-fself, create-gp4 built"
}

# vars (PacBrew ps4-openorbis-vars 1.1): ps4vars.sh, cmake/ps4.cmake, usr/bin/openorbis-cmake
step_vars() {
    local v="$SRC/ps4-openorbis/vars"
    install -m644 "$v/ps4vars.sh" "$OO/ps4vars.sh"
    install -m644 "$v/ps4.cmake" "$OO/cmake/ps4.cmake"
    install -m755 "$v/openorbis-cmake" "$OO/usr/bin/openorbis-cmake"
    echo "vars installed"
}

# libs (PacBrew ps4-openorbis-orbis-lib-gen 1.3): the system libraries' link stubs (libkernel.so,
# libSceVideoOut.so, ...). PacBrew takes OpenOrbis' prebuilt lib.tar.gz (a release download); here they are made
# with OpenOrbis' own generator (orbis-lib-gen) from the ps4libdoc symbol tables (firmware 9.00), each stub a
# shared object whose functions only carry the names create-fself turns into imports. Plus PacBrew's stripped
# libSceLibcInternal.so (no malloc: musl's wrappers get those).
PS4LIBDOC_BRANCH="${PS4LIBDOC_BRANCH:-9.00}"
step_libs() {
    fetch orbis-lib-gen  https://github.com/OpenOrbis/orbis-lib-gen.git 8443a656ba40a6c6212ac2e03164019d78268131
    fetch ps4libdoc      https://github.com/idc/ps4libdoc.git            "${PS4LIBDOC_COMMIT:-a71315e7f36e312ae71e9e3a92982e9ffbfc725f}"  # (branch 9.00)
    local g="$SRC/orbis-lib-gen" n=0 f
    rm -rf "$g/build"; mkdir -p "$g/build/out"
    (cd "$g" && python3 generate.py "$SRC/ps4libdoc/system/common/lib" > "$SRC/libgen.log" 2>&1)
    for f in "$g"/build/*.c; do
        local name; name="$(basename "$f" .c)"
        # (as assembly, not the generator's C: clang refuses C definitions of its builtins, __atomic_* and the like)
        sed -nE 's/^void ([A-Za-z0-9_$.@]+)\(\) \{ for\(;;\)\{\} \}$/\1/p' "$f" |
            awk '{ printf ".globl \"%s\"\n.type \"%s\", @function\n\"%s\":\n\tret\n", $1, $1, $1 }' > "$g/build/$name.S"
        "$CLANG" --target=x86_64-pc-freebsd12-elf -fPIC -c "$g/build/$name.S" -o "$g/build/$name.o"
        "$CLANG" --target=x86_64-pc-freebsd12-elf -fuse-ld=lld -shared -nostdlib "$g/build/$name.o" -o "$g/build/out/$name.so"
        n=$((n + 1))
    done
    # (not libc.so: -lc must find musl's libc.a, the C library the toolchain links)
    rm -f "$g/build/out/libc.so"
    cp "$g"/build/out/*.so "$OO/lib/"
    install -m644 "$SRC/ps4-openorbis/orbis-lib-gen/libSceLibcInternal.so" "$OO/lib/libSceLibcInternal.so"
    echo "libs: $n stub libraries"
}

# llvmrt (PacBrew ps4-openorbis-libcxx's compiler-rt and libunwind parts): libclang_rt.builtins-x86_64.a and
# libunwind.a, from LLVM $LLVM_VER (git tag, only the subtrees needed)
step_llvmrt() {
    local l="$SRC/llvm-project-$LLVM_VER"
    if [ ! -d "$l/compiler-rt" ]; then
        rm -rf "$l"; git init -q "$l"; git -C "$l" remote add origin https://github.com/llvm/llvm-project.git
        git -C "$l" sparse-checkout set --no-cone /compiler-rt /libunwind /libcxx /libcxxabi /libc /runtimes /cmake \
            /llvm/cmake /llvm/utils/lit /llvm/utils/llvm-lit /third-party
        git -C "$l" fetch -q --depth 1 origin "refs/tags/llvmorg-$LLVM_VER"
        git -C "$l" -c advice.detachedHead=false checkout -q FETCH_HEAD
    fi
    local flags="--target=x86_64-scei-ps4 -fPIC -D__PS4__ -D_LIBUNWIND_IS_BAREMETAL=1 -isystem $OO/include"
    local b="$SRC/build-builtins"; rm -rf "$b"
    cmake -S "$l/compiler-rt/lib/builtins" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$CLANG" -DCMAKE_ASM_COMPILER="$CLANG" -DCMAKE_C_FLAGS="$flags" -DCMAKE_ASM_FLAGS="$flags" \
        -DCMAKE_C_COMPILER_TARGET=x86_64-scei-ps4 -DCMAKE_ASM_COMPILER_TARGET=x86_64-scei-ps4 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCOMPILER_RT_BAREMETAL_BUILD=ON \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BUILTINS_ENABLE_PIC=ON \
        -DLLVM_CMAKE_DIR="$l/llvm/cmake/modules" > "$SRC/builtins-configure.log" 2>&1
    ninja -C "$b" > "$SRC/builtins-build.log" 2>&1
    install -m644 "$(find "$b" -name 'libclang_rt.builtins*.a' | head -1)" "$OO/lib/libclang_rt.builtins-x86_64.a"
    b="$SRC/build-libunwind"; rm -rf "$b"
    cmake -S "$l/runtimes" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_RUNTIMES=libunwind \
        -DCMAKE_C_COMPILER="$CLANG" -DCMAKE_CXX_COMPILER="${CLANG/clang/clang++}" -DCMAKE_ASM_COMPILER="$CLANG" \
        -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" -DCMAKE_ASM_FLAGS="$flags" \
        -DCMAKE_C_COMPILER_TARGET=x86_64-scei-ps4 -DCMAKE_CXX_COMPILER_TARGET=x86_64-scei-ps4 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLIBUNWIND_USE_COMPILER_RT=ON -DLIBUNWIND_IS_BAREMETAL=ON -DLIBUNWIND_INCLUDE_TESTS=OFF \
        -DLIBUNWIND_ENABLE_THREADS=OFF > "$SRC/libunwind-configure.log" 2>&1
    ninja -C "$b" unwind_static > "$SRC/libunwind-build.log" 2>&1
    install -m644 "$(find "$b" -name 'libunwind.a' | head -1)" "$OO/lib/libunwind.a"
    ls -la "$OO/lib/libclang_rt.builtins-x86_64.a" "$OO/lib/libunwind.a"
}

# bin (PacBrew ps4-openorbis-clang's place): clang, ld.lld and the LLVM tools in $OO/bin, as links to the
# host's LLVM 21 (PacBrew's cmake/ps4.cmake and ps4vars.sh call them there)
step_bin() {
    local t
    for t in clang clang++ ld.lld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-readelf; do
        ln -sfn "$(command -v "$t-${CLANG##*-}")" "$OO/bin/$t"
    done
    ls "$OO/bin"
}

# pkgtool (PacBrew ps4-openorbis-pkgtools 0.2.231: LibOrbisPkg 594021f's PkgTool.Core) with ps4-kit's three fixes
# (scripts/build-pkgtool.sh at ps4-kit HEAD: PlayGo chunk hash slack past ~4 GB, PKG_EXTRA_CONTENT_FLAGS, PFSC
# inflate loop), on the .NET 8 SDK (Ubuntu's dotnet-sdk-8.0) instead of .NET 6, into $OO/bin/linux/pkgtool and
# PacBrew's PkgTool.Core wrapper
step_pkgtool() {
    command -v dotnet >/dev/null || { echo "no dotnet: apt-get install dotnet-sdk-8.0" >&2; return 1; }
    cd "$SRC/liborbispkg"
    git checkout -q -- .
    sed -i 's|e.DataSize = (uint)(pkgSize / 0x10000L) \* 4;|e.DataSize = (uint)(pkgSize / 0x10000L) * 4 + 0x10000;  // slack: the estimate fell short for a 4 GB image|' \
        LibOrbisPkg/PKG/PkgBuilder.cs
    sed -i 's|content_flags = ContentFlags.Unk_x8000000 \| VolTypeToContentFlags(volType),|content_flags = ContentFlags.Unk_x8000000 \| VolTypeToContentFlags(volType) \| (ContentFlags)System.Convert.ToUInt32(System.Environment.GetEnvironmentVariable("PKG_EXTRA_CONTENT_FLAGS") ?? "0", 16),|' \
        LibOrbisPkg/PKG/PkgBuilder.cs
    sed -i 's|          ds.Read(output, 0, hdr.BlockSz);|          for (int got = 0, n; got < hdr.BlockSz \&\& (n = ds.Read(output, got, hdr.BlockSz - got)) > 0; got += n) { }  // DeflateStream may return a partial block|' \
        LibOrbisPkg/PFS/PFSCReader.cs
    grep -q "slack: the estimate" LibOrbisPkg/PKG/PkgBuilder.cs && grep -q PKG_EXTRA_CONTENT_FLAGS LibOrbisPkg/PKG/PkgBuilder.cs &&
        grep -q "may return a partial block" LibOrbisPkg/PFS/PFSCReader.cs || { echo "pkgtool: a fix did not apply" >&2; return 1; }
    sed -i 's|<TargetFramework>net6.0</TargetFramework>|<TargetFramework>net8.0</TargetFramework>|' \
        PkgTool.Core/PkgTool.Core.csproj LibOrbisPkg.Core/LibOrbisPkg.Core.csproj
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 DOTNET_NOLOGO=1 \
        dotnet publish PkgTool.Core/PkgTool.Core.csproj -r linux-x64 --self-contained false -c Release \
        -o "$OO/bin/linux/pkgtool" > "$SRC/pkgtool-build.log" 2>&1
    install -m755 "$SRC/ps4-openorbis/pkgtools/PkgTool.Core" "$OO/bin/linux/PkgTool.Core"
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 "$OO/bin/linux/PkgTool.Core" 2>&1 | head -3
}

STEPS=("$@"); [ ${#STEPS[@]} -gt 0 ] || STEPS=(fetch bin headers musl fself vars libs llvmrt pkgtool)
for s in "${STEPS[@]}"; do echo "--- $s"; "step_$s"; done
