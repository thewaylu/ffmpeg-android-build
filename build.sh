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

declare -a OK=() FAILED=() SKIPPED=() ENABLE_FLAGS=()

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
    if [ -f "$BUILD_ROOT/done/$name" ] && ls "$PREFIX/lib"/*.a >/dev/null 2>&1; then
        OK+=("$name(cached)"); echo "########## [$name] 上轮已成功，跳过 ##########"; return 0
    fi
    echo "########## [$name] 开始 ##########"
    if ( set -eo pipefail; "$fn" ) >"$log" 2>&1; then
        if [ -n "$expect" ] && [ ! -e "$PREFIX/lib/$expect" ]; then
            FAILED+=("$name"); rm -f "$BUILD_ROOT/done/$name"
            echo "########## [$name] 假成功：返回 0 但没有 $expect，日志尾部 ##########"
            tail -25 "$log"
        else
            OK+=("$name"); mkdir -p "$BUILD_ROOT/done"; touch "$BUILD_ROOT/done/$name"
            echo "########## [$name] OK ##########"
        fi
    else
        FAILED+=("$name"); rm -f "$BUILD_ROOT/done/$name"
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
    echo "[$name] 下载 $url"
    rm -f "$tmp"
    curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$tmp" "$url" || {
        echo "[$name] 下载失败：$url"; rm -f "$tmp"; return 1; }
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
    export CROSS_COMPILE=$TOOLCHAIN/bin/${TARGET}${API}-
    ./Configure android-arm64 no-shared no-tests no-asm no-engine no-apps no-cli \
        --prefix=$PREFIX --openssldir=$PREFIX/ssl --sysroot=$SYSROOT \
        -D__ANDROID_API__=$API -fPIC
    [ -f Makefile ] || { echo "openssl Configure 未生成 Makefile"; return 1; }
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
    ./configure --prefix=$PREFIX --target=arm64-android-gcc \
        --enable-static --disable-shared --disable-examples --disable-unit-tests \
        --disable-tools --disable-docs --disable-better-hw-compression
    make -j$(nproc) libs
    make install
}
b_xvid() {
    fetch xvid https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.bz2 xvid
    cd "$SRC/xvid/build/generic"
    ./configure --prefix=$PREFIX --host=$TARGET --build=x86_64-pc-linux-gnu
    make -j$(nproc)
    install -d $PREFIX/lib && cp -f xvidcore.a $PREFIX/lib/
    write_pc xvidcore 1.3.7 "-lxvidcore"
}

# ============================================================================
# 第 4 层：音频编码器
# ============================================================================
b_opus()   { fetch opus https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz opus; do_autotools opus --disable-extra-programs --disable-assertions; }
b_ogg()    { fetch ogg https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz ogg; do_autotools ogg; }
b_vorbis() { fetch vorbis https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz vorbis; do_autotools vorbis; }
b_theora() {
    fetch theora https://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.xz theora
    cd "$SRC/theora"
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
    fetch openmpt "https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-0.7.19+release.makefile.tar.gz" openmpt
    make -C "$SRC/openmpt" -j"$(nproc)" PREFIX=$PREFIX NO_REVISION=1
    make -C "$SRC/openmpt" install PREFIX=$PREFIX NO_REVISION=1
    write_pc libopenmpt 0.7.19 "-lopenmpt -lm -lstdc++"
}
b_soxr()   { fetch soxr https://sourceforge.net/projects/soxr/files/soxr-0.1.3-Source.tar.xz soxr; do_cmake soxr -DWITH_LSP_DEMO=OFF -DBUILD_TESTS=OFF -DHAVE_AVX_P6=OFF -DHAVE_AVX=OFF -DHAVE_SSE2=OFF -DHAVE_SSE3=OFF; }
b_bs2b()   { fetch bs2b https://sourceforge.net/projects/bs2b/files/libbs2b/3.1.0/libbs2b-3.1.0.tar.gz bs2b; do_autotools bs2b; write_pc libbs2b 3.1.0 "-lbs2b"; }
b_fftw()   { fetch fftw https://fftw.org/fftw-3.3.10.tar.gz fftw; do_autotools fftw --enable-single --disable-float128 --without-python; }
b_samplerate() { fetch samplerate https://github.com/libsndfile/libsamplerate/releases/download/0.2.2/libsamplerate-0.2.2.tar.xz samplerate; do_cmake samplerate -DBUILD_TESTING=OFF -DLIBSAMPLERATE_EXAMPLES=OFF; }
b_rubberband() {
    fetch rubberband https://breakfastquay.com/files/releases/rubberband-4.0.0.tar.bz2 rubberband
    do_autotools rubberband --disable-rubberband-cli --disable-simd
    write_pc rubberband-2.0 4.0.0 "-lrubberband -lsamplerate -lfftw3"
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
b_glslang() {
    fetch glslang https://github.com/KhronosGroup/glslang/archive/refs/tags/15.1.0.tar.gz glslang
    do_cmake glslang -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DENABLE_HLSL=OFF -DBUILD_TESTING=OFF
}
b_glslang_pc() {
    cat > $PREFIX/lib/pkgconfig/glslang.pc <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: glslang
Description: glslang
Version: 15.1.0
Libs: -L\${libdir} -lSPIRV -lglslang -lMachineIndependent -lGenericCodeGen -lOSDependent -lSPVRemapper -lstdc++
Cflags: -I\${includedir}
EOF
}
b_placebo() {
    b_glslang_pc
    fetch placebo https://code.videolan.org/videolan/libplacebo/-/archive/v6.338.0/libplacebo-v6.338.0.tar.bz2 placebo
    cd "$SRC/placebo"
    git submodule update --init --depth 1 src/vulkan src/gl 2>/dev/null || true
    do_meson placebo -Dvulkan=enabled -Dglslang=enabled -Dlcms=enabled \
        -Ddemos=false -Dtests=false
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
b_libssh() { fetch libssh https://git.libssh.org/projects/libssh.git/snapshot/libssh-0.11.1.tar.gz libssh; do_cmake libssh -DWITH_EXAMPLES=OFF -DWITH_GSSAPI=OFF -DWITH_SERVER=OFF -DUNIT_TESTING=OFF -DWITH_ZLIB=OFF -DWITH_EXAMPLES_ELSE=OFF; }
b_zmq()    { fetch zmq https://github.com/zeromq/libzmq/releases/download/v4.3.5/zeromq-4.3.5.tar.gz zmq; do_cmake zmq -DZMQ_BUILD_TESTS=OFF -DWITH_LIBSODIUM=OFF -DWITH_TLS=OFF; }
b_bluray() { fetch bluray https://download.videolan.org/pub/videolan/libbluray/1.3.4/libbluray-1.3.4.tar.bz2 bluray; do_autotools bluray --disable-bdjava-jar --disable-examples; }
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
run_step rav1e      b_rav1e librav1e.a
run_step vpx        b_vpx libvpx.a
run_step xvid       b_xvid
run_step opus       b_opus
run_step ogg        b_ogg
run_step vorbis     b_vorbis
run_step theora     b_theora libtheora.a
run_step lame       b_lame
run_step amrnb      b_amrnb
run_step amrwb      b_amrwb
run_step gme        b_gme libgme.a
run_step mpg123     b_mpg123
run_step openmpt    b_openmpt
run_step soxr       b_soxr
run_step bs2b       b_bs2b
run_step fftw       b_fftw
run_step samplerate b_samplerate
run_step rubberband b_rubberband
run_step zimg       b_zimg
run_step vidstab    b_vidstab libvidstab.a
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
run_step libssh     b_libssh libssh.a
run_step zmq        b_zmq
run_step bluray     b_bluray libbluray.a
run_step dvdread    b_dvdread
run_step dvdnav     b_dvdnav
run_step v4l2       b_v4l2

# ============================================================================
# 按实际产物拼装 ffmpeg 开关
# ============================================================================
flag() {  # flag <探测文件> <ffmpeg开关>
    if have "$1"; then ENABLE_FLAGS+=("$2"); else echo "  [缺] $2 （$1 未编出）"; fi
}

echo ""
echo "=== 依赖产物探测 → ffmpeg 开关 ==="
flag libx264.a              --enable-libx264
flag libx265.a              --enable-libx265
flag libdav1d.a             --enable-libdav1d
flag libaom.a               --enable-libaom
flag librav1e.a             --enable-librav1e
flag libvpx.a               --enable-libvpx
flag libxvidcore.a          --enable-libxvidcore
flag libopus.a              --enable-libopus
flag libvorbis.a            --enable-libvorbis
flag libtheora.a            --enable-libtheora
flag libmp3lame.a           --enable-libmp3lame
flag libopencore-amrnb.a    --enable-libopencore-amrnb
flag libvo-amrwbenc.a       --enable-libvo-amrwbenc
flag libgme.a               --enable-libgme
flag libopenmpt.a           --enable-libopenmpt
flag libbs2b.a              --enable-libbs2b
flag libsoxr.a              --enable-libsoxr
flag librubberband.a        --enable-librubberband
flag libzimg.a              --enable-libzimg
flag libvidstab.a           --enable-libvidstab
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
flag libplacebo.a           --enable-libplacebo
if ls "$PREFIX"/lib/libplacebo*.a >/dev/null 2>&1; then
    grep -q -- '--enable-libplacebo' <<<" ${ENABLE_FLAGS[*]:-} " || ENABLE_FLAGS+=(--enable-libplacebo)
fi

# ============================================================================
# FFmpeg 本体
# ============================================================================
echo ""
echo "=== 成功 ${#OK[@]} / 失败 ${#FAILED[@]} / 跳过 ${#SKIPPED[@]} ==="
echo "失败: ${FAILED[*]:-无}"
echo "启用开关: ${ENABLE_FLAGS[*]:-}"

fetch ffmpeg "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz" ffmpeg
cd "$SRC/ffmpeg"

FF_OK=1
if ! ./configure \
    --prefix=$PREFIX \
    --pkg-config=$PKGCFG --pkg-config-flags=--static \
    --cc=$CC --cxx=$CXX --ar=$AR --nm=$NM --ranlib=$RANLIB --strip=$STRIP \
    --enable-cross-compile --target-os=android --arch=aarch64 --cpu=armv8-a \
    --enable-static --disable-shared \
    --enable-gpl --enable-version3 \
    --enable-jni --enable-mediacodec --enable-vulkan --enable-neon \
    --enable-indev=lavfi \
    --extra-cflags="-I$PREFIX/include -fPIC -O2" \
    --extra-ldflags="-L$PREFIX/lib -static-libstdc++" \
    --extra-libs="-lm -ldl -llog -landroid -lmediandk -lz -lbz2 -llzma -lpthread" \
    --disable-doc --disable-debug --disable-stripping \
    ${ENABLE_FLAGS[@]+"${ENABLE_FLAGS[@]}"} >"$LOGDIR/ffmpeg-configure.log" 2>&1; then
    FF_OK=0
    echo "!!! ffmpeg configure 失败，日志尾部："
    tail -40 "$LOGDIR/ffmpeg-configure.log"
fi

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
    echo "=== 单文件已产出 ==="
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
    echo "ffmpeg 实际启用: ${ENABLE_FLAGS[*]}"
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
        line=$(grep -hE 'configure: error|^CMake Error|ERROR: |: error: |fatal error:|No such file or directory' \
                  "$LOGDIR/$f.log" "$LOGDIR/$f-configure.log" "$LOGDIR/$f-make.log" 2>/dev/null \
                | grep -vE 'Looking for|Performing Test|Fetching value|Check for working' | head -1 | cut -c1-220)
        if [ -z "$line" ]; then
            line=$(tail -3 "$LOGDIR/$f.log" 2>/dev/null | tr '\n' ' | ' | cut -c1-220)
            echo "  - $f :: (无标准错误行) $line"
        else
            echo "  - $f :: $line"
        fi
    done
    echo
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
if [ ! -x "$BIN" ]; then
    echo "=== 构建失败：见上面报告 ==="
    exit 1
fi
echo "=== 完成：单文件在 $PREFIX/lib/libffmpeg.so ==="
