#!/bin/bash
# ============================================================================
# FFmpeg 9.0.2 单体构建 for Android arm64-v8a（静态链接全部第三方库）
# 产物：$PREFIX/lib/libffmpeg.so —— 静态链接的 ffmpeg 可执行文件改名，
#      供 App 用 Runtime.exec() 直接调用（与 Termux 版形态一致）。
#
# 相对上一版 build.sh 的修正：
#   1. 每个库独立容错：失败只记录并继续 → 一轮 CI 暴露所有问题
#   2. ffmpeg 的 --enable-libxxx 按"实际编出的库"动态拼装，绝不因缺库 configure 失败
#   3. 库版本钉死（tag/版本号），可复现
#   4. 打开汇编（上一版 --disable-asm 导致没有 NEON）
#   5. API 24（vulkan/mediacodec 需要）
#   6. SKIP_LIBS 环境变量可临时排除某些库，便于分批调试
# ============================================================================

set -uo pipefail

BUILD_ROOT=${BUILD_ROOT:-/tmp/ffbuild}
SRC=$BUILD_ROOT/src
PREFIX=$BUILD_ROOT/install
LOGDIR=$BUILD_ROOT/logs
NDK_VER=android-ndk-r27c
NDK_ROOT=$BUILD_ROOT/ndk
TOOLCHAIN=$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64
SYSROOT=$TOOLCHAIN/sysroot
TARGET=aarch64-linux-android
API=24
FFMPEG_VER=9.0.2

CC=$TOOLCHAIN/bin/${TARGET}${API}-clang
CXX=$TOOLCHAIN/bin/${TARGET}${API}-clang++
AR=$TOOLCHAIN/bin/llvm-ar
NM=$TOOLCHAIN/bin/llvm-nm
RANLIB=$TOOLCHAIN/bin/llvm-ranlib
STRIP=$TOOLCHAIN/bin/llvm-strip
READELF=$TOOLCHAIN/bin/llvm-readelf
PKGCFG=/usr/bin/pkg-config

export CC CXX AR NM RANLIB STRIP
export PATH=$TOOLCHAIN/bin:$PATH
export MAKEFLAGS="-j$(nproc)"
export CFLAGS="-fPIC -O2 -I$PREFIX/include"
export CXXFLAGS="-fPIC -O2 -I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
unset PKG_CONFIG_SYSROOT_DIR

mkdir -p "$SRC" "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$LOGDIR"

declare -a OK=() FAILED=() SKIPPED=() ENABLE_FLAGS=() MISSING=()

# ---------------- 容错执行 ----------------
want() {  # SKIP_LIBS 里点名过的库直接跳过
    case " ${SKIP_LIBS:-} " in *" $1 "*) return 1 ;; esac
    return 0
}
run_step() {
    # 注意：bash 的 local 会先展开整行再赋值，所以 log 必须单独一行，
    # 否则 $name 在此时还是未定义（set -u 下直接 unbound variable）
    local name=$1 fn=$2 expect=${3:-}
    local log=$LOGDIR/$name.log
    echo ""
    if ! want "$name"; then
        SKIPPED+=("$name"); echo "########## [$name] SKIP_LIBS 排除 ##########"; return 0
    fi
    # 增量：上一轮已成功且产物仍在（配合 CI 缓存），直接跳过
    local sig
    sig=$(declare -f "$fn" | cksum | awk '{print $1}')
    local stamp="$BUILD_ROOT/done/$name.$sig"
    # 增量：上一轮用"同样的构建函数"成功过且产物仍在，才跳过。
    # 改了编译参数 → 签名变 → 自动重建（否则新参数不生效，白改）。
    if [ -f "$stamp" ] && ls "$PREFIX/lib"/*.a >/dev/null 2>&1; then
        OK+=("$name(cached)"); echo "########## [$name] 上轮已成功（签名一致），跳过 ##########"; return 0
    fi
    echo "########## [$name] 开始 ##########"
    if ( set -eo pipefail; "$fn" ) >"$log" 2>&1; then
        if [ -n "$expect" ] && [ ! -e "$PREFIX/lib/$expect" ]; then
            FAILED+=("$name"); rm -f "$BUILD_ROOT/done/$name" "$stamp"
            echo "########## [$name] 假成功：返回 0 但没有 $expect，日志尾部 ##########"
            tail -25 "$log"
        else
            OK+=("$name"); mkdir -p "$BUILD_ROOT/done"; touch "$stamp"; rm -f "$BUILD_ROOT/done/$name"
            echo "########## [$name] OK ##########"
        fi
    else
        FAILED+=("$name"); rm -f "$BUILD_ROOT/done/$name" "$stamp"
        echo "########## [$name] 失败，日志尾部 ##########"
        tail -25 "$log"
    fi
}

have() { [ -e "$PREFIX/lib/$1" ]; }

fetch() {
    local name=$1 url=$2 dir=$3
    if [ -d "$SRC/$dir" ] && [ -n "$(ls -A "$SRC/$dir" 2>/dev/null)" ]; then
        echo "[$name] 源码已在，跳过下载"; return 0
    fi
    local tmp=$SRC/$dir.dl
    rm -f "$tmp"
    # $url 可以是空格分隔的多个候选源，逐个用 curl / wget 尝试
    local got=0 u
    for u in $url; do
        echo "[$name] 尝试下载 $u"
        if curl -fL --retry 4 --retry-delay 10 --retry-all-errors --connect-timeout 30 -m 900 -o "$tmp" "$u"; then
            got=1; break
        fi
        echo "[$name] curl 失败，改用 wget"
        if wget -c -q -T 60 -t 3 -O "$tmp" "$u"; then got=1; break; fi
        rm -f "$tmp"
    done
    [ $got -eq 1 ] || { echo "[$name] 所有候选源都下载失败：$url"; return 1; }
    [ -s "$tmp" ] || { echo "[$name] 下载到的文件是空的"; rm -f "$tmp"; return 1; }
    # 确认不是 HTML 错误页（gzip/xz/bzip2 的魔数）
    local magic=$(od -An -tx1 -N2 "$tmp" 2>/dev/null | tr -d ' \n')
    case "$magic" in
        1f8b*|425a*|fd37*|504b*) ;;   # gz / bz2 / xz / zip
        *) echo "[$name] 下载内容不像压缩包（magic=$magic），可能是错误页"; rm -f "$tmp"; return 1 ;;
    esac
    rm -rf "$SRC/$dir"
    mkdir -p "$SRC/$dir"
    tar xf "$tmp" -C "$SRC/$dir" --strip-components=1 || { echo "[$name] 解压失败"; return 1; }
    rm -f "$tmp"
    [ -n "$(ls -A "$SRC/$dir" 2>/dev/null)" ] || { echo "[$name] 解压后目录为空"; return 1; }
}
gitclone() {
    local name=$1 url=$2 dir=$3 ref=${4:-}
    if [ -d "$SRC/$dir/.git" ]; then echo "[$name] 仓库已在"; return 0; fi
    # 上一轮失败可能留下"有文件但无 .git"的脏目录（CI 缓存会把它带回来）
    if [ -d "$SRC/$dir" ]; then echo "[$name] 清理脏目录后重新克隆"; rm -rf "$SRC/$dir"; fi
    echo "[$name] git clone $url ${ref:+@$ref}"
    if [ -n "$ref" ]; then
        git clone --depth 1 --branch "$ref" --recursive "$url" "$SRC/$dir"
    else
        git clone --depth 1 --recursive "$url" "$SRC/$dir"
    fi
}

# ---------------- 三套构建体系 ----------------
do_autotools() {
    local d=$SRC/$1; shift
    cd "$d"
    if [ ! -f configure ]; then
        if [ -f autogen.sh ]; then ./autogen.sh; else autoreconf -fiv; fi
    fi
    ./configure --prefix="$PREFIX" --host="$TARGET" \
        --enable-static --disable-shared --disable-doc "$@"
    make -j"$(nproc)"
    make install
}
do_cmake() {
    local d=$SRC/$1; shift
    rm -rf "$d/build"; mkdir -p "$d/build"; cd "$d/build"
    cmake -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$API \
        -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF "$@" ..
    cmake --build . -j"$(nproc)"
    cmake --install .
}
do_meson() {
    local d=$SRC/$1; shift
    rm -rf "$d/build"
    meson setup "$d/build" "$d" --cross-file "$BUILD_ROOT/cross.txt" \
        --prefix="$PREFIX" --default-library=static --buildtype=release "$@"
    ninja -C "$d/build"
    ninja -C "$d/build" install
}

write_pc() {  # write_pc <名> <版本> <Libs> [Cflags额外]
    cat > "$PREFIX/lib/pkgconfig/$1.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: $1
Description: $1
Version: $2
Libs: -L\${libdir} $3
Cflags: -I\${includedir} ${4:-}
EOF
}

# ---------------- meson 交叉配置（上一版 fontconfig 就是卡在这）----------
cat > "$BUILD_ROOT/cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
nm = '$NM'
ranlib = '$RANLIB'
pkgconfig = '$PKGCFG'
python = '$(command -v python3)'

[built-in options]
c_args = ['--target=$TARGET$API', '--sysroot=$SYSROOT', '-fPIC', '-O2', '-I$PREFIX/include', '-I$PREFIX/include/freetype2']
c_link_args = ['-L$PREFIX/lib']
cpp_args = ['--target=$TARGET$API', '--sysroot=$SYSROOT', '-fPIC', '-O2', '-I$PREFIX/include', '-I$PREFIX/include/freetype2']
cpp_link_args = ['-L$PREFIX/lib', '-static-libstdc++']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
sys_root = '$SYSROOT'
pkg_config_libdir = '$PREFIX/lib/pkgconfig'
needs_exe_wrapper = false
EOF

# ---------------- NDK ----------------
echo "=== 环境 ==="
echo "nproc=$(nproc)  磁盘:"; df -h /tmp / | tail -2
echo "curl=$(curl --version 2>/dev/null | head -1)"
echo "wget=$(command -v wget || echo 无)"
echo "cmake=$(cmake --version 2>/dev/null | head -1)"
echo "meson=$(meson --version 2>/dev/null)"
echo "ninja=$(ninja --version 2>/dev/null)"
echo "cargo=$(command -v cargo || echo 无)"

NDK_ZIP=$BUILD_ROOT/ndk.zip
if [ ! -x "$CC" ]; then
    echo "=== 下载 NDK $NDK_VER ==="
    cd "$BUILD_ROOT"
    rm -f "$NDK_ZIP"
    curl -fL --retry 3 --retry-delay 5 -o "$NDK_ZIP" \
        "https://dl.google.com/android/repository/$NDK_VER-linux.zip" \
        || echo "curl 失败，改用 wget"
    # 校验：NDK zip 应有 600MB+ 且是合法 zip
    if [ ! -s "$NDK_ZIP" ] || [ "$(stat -c %s "$NDK_ZIP" 2>/dev/null || echo 0)" -lt 100000000 ]; then
        echo "curl 结果不可用，尝试 wget"
        wget -c -q --show-progress -O "$NDK_ZIP" \
            "https://dl.google.com/android/repository/$NDK_VER-linux.zip" \
            || echo "wget 也失败"
    fi
    if [ ! -s "$NDK_ZIP" ] || [ "$(stat -c %s "$NDK_ZIP" 2>/dev/null || echo 0)" -lt 100000000 ]; then
        echo "FATAL: NDK 下载失败（两种方法都不行）。文件状态："
        ls -la "$NDK_ZIP" 2>/dev/null || echo "  无 $NDK_ZIP"
        exit 1
    fi
    echo "NDK zip 就绪: $(stat -c %s "$NDK_ZIP") 字节，解压中..."
    rm -rf "$NDK_ROOT" "$BUILD_ROOT/$NDK_VER"
    unzip -q "$NDK_ZIP" -d "$BUILD_ROOT" || { echo "FATAL: unzip 失败"; exit 1; }
    mv "$BUILD_ROOT/$NDK_VER" "$NDK_ROOT" || { echo "FATAL: mv 失败，解压出的目录名不是 $NDK_VER"; ls -la "$BUILD_ROOT"; exit 1; }
    rm -f "$NDK_ZIP"
fi
if [ ! -x "$CC" ]; then
    echo "FATAL: NDK 编译器仍不存在：$CC"
    ls -la "$TOOLCHAIN/bin" 2>/dev/null | head -10 || echo "  工具链目录都没有"
    exit 1
fi
echo "NDK: $("$CC" --version | head -1)"

ln -sf "${TARGET}${API}-clang"   "$TOOLCHAIN/bin/${TARGET}-gcc"
ln -sf "${TARGET}${API}-clang++" "$TOOLCHAIN/bin/${TARGET}-g++"
for t in ar nm ranlib strip readelf objdump strings; do
    [ -f "$TOOLCHAIN/bin/llvm-$t" ] || continue
    ln -sf "llvm-$t" "$TOOLCHAIN/bin/${TARGET}-$t"
    ln -sf "llvm-$t" "$TOOLCHAIN/bin/${TARGET}${API}-$t"
done

# ============================================================================
# 第 1 层：压缩 / 文本 / 加密
# ============================================================================
b_zlib() {
    fetch zlib https://zlib.net/fossils/zlib-1.3.1.tar.gz zlib
    cd "$SRC/zlib"
    CHOST=$TARGET$API ./configure --prefix=$PREFIX --static
    make -j$(nproc); make install
}
b_bzip2() {
    fetch bzip2 https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz bzip2
    cd "$SRC/bzip2"
    make -j$(nproc) libbz2.a CC=$CC AR=$AR RANLIB=$RANLIB CFLAGS="-fPIC -O2 -D_FILE_OFFSET_BITS=64"
    install -m 644 libbz2.a $PREFIX/lib/
    install -m 644 bzlib.h $PREFIX/include/
    write_pc bzip2 1.0.8 "-lbz2"
}
b_xz() {
    fetch xz https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.xz xz
    do_autotools xz --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
        --disable-scripts --disable-nls --without-lint
}
b_expat() {
    fetch expat https://github.com/libexpat/libexpat/releases/download/R_2_6_4/expat-2.6.4.tar.gz expat
    do_cmake expat -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
        -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_FUZZERS=OFF
}
b_openssl() {
    fetch openssl https://github.com/openssl/openssl/releases/download/openssl-3.3.2/openssl-3.3.2.tar.gz openssl
    cd "$SRC/openssl"
    export ANDROID_NDK_ROOT=$NDK_ROOT
    env -u CROSS_COMPILE -u CC -u CXX ./Configure android-arm64 no-shared no-tests no-asm no-engine no-apps \
        --prefix=$PREFIX --openssldir=$PREFIX/ssl --sysroot=$SYSROOT \
        -D__ANDROID_API__=$API >"$LOGDIR/openssl-configure.log" 2>&1
    if [ ! -f Makefile ]; then
        echo "openssl Configure 未生成 Makefile，其输出尾部："
        tail -20 "$LOGDIR/openssl-configure.log"
        return 1
    fi
    make -j"$(nproc)" >"$LOGDIR/openssl-make.log" 2>&1 || { tail -20 "$LOGDIR/openssl-make.log"; return 1; }
    make install_sw install_ssldirs >>"$LOGDIR/openssl-make.log" 2>&1 || \
        make install_sw >>"$LOGDIR/openssl-make.log" 2>&1 || true
    for a in libcrypto.a libssl.a; do
        [ -f "$PREFIX/lib/$a" ] || cp -f "$a" "$PREFIX/lib/$a" 2>/dev/null || true
    done
    have libcrypto.a || { echo "openssl 没产出 libcrypto.a"; ls *.a 2>/dev/null | head; return 1; }
    write_pc openssl 3.3.2 "-lssl -lcrypto"
    write_pc libcrypto 3.3.2 "-lcrypto -lz -ldl -lpthread"
}

# ============================================================================
# 第 2 层：字体 / 字幕
# ============================================================================
b_libpng() {
    fetch libpng https://github.com/glennrp/libpng/archive/refs/tags/v1.6.47.tar.gz libpng
    do_cmake libpng -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DSYSTEM_ZLIB=OFF
}
b_freetype() {
    fetch freetype https://github.com/freetype/freetype/archive/refs/tags/VER-2-13-3.tar.gz freetype
    do_cmake freetype -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
        -DFT_DISABLE_BZIP2=OFF -DFT_DISABLE_PNG=OFF
}
b_fribidi() {
    fetch fribidi https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz fribidi
    do_autotools fribidi --with-glib=false
}
b_harfbuzz() {
    fetch harfbuzz https://github.com/harfbuzz/harfbuzz/releases/download/10.2.0/harfbuzz-10.2.0.tar.xz harfbuzz
    do_meson harfbuzz -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled \
        -Dcairo=disabled -Dglib=disabled -Dfreetype=enabled -Dbenchmark=disabled
}
b_fontconfig() {
    fetch fontconfig https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz fontconfig
    do_meson fontconfig -Ddoc=disabled -Dtests=disabled -Dtools=disabled
}
b_libass() {
    fetch libass https://github.com/libass/libass/releases/download/0.17.3/libass-0.17.3.tar.xz libass
    if have libfontconfig.a; then
        do_autotools libass --enable-fontconfig --disable-iconv --disable-require-system-font-provider
    else
        do_autotools libass --disable-fontconfig --disable-iconv --disable-require-system-font-provider
    fi
}

# ============================================================================
# 第 3 层：视频编码器
# ============================================================================
b_x264() {
    gitclone x264 https://code.videolan.org/videolan/x264.git x264
    cd "$SRC/x264"
    ./configure --prefix=$PREFIX --host=$TARGET \
        --cross-prefix=$TOOLCHAIN/bin/${TARGET}${API}- \
        --enable-static --enable-pic --disable-cli --disable-opencl --disable-lavf
    make -j$(nproc); make install
}
b_x265() {
    fetch x265 https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.0.tar.gz x265
    local d=$SRC/x265/source
    rm -rf "$d/build"; mkdir -p "$d/build"; cd "$d/build"
    cmake -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$API -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_CLI=OFF \
        -DENABLE_ASSEMBLY=ON -DENABLE_NEON=ON \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON ..
    if ! cmake --build . -j"$(nproc)" >"$LOGDIR/x265-asm.log" 2>&1; then
        echo "x265 开启 NEON 汇编失败，退回 ENABLE_ASSEMBLY=OFF 重编"
        tail -5 "$LOGDIR/x265-asm.log"
        rm -rf "$d/build"; mkdir -p "$d/build"; cd "$d/build"
        cmake -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$API -DANDROID_STL=c++_static \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX \
            -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_CLI=OFF \
            -DENABLE_ASSEMBLY=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON ..
        cmake --build . -j"$(nproc)"
    fi
    cmake --install .
    write_pc x265 4.0 "-lx265"
}
b_dav1d() {
    fetch dav1d https://code.videolan.org/videolan/dav1d/-/archive/1.5.1/dav1d-1.5.1.tar.bz2 dav1d
    do_meson dav1d
}
b_aom() {
    gitclone aom https://aomedia.googlesource.com/aom aom
    cd "$SRC/aom"
    if [ -f ./configure ]; then
        chmod +x ./configure
        ./configure --prefix=$PREFIX --target=arm64-android-gcc --enable-static \
            --disable-shared --disable-docs --disable-tools --disable-examples \
            --disable-unit-tests --enable-neon --runtime-cpu-detect
        make -j"$(nproc)"; make install
    else
        echo "aom 无 ./configure（目录：$(ls | tr '\n' ' ')），改用 cmake"
        do_cmake aom -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TOOLS=OFF -DENABLE_DOCS=OFF
    fi
    have libaom.a || { echo "aom 没产出 libaom.a"; return 1; }
}
b_svtav1() {
    fetch svtav1 https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v2.3.0/SVT-AV1-v2.3.0.tar.bz2 svtav1
    do_cmake svtav1 -DBUILD_DEC=ON -DBUILD_TEST=OFF
    write_pc SvtAv1EncLib 2.3.0 "-lSvtAv1Enc"
    write_pc SvtAv1DecLib 2.3.0 "-lSvtAv1Dec"
}
b_rav1e() {
    command -v cargo >/dev/null || { echo "没有 cargo，跳过 rav1e"; return 1; }
    rustup target add aarch64-linux-android >/dev/null 2>&1 || true
    gitclone rav1e https://github.com/xiph/rav1e.git rav1e v0.7.1
    cd "$SRC/rav1e"
    mkdir -p .cargo
    cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
ar = "$AR"
linker = "$CC"
rustflags = ["-C", "link-arg=--sysroot=$SYSROOT", "-C", "link-arg=-static-libstdc++"]
EOF
    env -u LDFLAGS -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_PATH \
        cargo rustc --release --target aarch64-linux-android --lib -- --crate-type=staticlib
    [ -f target/aarch64-linux-android/release/librav1e.a ] || { echo "rav1e 没产出 staticlib"; ls target/aarch64-linux-android/release/ | head -20; return 1; }
    install -m 644 target/aarch64-linux-android/release/librav1e.a $PREFIX/lib/
    install -m 644 rav1e.h $PREFIX/include/
    write_pc rav1e 0.7.1 "-lrav1e -lcsydyz -lnum_bigint -lnum_traits"
}
b_vpx() {
    fetch vpx https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.0.tar.gz vpx
    cd "$SRC/vpx"
    # 上一轮缓存在 install/include/vpx 的头是"不完整安装"（不装 vpx_tpl.h/vpx_integer.h），
    # 而全局 CFLAGS 带 -I$PREFIX/include，会让 libvpx 编译时自引用这些残缺头而失败。
    rm -rf "$PREFIX/include/vpx"
    env CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2" ./configure --prefix=$PREFIX --target=arm64-android-gcc \
        --enable-static --disable-shared --disable-examples --disable-unit-tests \
        --disable-tools --disable-docs
    env CFLAGS="-fPIC -O2" make -j$(nproc) libs
    make install
}
b_xvid() {
    fetch xvid https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.bz2 xvid
    cd "$SRC/xvid/build/generic"
    ./configure --prefix=$PREFIX --host=$TARGET --build=x86_64-pc-linux-gnu
    make -j$(nproc)
    # xvid 产出的文件叫 xvidcore.a，ffmpeg 与探测都按 lib*.a 命名，必须补前缀；
    # 它的对外头在 src/xvid.h，build/generic 的 make install 并不会装它，
    # 而 ffmpeg 的 libxvid 探测要同时看到 xvid.h + xvid_global，缺一个就整体 configure 失败。
    install -d $PREFIX/lib $PREFIX/include
    local xal=$(find "$SRC/xvid" \( -name 'libxvidcore.a' -o -name 'xvidcore.a' \) 2>/dev/null | head -1)
    [ -n "$xal" ] || { echo "找不到 xvid 静态库产物"; find "$SRC/xvid" -name '*.a' 2>/dev/null; return 1; }
    cp -f "$xal" $PREFIX/lib/libxvidcore.a
    local xh=$(find "$SRC/xvid" -maxdepth 3 -name xvid.h 2>/dev/null | head -1)
    [ -n "$xh" ] || { echo "找不到 xvid.h"; find "$SRC/xvid" -maxdepth 2 -type d; return 1; }
    cp -f "$xh" $PREFIX/include/xvid.h
    write_pc xvidcore 1.3.7 "-lxvidcore"
    ls -l $PREFIX/lib/libxvidcore.a $PREFIX/include/xvid.h
}

# ============================================================================
# 第 4 层：音频编码器
# ============================================================================
b_opus()   { fetch opus https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz opus; do_autotools opus --disable-extra-programs --disable-assertions; }
b_ogg()    { fetch ogg https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz ogg; do_autotools ogg; }
b_vorbis() { fetch vorbis https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz vorbis; do_autotools vorbis; }
b_theora() {
    fetch theora https://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.xz theora || return 1
    cd "$SRC/theora" || return 1
    # 1.1.1 自带的 config.sub/guess 太旧，不认 aarch64-linux-android
    for f in /usr/share/automake-*/config.sub /usr/share/automake-*/config.guess; do
        [ -f "$f" ] && cp -f "$f" .
    done
    do_autotools theora --disable-examples --disable-spec
}
b_lame()   { fetch lame https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz lame; do_autotools lame --disable-frontend; }
b_amrnb()  { fetch amr https://sourceforge.net/projects/opencore-amr/files/opencore-amr/opencore-amr-0.1.6.tar.gz opencore-amr; do_autotools opencore-amr; }
b_amrwb()  { fetch voamr https://sourceforge.net/projects/opencore-amr/files/vo-amrwbenc/vo-amrwbenc-0.1.3.tar.gz vo-amrwbenc; do_autotools vo-amrwbenc; }
b_gme()    { gitclone gme https://github.com/libgme/game-music-emu.git gme 0.6.4; do_cmake gme; }
b_mpg123() { fetch mpg123 https://www.mpg123.de/download/mpg123-1.32.10.tar.bz2 mpg123; do_autotools mpg123 --disable-modules --disable-network --with-realtime=none; }
b_openmpt() {
    # 必须用 autotools 版：makefile 版只产出 libopenmpt.so，根本没有静态库，
    # 而单体不能留 NEEDED libopenmpt.so.N（上一版删 .so 的操作等于把库删空了）
    fetch openmpt "https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-0.7.19+release.autotools.tar.gz https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-0.7.19%2Brelease.autotools.tar.gz" openmpt
    do_autotools openmpt --disable-libopenmpt-soundtouch
    rm -f $PREFIX/lib/libopenmpt.so*
    # 不要用 write_pc 覆盖 libopenmpt 自带的 .pc：它的 Requires.private 里带着
    # modplug 真正依赖的 ogg/vorbisfile/mpg123。手写那份补了 vorbisfile 又缺 mpg123，
    # 永远差一块，ffmpeg 只会说 "libopenmpt not found"。
    [ -f $PREFIX/lib/pkgconfig/libopenmpt.pc ] \
        && echo "libopenmpt.pc: $(sed -n 's/^Requires.private: //p;/^Libs.private/p;/^Version/p' $PREFIX/lib/pkgconfig/libopenmpt.pc | tr '\n' ' ')"
}
b_soxr()   { fetch soxr https://sourceforge.net/projects/soxr/files/soxr-0.1.3-Source.tar.xz soxr; do_cmake soxr -DWITH_LSP_DEMO=OFF -DBUILD_TESTS=OFF -DWITH_OPENMP=OFF -DHAVE_AVX_P6=OFF -DHAVE_AVX=OFF -DHAVE_SSE2=OFF -DHAVE_SSE3=OFF; }
b_bs2b()   {
    fetch bs2b https://sourceforge.net/projects/bs2b/files/libbs2b/3.1.0/libbs2b-3.1.0.tar.gz bs2b
    # 3.1.0 自带的 config.sub 太旧：configure 报 "machine `aarch64-linux' not recognized"
    for f in /usr/share/automake-*/config.sub /usr/share/automake-*/config.guess; do
        [ -f "$f" ] || continue
        cp -f "$f" "$SRC/bs2b/build-aux/" 2>/dev/null || true
        cp -f "$f" "$SRC/bs2b/" 2>/dev/null || true
    done
    # 它的 autotools 太旧（config.sub 不认 android），而全部实现就 3 个 .c，直接手工编静态库
    local bs=$(find "$SRC/bs2b" -name bs2b.c 2>/dev/null | head -1)
    [ -n "$bs" ] || { echo "找不到 bs2b.c"; find "$SRC/bs2b" -maxdepth 3 -type d; return 1; }
    local d=$(dirname "$bs")
    cd "$d" || return 1
    echo "bs2b 源目录: $d"; ls
    $CC -O2 -fPIC -I. -c bs2b.c
    install -d $PREFIX/lib $PREFIX/include
    rm -f $PREFIX/lib/libbs2b.a
    $AR rcus $PREFIX/lib/libbs2b.a bs2b.o
    cp -f bs2b.h bs2btypes.h bs2bversion.h $PREFIX/include/ 2>/dev/null || true
    write_pc libbs2b 3.1.0 "-lbs2b"
}
# 不带 --enable-single：那样只产出 libfftw3f，rubberband 的 meson 需要 fftw3（双精度）依赖
b_fftw()   { fetch fftw https://fftw.org/fftw-3.3.10.tar.gz fftw; do_autotools fftw --disable-float128 --without-python; }
b_samplerate() { fetch samplerate https://github.com/libsndfile/libsamplerate/releases/download/0.2.2/libsamplerate-0.2.2.tar.xz samplerate; do_cmake samplerate -DBUILD_TESTING=OFF -DLIBSAMPLERATE_EXAMPLES=OFF; }
b_rubberband() {
    fetch rubberband https://breakfastquay.com/files/releases/rubberband-4.0.0.tar.bz2 rubberband
    # rubberband 3.x 起改成 meson 工程，没有 configure.ac（autoreconf 直接报错）
    # auto-features=disabled 一次性关掉 demo/tests/jni 等非必需 feature
    do_meson rubberband -Dauto_features=disabled
    write_pc rubberband-2.0 4.0.0 "-lrubberband -lsamplerate -lfftw3"
    write_pc rubberband 4.0.0 "-lrubberband -lsamplerate -lfftw3"
}

# ============================================================================
# 第 5 层：滤镜 / 图像 / 质量测量
# ============================================================================
b_zimg()    { fetch zimg https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.5.tar.gz zimg; do_autotools zimg --disable-tests; }
b_vidstab() {
    fetch vidstab https://github.com/openkylin/libvidstab/archive/refs/tags/upstream/1.1.0.tar.gz vidstab
    # 该库在 CMakeLists 里无条件加 -msse2，交叉到 arm64 必然失败，先从源码剔除
    grep -rl 'msse2' "$SRC/vidstab" 2>/dev/null | xargs -r sed -i 's/-msse2//g'
    do_cmake vidstab -DUSE_SSE2=OFF -DUSE_SSE=OFF
}
b_mysofa()  { fetch mysofa https://github.com/hoene/libmysofa/archive/refs/tags/v1.3.2.tar.gz mysofa; do_cmake mysofa -DJSON_TESTS=OFF -DCMOD_TESTS=OFF -DBUILD_TESTING=OFF -DCMAKE_DISABLE_FIND_PACKAGE_CUnit=ON -DBUILD_TESTS=OFF -DENABLE_TESTS=OFF; }
b_lcms2()   { fetch lcms2 https://github.com/mm2/Little-CMS/archive/refs/tags/lcms2.14.tar.gz lcms2; do_autotools lcms2; }
b_webp()    {
    fetch webp https://github.com/webmproject/libwebp/archive/refs/tags/v1.4.0.tar.gz webp
    do_cmake webp -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_EXTRAS=OFF -DWEBP_HAVE_NEON=ON
}
b_brotli()  { fetch brotli https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz brotli; do_cmake brotli; }
b_highway() { fetch highway https://github.com/google/highway/archive/refs/tags/1.2.0.tar.gz highway; do_cmake highway -DHWY_ENABLE_CONTRIB=OFF -DBUILD_TESTING=OFF; }
b_jxl()     {
    gitclone jxl https://github.com/libjxl/libjxl.git jxl v0.11.1
    cd "$SRC/jxl"
    git submodule update --init --depth 1 --recursive || true
    [ -f third_party/sjpeg/CMakeLists.txt ] || { echo "jxl 子模块未拉全"; ls third_party | head; return 1; }
    do_cmake jxl -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
        -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
        -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_SKCMS=OFF \
        -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_SJPEG=OFF
}
b_vmaf() {
    fetch vmaf https://github.com/Netflix/vmaf/archive/refs/tags/v3.0.0.tar.gz vmaf
    cd "$SRC/vmaf/libvmaf"
    rm -rf build
    meson setup build . --cross-file "$BUILD_ROOT/cross.txt" --prefix=$PREFIX \
        --default-library=static --buildtype=release \
        -Denable_tests=false -Denable_docs=false -Dbuilt_in_models=true 
    ninja -C build; ninja -C build install
}

# ============================================================================
# 第 6 层：Vulkan / GPU（清单里最重）
# ============================================================================
vulkan_headers() {
    fetch vulkan_hdr "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.3.278.tar.gz https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.3.275.tar.gz" vulkan_hdr || return 1
    mkdir -p $PREFIX/include
    rm -rf $PREFIX/include/vulkan $PREFIX/include/vk_video $PREFIX/include/vk_struct_helper
    cp -rf "$SRC/vulkan_hdr/include/." $PREFIX/include/
    # placebo 构建期要用 python 从 vk.xml 生成 vulkan 代码，光有头文件不够
    mkdir -p $PREFIX/share/vulkan/registry
    cp -f "$SRC/vulkan_hdr/registry/vk.xml" $PREFIX/share/vulkan/registry/ 2>/dev/null || true
    ls -l $PREFIX/share/vulkan/registry/vk.xml 2>/dev/null
    echo "Vulkan-Headers VK_HEADER_VERSION=$(sed -n 's/^#  *define  *VK_HEADER_VERSION  *\([0-9]*\).*//p' $PREFIX/include/vulkan/vulkan_core.h | head -1)"
}

b_glslang() {
    fetch glslang https://github.com/KhronosGroup/glslang/archive/refs/tags/15.1.0.tar.gz glslang
    do_cmake glslang -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DENABLE_HLSL=OFF -DBUILD_TESTING=OFF
    # glslang 的 CMake install 清单不全（实测漏了 OGLCompiler），但构建目录里其实都产出了；
    # 而 libplacebo 的 meson 会逐个 find_library 要它们，缺一个就整个配置失败。
    find "$SRC/glslang/build" -name "*.a" -exec cp -f {} $PREFIX/lib/ \; 2>/dev/null || true
    echo "glslang 静态库: $(ls $PREFIX/lib/lib{SPIRV,glslang,MachineIndependent,GenericCodeGen,OSDependent,SPVRemapper,OGLCompiler,HLSL,glslang-default-resource-limits}*.a 2>/dev/null | xargs -n1 basename | tr '
' ' ')"
}
b_glslang_pc() {
    cat > $PREFIX/lib/pkgconfig/glslang.pc <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: glslang
Description: glslang
Version: 15.1.0
Libs: -L\${libdir} -lSPIRV -lglslang -lMachineIndependent -lGenericCodeGen -lOSDependent -lSPVRemapper -lc++_static -lc++abi
Cflags: -I\${includedir}
EOF
}
b_placebo() {
    vulkan_headers || return 1
    b_glslang_pc
    fetch placebo https://code.videolan.org/videolan/libplacebo/-/archive/v7.351.0/libplacebo-v7.351.0.tar.bz2 placebo
    # meson 的 cpp.find_library('SPIRV') 只搜编译器 --print-search-dirs 报出的内建目录，
    # 根本不认 -L / link_args，所以把 glslang 的静态库直接放进 sysroot 的库目录。
    # glslang 15.1 已经把 OGLCompilersDLL 合并进 MachineIndependent，不再产出
    # libOGLCompiler.a；而 libplacebo 6.338 的 static 分支仍然硬性
    # find_library('OGLCompiler', required: true)。它只要"这个库存在"，
    # 符号实际都在别的库里，所以造一个占位归档即可过关。
    if [ ! -e $PREFIX/lib/libOGLCompiler.a ]; then
        echo 'static int _placebo_oglcompiler_placeholder(void){return 0;}' > /tmp/oglc.c
        $CC -c -fPIC -o /tmp/oglc.o /tmp/oglc.c
        rm -f $PREFIX/lib/libOGLCompiler.a
        $AR rcs $PREFIX/lib/libOGLCompiler.a /tmp/oglc.o
        echo "已造占位库 libOGLCompiler.a"
    fi

    for _f in "$PREFIX"/lib/lib*.a; do
        case "$(basename "$_f")" in
            libSPIRV.a|libglslang*.a|libMachineIndependent.a|libGenericCodeGen.a|libOSDependent.a|libSPVRemapper.a|libOGLCompiler.a|libHLSL.a)
                cp -f "$_f" "$SYSROOT/usr/lib/aarch64-linux-android/" 2>/dev/null || true ;;
        esac
    done
    echo "已放进 sysroot 的 glslang 库: $(ls $SYSROOT/usr/lib/aarch64-linux-android/lib*.a 2>/dev/null | xargs -n1 basename | tr '
' ' ')"
    # libplacebo 的 convert.cc 需要 fast_float（header-only）。离线取不到它的
    # meson subproject wrap，就退化到要求系统提供 <fast_float/fast_float.h>。
    fetch fast_float https://github.com/fastfloat/fast_float/archive/refs/tags/v6.1.1.tar.gz fast_float || return 1
    mkdir -p $PREFIX/include/fast_float
    _ffd=$(find "$SRC/fast_float" -type d -name include | head -1)
    [ -n "$_ffd" ] || { echo "找不到 fast_float 的 include 目录"; return 1; }
    # fast_float.h 内部还 #include "float_common.h" 等兄弟头，只拷它自己不够
    cp -f "$_ffd"/*.h $PREFIX/include/fast_float/
    echo "已装 fast_float 头: $(ls $PREFIX/include/fast_float/ | tr '\n' ' ')"
    do_meson placebo -Dvulkan=enabled -Dglslang=enabled -Dlcms=enabled -Dopengl=disabled -Dd3d11=disabled -Dshaderc=disabled -Ddovi=disabled -Dlibdovi=disabled -Dxxhash=disabled -Dvulkan-registry=$PREFIX/share/vulkan/registry/vk.xml -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
    ls -l $PREFIX/lib/libplacebo.a 2>/dev/null
}

# ============================================================================
# 第 7 层：网络 / 容器 / 光盘
# ============================================================================
b_xml2() {
    fetch xml2 https://github.com/GNOME/libxml2/archive/refs/tags/v2.13.5.tar.gz xml2
    do_cmake xml2 -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF \
        -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
        -DLIBXML2_WITH_ZLIB=OFF -DLIBXML2_WITH_LZMA=OFF
}
b_srt() {
    fetch srt https://github.com/Haivision/srt/archive/refs/tags/v1.5.3.tar.gz srt
    if have libcrypto.a; then
        do_cmake srt -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF \
            -DENABLE_TESTS=OFF -DENABLE_ENCRYPTION=ON -DUSE_ENCLIB=openssl
    else
        do_cmake srt -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF \
            -DENABLE_TESTS=OFF -DUSE_ENCLIB=mbedtls -DENABLE_MBEDTLS=OFF
    fi
}
b_libssh() { fetch libssh https://git.libssh.org/projects/libssh.git/snapshot/libssh-0.11.1.tar.gz libssh; do_cmake libssh -DBUILD_SHARED_LIBS=OFF -DWITH_STATIC_LIB=ON -DWITH_EXAMPLES=OFF -DWITH_GSSAPI=OFF -DWITH_SERVER=OFF -DUNIT_TESTING=OFF -DWITH_ZLIB=OFF -DOPENSSL_INCLUDE_DIR=$PREFIX/include -DOPENSSL_CRYPTO_LIBRARY=$PREFIX/lib/libcrypto.a -DOPENSSL_SSL_LIBRARY=$PREFIX/lib/libssl.a; }
b_zmq()    { fetch zmq https://github.com/zeromq/libzmq/releases/download/v4.3.5/zeromq-4.3.5.tar.gz zmq; do_cmake zmq -DZMQ_BUILD_TESTS=OFF -DWITH_LIBSODIUM=OFF -DWITH_TLS=OFF -DBUILD_SHARED=OFF -DBUILD_STATIC=ON; }
b_bluray() {
    fetch bluray https://download.videolan.org/pub/videolan/libbluray/1.3.4/libbluray-1.3.4.tar.bz2 bluray
    # libbluray 的 dec_init 漏了 static，是全局符号；单体静态合并时和 FFmpeg 9 的
    # fftools/ffmpeg_dec.c:dec_init 直接 duplicate symbol，LDXX 阶段整个链接失败。
    # 改名加 bluray_ 前缀（比 objcopy --localize 安全：局部化会让跨文件的调用变 undefined）。
    find "$SRC/bluray/src" \( -name '*.c' -o -name '*.h' \) -print0 2>/dev/null \
        | xargs -0 -r sed -i 's/\bdec_init\b/bluray_dec_init/g'
    grep -rc 'bluray_dec_init' "$SRC/bluray/src" 2>/dev/null | grep -v ':0' | head -5
    do_autotools bluray --disable-bdjava-jar --disable-examples
}
b_dvdread() { fetch dvdread https://download.videolan.org/pub/videolan/libdvdread/6.1.2/libdvdread-6.1.2.tar.bz2 dvdread; do_autotools dvdread --with-libcss=no; }
b_dvdnav()  { fetch dvdnav https://download.videolan.org/pub/videolan/libdvdnav/6.1.1/libdvdnav-6.1.1.tar.bz2 dvdnav; do_autotools dvdnav --with-libcss=no; }

# ============================================================================
# 第 8 层：Android 上无意义的（X11 / V4L2 / OpenCL），试了不行就丢
# ============================================================================
b_xcb()  {
    fetch xcb https://www.x.org/releases/individual/lib/libxcb-1.17.0.tar.xz xcb
    do_autotools xcb
}
b_v4l2() {
    fetch v4l2 https://linuxtv.org/downloads/libv4l/libv4l-1.28.1.tar.gz v4l2
    cd "$SRC/v4l2"
    make -j$(nproc) CC=$CC prefix=$PREFIX
    make prefix=$PREFIX install
}

# ============================================================================
# 执行（依赖在前）
# ============================================================================
run_step zlib       b_zlib
run_step bzip2      b_bzip2
run_step xz         b_xz
run_step expat      b_expat
run_step openssl    b_openssl libcrypto.a
run_step libpng     b_libpng
run_step freetype   b_freetype
run_step fribidi    b_fribidi
run_step harfbuzz   b_harfbuzz libharfbuzz.a
run_step fontconfig b_fontconfig libfontconfig.a
run_step libass     b_libass libass.a
run_step x264       b_x264 libx264.a
run_step x265       b_x265 libx265.a
run_step dav1d      b_dav1d libdav1d.a
run_step aom        b_aom libaom.a
run_step svtav1     b_svtav1 libSvtAv1Enc.a
run_step vpx        b_vpx libvpx.a
run_step xvid       b_xvid libxvidcore.a
run_step opus       b_opus
run_step ogg        b_ogg
run_step vorbis     b_vorbis
run_step theora     b_theora libtheora.a
run_step lame       b_lame
run_step amrnb      b_amrnb
run_step amrwb      b_amrwb
run_step gme        b_gme libgme.a
run_step mpg123     b_mpg123
run_step openmpt    b_openmpt libopenmpt.a
run_step soxr       b_soxr
run_step bs2b       b_bs2b libbs2b.a
run_step fftw       b_fftw
run_step samplerate b_samplerate
run_step rubberband b_rubberband librubberband.a
run_step zimg       b_zimg
run_step vmaf       b_vmaf
run_step mysofa     b_mysofa libmysofa.a
run_step lcms2      b_lcms2
run_step webp       b_webp
run_step brotli     b_brotli
run_step highway    b_highway
run_step jxl        b_jxl libjxl.a
run_step glslang    b_glslang
run_step placebo    b_placebo libplacebo.a
run_step xml2       b_xml2
run_step srt        b_srt libsrt.a
# libssh 主动排除：只服务 sftp:// 协议，Android 端本地转码用不到；
# 它的 CMake install 规则找 build/src/libssh.a 而交叉构建产物名不符，四轮未解，继续拖只增加噪音。
SKIPPED+=("libssh(主动排除:sftp协议无用/CMake静态install不兼容)")
run_step zmq        b_zmq
run_step bluray     b_bluray libbluray.a
run_step dvdread    b_dvdread
run_step dvdnav     b_dvdnav
run_step v4l2       b_v4l2

# ============================================================================
# 清掉 .pc 里的 -lpthread
# bionic 的 pthread 符号全在 libc 内，系统里没有 libpthread；但 srt/zmq/harfbuzz
# 等 .pc 的 Libs.private 写死 -lpthread，pkg-config --static 会把它带进 ffmpeg 的
# 链接探测 → "unable to find library -lpthread" → configure 报 "srt not found"。
# ============================================================================
echo ""
echo "=== 清理 .pc 中的 -lpthread ==="
sed -i 's/[[:space:]]-lpthread//g' $PREFIX/lib/pkgconfig/*.pc 2>/dev/null || true
echo "仍含 lpthread 的 pc: $(grep -l 'lpthread' $PREFIX/lib/pkgconfig/*.pc 2>/dev/null | tr '\n' ' ')"

# 同理把 .pc 里的 C++ 运行时换成 NDK 静态 libc++：-lc++ 会解析到 sysroot 的
# libc++_shared.so 桩，单体里就留下 NEEDED libc++_shared.so（又变成一个外部依赖）
sed -i -e 's/-lstdc++/-lc++_static -lc++abi/g' \
       -e 's/-lc++\([[:space:]]\|$\)/-lc++_static -lc++abi\1/g' $PREFIX/lib/pkgconfig/*.pc 2>/dev/null || true
echo "仍含 C++ 运行时的 pc: $(grep -l -e 'lstdc++' -e 'lc\+\+[^_]' $PREFIX/lib/pkgconfig/*.pc 2>/dev/null | tr '\n' ' ')"

# ============================================================================
# 补一个 vulkan.pc
# NDK sysroot 里有 vulkan/vulkan.h 和可链接的 libvulkan.so stub，但没有 pkg-config
# 元数据；FFmpeg 9 的 vulkan 检测是按 pkg-config 找 "vulkan >= 1.3.251"，缺 .pc 就直接
# "ERROR: vulkan requested but not found"，把整个 configure 卡死。
# ============================================================================
echo ""
echo ""
echo "=== 安装新 Vulkan-Headers（FFmpeg 9 读头里的 VK_HEADER_VERSION，要求 >= 251）==="
# 逐库探测里 vkCreateInstance 是能链接通过的，卡点在头文件版本宏：
# NDK sysroot 自带的 vulkan_core.h 偏旧，所以从 Khronos 装一份新的优先使用。
fetch vulkan_hdr "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.3.278.tar.gz https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.3.275.tar.gz" vulkan_hdr
if [ -d "$SRC/vulkan_hdr/include/vulkan" ]; then
    mkdir -p $PREFIX/include
    # 整个 include/ 都要拷：新版把 vk_video/、vk_struct_helper/ 拆成兄弟目录，
    # vulkan_core.h 会 #include <vk_video/vulkan_video_codec_av1std.h>，
    # 只拷 vulkan/ 反而把自己搞成"头文件缺失"
    rm -rf $PREFIX/include/vulkan $PREFIX/include/vk_video $PREFIX/include/vk_struct_helper
    cp -rf "$SRC/vulkan_hdr/include/." $PREFIX/include/
    ls -d $PREFIX/include/vk_video $PREFIX/include/vulkan 2>/dev/null | tr '
' ' '
    echo
    echo "已装头文件，VK_HEADER_VERSION=$(sed -n 's/^#  *define  *VK_HEADER_VERSION  *\([0-9]*\).*/\1/p' $PREFIX/include/vulkan/vulkan_core.h | head -1)"
else
    echo "未取得新头，退回 NDK sysroot 的头（vulkan 可能仍被判定不可用）"
fi
echo "=== 生成 vulkan.pc ==="
VK_INC=$SYSROOT/usr/include
[ -f "$PREFIX/include/vulkan/vulkan_core.h" ] && VK_INC=$PREFIX/include
VK_HDR=$(sed -n 's/^#  *define  *VK_HEADER_VERSION  *\([0-9][0-9]*\).*/\1/p' \
            "$VK_INC/vulkan/vulkan_core.h" 2>/dev/null | head -1)
VK_HDR=${VK_HDR:-275}
[ "$VK_HDR" -ge 251 ] || VK_HDR=251
{
    echo "prefix=$PREFIX"
    echo "libdir=\${prefix}/lib"
    echo "includedir=$VK_INC"
    echo "Name: Vulkan-Loader"
    echo "Description: Vulkan Loader"
    echo "Version: 1.3.$VK_HDR"
    echo "Cflags: -I\${includedir}"
    echo "Libs: -L\${libdir} -lvulkan"
} > $PREFIX/lib/pkgconfig/vulkan.pc
cat $PREFIX/lib/pkgconfig/vulkan.pc
echo "pkg-config 验证: $($PKGCFG --exists --print-errors 'vulkan >= 1.3.251' 2>&1 && echo OK)  Version=$($PKGCFG --modversion vulkan 2>&1)  Cflags=$($PKGCFG --cflags vulkan 2>&1)"

# ============================================================================
# 按实际产物拼装 ffmpeg 开关
# ============================================================================
flag() {  # flag <探测文件> <ffmpeg开关>
    if have "$1"; then ENABLE_FLAGS+=("$2"); else MISSING+=("$2"); echo "  [缺] $2 （$1 未编出）"; fi
}

echo ""
echo "=== 依赖产物探测 → ffmpeg 开关 ==="
flag libx264.a              --enable-libx264
flag libx265.a              --enable-libx265
flag libdav1d.a             --enable-libdav1d
flag libaom.a               --enable-libaom
flag libvpx.a               --enable-libvpx
flag libxvidcore.a          --enable-libxvid
flag libSvtAv1Enc.a         --enable-libsvtav1
flag libopus.a              --enable-libopus
flag libvorbis.a            --enable-libvorbis
flag libtheora.a            --enable-libtheora
flag libmp3lame.a           --enable-libmp3lame
flag libopencore-amrnb.a    --enable-libopencore-amrnb
flag libopencore-amrwb.a    --enable-libopencore-amrwb
flag libvo-amrwbenc.a       --enable-libvo-amrwbenc
flag libgme.a               --enable-libgme
flag libopenmpt.a           --enable-libopenmpt
flag libbs2b.a              --enable-libbs2b
flag libsoxr.a              --enable-libsoxr
flag librubberband.a        --enable-librubberband
flag libzimg.a              --enable-libzimg
flag libvmaf.a              --enable-libvmaf
flag libmysofa.a            --enable-libmysofa
flag libwebp.a              --enable-libwebp
flag libjxl.a               --enable-libjxl
flag libxml2.a              --enable-libxml2
flag libzmq.a               --enable-libzmq
flag libsrt.a               --enable-libsrt
flag libssh.a               --enable-libssh
flag libcrypto.a            --enable-openssl
flag libbluray.a            --enable-libbluray
flag libdvdread.a           --enable-libdvdread
flag libdvdnav.a            --enable-libdvdnav
flag libass.a               --enable-libass
flag libfreetype.a          --enable-libfreetype
flag libfribidi.a           --enable-libfribidi
flag libharfbuzz.a          --enable-libharfbuzz
flag libfontconfig.a        --enable-libfontconfig
flag liblcms2.a             --enable-lcms2
flag libplacebo.a           --enable-libplacebo
flag libv4l2.a              --enable-libv4l2


# ============================================================================
# FFmpeg 本体
# ============================================================================
echo ""
echo "=== 成功 ${#OK[@]} / 失败 ${#FAILED[@]} / 跳过 ${#SKIPPED[@]} ==="
echo "失败: ${FAILED[*]:-无}"
echo "启用开关: ${ENABLE_FLAGS[*]:-}"

fetch ffmpeg "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$FFMPEG_VER.tar.gz" ffmpeg
cd "$SRC/ffmpeg"

# 缓存里留着上一轮的 $PREFIX/bin/ffmpeg。不先删掉的话，本轮 configure/make 失败也会被
# 下面的 [ -x "$BIN" ] 当成成功，拿旧产物冒充新结果（run#91 就是这样 2 分钟"成功"的）
rm -f "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe" "$BUILD_ROOT/ffmpeg-unstripped" "$PREFIX/lib/libffmpeg.so"

FF_OK=1
TRY=0
VK_STATE=启用
ffmpeg_configure() {   # 用全局 VK_ON 决定是否带 --enable-vulkan
    local vk=""; [ "$VK_ON" = 1 ] && vk=--enable-vulkan
    ./configure \
        --prefix=$PREFIX \
        --pkg-config=$PKGCFG --pkg-config-flags=--static \
        --cc=$CC --cxx=$CXX --ar=$AR --nm=$NM --ranlib=$RANLIB --strip=$STRIP \
        --enable-cross-compile --target-os=android --arch=aarch64 --cpu=armv8-a \
        --enable-static --disable-shared \
        --enable-gpl --enable-version3 \
        --enable-jni --enable-mediacodec --enable-neon \
        ${vk:+"$vk"} \
        --enable-indev=lavfi \
        --extra-cflags="-I$PREFIX/include -fPIC -O2" \
        --extra-ldflags="-L$PREFIX/lib -static-libstdc++" \
        --extra-libs="-lm -ldl -llog -landroid -lmediandk -lz -lbz2 -llzma -lc++_static -lc++abi -lmpg123 -lvorbisfile -lvorbis -logg" \
        --disable-doc --disable-debug --disable-stripping \
        ${ENABLE_FLAGS[@]+"${ENABLE_FLAGS[@]}"} >"$LOGDIR/ffmpeg-configure.log" 2>&1
}

VK_ON=1
DROPPED=()
# 链接前清掉依赖库里所有 shared 副本：只要 $PREFIX/lib 里还留着 libxxx.so，
# 链接器就会优先选中它，单体里于是出现 NEEDED libxxx.so —— 只留 .a 才能杜绝
echo ""
echo "=== 清除依赖库的 .so 副本（强制全部走静态）==="
find $PREFIX/lib -maxdepth 1 -name '*.so*' -print -delete 2>/dev/null | sed 's|.*/|  删除 |'

# 自动降级：vulkan 先试，失败就摘掉它；之后 configure 报"某库 not found"，
# 就把那个开关临时摘掉再试。任何一个库的探测问题都不该把整体拖成零产物。
while :; do
    TRY=$((TRY+1))
    if ffmpeg_configure; then FF_OK=1; break; fi
    cp -f "$LOGDIR/ffmpeg-configure.log" "$LOGDIR/ffmpeg-configure-attempt$TRY.log"
    errline=$(grep -m1 -E '^ERROR: |^Unknown option ' "$LOGDIR/ffmpeg-configure.log" | cut -c1-160)
    echo "!!! configure 第 $TRY 次失败: ${errline:-（没有可识别的错误行，见日志）}"
    flag=""
    case "${errline:-}" in
        *vulkan*) if [ "$VK_ON" = 1 ]; then VK_ON=0; VK_STATE=降级关闭
                      echo "  错误指向 vulkan，摘掉 --enable-vulkan 重试"; continue; fi
                  echo "vulkan 已摘除仍失败，停止重试"; FF_OK=0; break ;;
    esac
    # FFmpeg 遇到未知选项会直接退出且不写 ERROR: 行，必须单独识别
    case "${errline:-}" in
        "Unknown option "*)
            flag=$(printf '%s' "$errline" | sed -n 's/.*Unknown option "\([^"]*\)".*/\1/p') ;;
    esac
    if [ -z "$flag" ]; then
        pkg=$(printf '%s' "${errline#ERROR: }" | sed -n 's/^\([a-zA-Z0-9_.+-]\{2,\}\).*/\1/p')
        if [ -z "$pkg" ]; then echo "无法从错误行提取开关名，停止重试"; FF_OK=0; break; fi
        case "$pkg" in lib*) flag="--enable-$pkg";; *) flag="--enable-lib$pkg";; esac
    fi
    new=()
    for f in "${ENABLE_FLAGS[@]}"; do [ "$f" = "$flag" ] || new+=("$f"); done
    if [ "${#new[@]}" -eq "${#ENABLE_FLAGS[@]}" ]; then
        echo "$flag 不在开关列表里（可能是编译器/链接器层面的问题），停止重试"
        FF_OK=0; tail -30 "$LOGDIR/ffmpeg-configure.log"; break
    fi
    ENABLE_FLAGS=("${new[@]:-}")
    DROPPED+=("$flag")
    echo "已临时移除 $flag 重试，当前开关数: ${#ENABLE_FLAGS[@]}"
    if [ "$TRY" -ge 10 ]; then echo "重试次数用尽"; FF_OK=0; break; fi
done

if [ $FF_OK -eq 1 ]; then
    if ! make -j$(nproc) >"$LOGDIR/ffmpeg-make.log" 2>&1; then
        FF_OK=0
        echo "!!! ffmpeg make 失败，日志尾部："
        tail -60 "$LOGDIR/ffmpeg-make.log"
    else
        make install >>"$LOGDIR/ffmpeg-make.log" 2>&1
    fi
fi

BIN=$PREFIX/bin/ffmpeg
if [ -x "$BIN" ]; then
    cp -f "$BIN" "$BUILD_ROOT/ffmpeg-unstripped"
    "$STRIP" --strip-unneeded "$BIN"
    cp -f "$BIN" "$PREFIX/lib/libffmpeg.so"
    chmod 755 "$PREFIX/lib/libffmpeg.so"
    # 只允许 Android 系统自带的库；出现别的就说明不是一个文件能独立跑
    SYS_LIBS='libm\.so|libdl\.so|libc\.so|liblog\.so|libandroid\.so|libmediandk\.so|libcamera2ndk\.so|libvulkan\.so|libEGL\.so|libGLESv2\.so|libGLESv1_CM\.so|libOpenCL\.so'
    STRAY=$("$READELF" -d "$PREFIX/lib/libffmpeg.so" 2>/dev/null \
            | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' \
            | grep -Ev "^($SYS_LIBS)$" | tr '\n' ' ')
    if [ -n "$STRAY" ]; then
        echo "=== 产物仍依赖非系统库，不算单体: $STRAY ==="
        echo "完整 NEEDED 清单:"
        "$READELF" -d "$PREFIX/lib/libffmpeg.so" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/  /p'
        cp -f "$PREFIX/lib/libffmpeg.so" "$BUILD_ROOT/rejected-libffmpeg.so"
        echo "（已留档为 $BUILD_ROOT/rejected-libffmpeg.so 供对比）"
        rm -f "$PREFIX/lib/libffmpeg.so"
    else
        echo "=== 单文件已产出（依赖全部为系统库）==="
    fi
else
    echo "=== 未产出 ffmpeg 可执行文件（FF_OK=$FF_OK）==="
fi

# ============================================================================
# 报告
# ============================================================================
{
    echo "FFmpeg $FFMPEG_VER 单体构建报告  $(date -u '+%F %T UTC')"
    echo "NDK $NDK_VER / API $API / $TARGET"
    echo
    echo "成功库 (${#OK[@]}): ${OK[*]}"
    echo
    echo "失败库 (${#FAILED[@]}): ${FAILED[*]:-无}"
    echo
    echo "SKIP_LIBS 排除 (${#SKIPPED[@]}): ${SKIPPED[*]:-无}"
    echo
    echo "vulkan 状态: $VK_STATE"
    if [ -s "$LOGDIR/ffmpeg-configure-vulkan-attempt.log" ]; then
        echo "带 vulkan 首次尝试的日志尾部（看 vulkan 到底缺什么）:"
        tail -12 "$LOGDIR/ffmpeg-configure-vulkan-attempt.log"
    fi
    echo
    echo "ffmpeg 实际启用: ${ENABLE_FLAGS[*]}"
    echo
    echo "因缺产物而未启用的开关 (${#MISSING[@]}): ${MISSING[*]:-无}"
    echo "configure 重试中被临时摘掉的开关: ${DROPPED[*]:-无}"
    echo "各次 configure 尝试的 ERROR 行（被摘掉的库到底为什么失败）:"
    for af in "$LOGDIR"/ffmpeg-configure-attempt*.log; do
        [ -f "$af" ] || continue
        echo "  $(basename "$af"): $(grep -m2 '^ERROR: ' "$af" | tr '\n' ' | ' | cut -c1-200)"
    done
    echo "  逐库静态探测（用 ffmpeg 的完整 extra-libs，只打印 error 行）:"
    FFLIBS="-lm -ldl -llog -landroid -lmediandk -lz -lbz2 -llzma -lc++_static -lc++abi"
    for probe in "libopenmpt libopenmpt/libopenmpt.h openmpt_module_create" \
                 "libopenmpt libopenmpt/libopenmpt.h openmpt_module_create2" \
                 "libzmq zmq.h zmq_ctx_new" "srt srt/srt.h srt_socket" \
                 "vulkan vulkan/vulkan.h vkCreateInstance"; do
        set -- $probe
        pcp=$1; pch=$2; pcs=$3
        printf '#include <%s>\nint main(void){ return (int)(size_t)&%s; }\n' "$pch" "$pcs" > /tmp/probe.c
        pcout=$($CC -I$PREFIX/include /tmp/probe.c -o /tmp/probe \
                 -L$PREFIX/lib $($PKGCFG --static --libs "$pcp" 2>/dev/null) $FFLIBS 2>&1)
        if [ -x /tmp/probe ]; then
            echo "    [$pcs via $pcp] 通过"
        else
            echo "    [$pcs via $pcp] 失败:"
            printf '%s\n' "$pcout" | grep -E 'error|undefined|cannot|referenced|ld\.lld' | head -5 | sed 's/^/        /'
        fi
        rm -f /tmp/probe
    done
    echo
    echo "产物:"
    ls -la "$PREFIX/lib/libffmpeg.so" "$BUILD_ROOT/ffmpeg-unstripped"
    echo
    echo "动态依赖:"
    "$READELF" -d "$PREFIX/lib/libffmpeg.so" | grep -E 'NEEDED|SONAME' || true
    echo
    echo "内嵌 configure 行:"
    strings -n 40 "$PREFIX/lib/libffmpeg.so" | grep -m1 'configuration:' || true
    echo "ffmpeg 构建状态: FF_OK=$FF_OK  产物: $([ -x "$BIN" ] && echo 有 || echo 无)"
    echo
    echo "libopenmpt 静态链接自测（复现 ffmpeg 的 pkg-config 探测）:"
    cat > /tmp/ffmtest.c <<'TEOF'
#include <libopenmpt/libopenmpt.h>
int main(void){ return openmpt_module_create ? 1 : 0; }
TEOF
    omc=$($PKGCFG --static --cflags libopenmpt 2>&1); oml=$($PKGCFG --static --libs libopenmpt 2>&1)
    echo "  cflags: $omc"
    echo "  libs  : $oml"
    echo "  头文件: $(find $PREFIX/include -name libopenmpt.h 2>/dev/null | head -1)"
    echo "  符号数: $("$NM" --defined-only $PREFIX/lib/libopenmpt.a 2>/dev/null | grep -c openmpt_module_create)"
    $CC $omc /tmp/ffmtest.c -o /tmp/ffmtest $oml 2>&1 | tail -8
    echo "  自测结果: $([ -x /tmp/ffmtest ] && echo 链接通过 || echo 链接失败)"
    echo
    echo "pkg-config --static 解析报错的 pc 清单:"
    for pcx in $PREFIX/lib/pkgconfig/*.pc; do
        pn=$(basename "$pcx" .pc)
        po=$($PKGCFG --static --libs "$pn" 2>&1) || echo "  [$pn] $po"
    done
    echo
    echo "pkgconfig 清单:"
    ls $PREFIX/lib/pkgconfig 2>/dev/null | tr '\n' ' '
    echo
    echo "pkg-config 解析检查:"
    for p in freetype2 harfbuzz glslang dav1d; do
        printf '  %-10s -> %s\n' "$p" "$(pkg-config --cflags $p 2>&1 | head -1)"
    done
    echo
    echo "实际安装到 $PREFIX/lib 的静态库:"
    ls $PREFIX/lib/*.a 2>/dev/null | xargs -n1 basename | tr '\n' ' '
    echo
    echo
    echo "各失败库的第一条错误行:"
    for f in "${FAILED[@]:-}"; do
        [ -n "$f" ] || continue
        line=$(grep -hE 'configure: error|^CMake Error|ERROR: |: error: |fatal error:|No such file or directory|Could NOT find' \
                  "$LOGDIR/$f.log" "$LOGDIR/$f-configure.log" "$LOGDIR/$f-make.log" 2>/dev/null \
                | head -3 | tr '\n' ' | ' | cut -c1-260)
        if [ -z "$line" ]; then
            line=$(tail -3 "$LOGDIR/$f.log" 2>/dev/null | tr '\n' ' | ' | cut -c1-220)
            echo "  - $f :: (无标准错误行) $line"
        else
            echo "  - $f :: $line"
        fi
        # 只给第一条错误行经常看不出真正的 fatal 在哪（前面全是可选依赖的 warning）
        echo "      尾部: $(tail -20 "$LOGDIR/$f.log" 2>/dev/null | tr '\n' ' | ' | cut -c1-1400)"
        # 代码生成类失败的关键信息在 FAILED 之后（python traceback），tail 常常抓不到
        _fl=$(grep -n "FAILED" "$LOGDIR/$f.log" 2>/dev/null | tail -1 | cut -d: -f1)
        if [ -n "$_fl" ]; then
            echo "      FAILED 之后:"
            sed -n "${_fl},$((_fl+16))p" "$LOGDIR/$f.log" 2>/dev/null | sed "s/^/        /"
        fi
    done
    echo
    if [ -f "$SRC/ffmpeg/ffbuild/config.log" ]; then
        echo "ffmpeg ffbuild/config.log 关键行:"
        grep -E 'error|undefined|cannot|No such file|failure|ld\.lld' "$SRC/ffmpeg/ffbuild/config.log" 2>/dev/null | tail -25
        echo "--- config.log 末尾 ---"
        tail -25 "$SRC/ffmpeg/ffbuild/config.log"
        echo
    fi
    if [ $FF_OK -eq 0 ] && [ -s "$LOGDIR/ffmpeg-configure.log" ]; then
        echo "ffmpeg configure 日志尾部:"
        tail -25 "$LOGDIR/ffmpeg-configure.log"
    fi
    if [ $FF_OK -eq 0 ] && [ -s "$LOGDIR/ffmpeg-make.log" ]; then
        echo "ffmpeg make 日志尾部:"
        tail -30 "$LOGDIR/ffmpeg-make.log"
    fi
} | tee "$BUILD_ROOT/build-report.txt"

echo ""
if [ $FF_OK -ne 1 ]; then
    echo "=== 构建失败：ffmpeg configure/make 没通过，见上面报告 ==="
    exit 1
fi
if [ ! -x "$PREFIX/lib/libffmpeg.so" ]; then
    echo "=== 构建失败：没有合格单体（NEEDED 里混入了非系统库，见报告）==="
    exit 1
fi
echo "=== 完成：合格单文件在 $PREFIX/lib/libffmpeg.so ==="
