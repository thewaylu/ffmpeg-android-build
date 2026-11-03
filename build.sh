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
    local name=$1 fn=$2 log=$LOGDIR/$name.log
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
        OK+=("$name"); mkdir -p "$BUILD_ROOT/done"; touch "$BUILD_ROOT/done/$name"
        echo "########## [$name] OK ##########"
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
    curl -fL --retry 3 --connect-timeout 30 -o "$tmp" "$url"
    rm -rf "$SRC/$dir" "$tmp"; mkdir -p "$SRC/$dir"
    tar xf "$tmp" -C "$SRC/$dir" --strip-components=1
    rm -f "$tmp"
}
gitclone() {
    local name=$1 url=$2 dir=$3 ref=${4:-}
    if [ -d "$SRC/$dir/.git" ]; then echo "[$name] 仓库已在"; return 0; fi
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
    ./configure --prefix="$PREFIX" --host="$TARGET$API" \
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
c_args = ['--target=$TARGET$API', '--sysroot=$SYSROOT', '-fPIC', '-O2', '-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib']
cpp_args = ['--target=$TARGET$API', '--sysroot=$SYSROOT', '-fPIC', '-O2', '-I$PREFIX/include']
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

for t in ar nm ranlib strip readelf objdump; do
    [ -f "$TOOLCHAIN/bin/llvm-$t" ] && ln -sf "llvm-$t" "$TOOLCHAIN/bin/${TARGET}-$t"
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
    ./Configure android-arm64 no-shared no-tests no-asm no-engine no-apps \
        --prefix=$PREFIX --openssldir=$PREFIX/ssl --sysroot=$SYSROOT \
        "-D__ANDROID_API__=$API" "-fPIC"
    make build_libs -j$(nproc)
    make install_sw install_ssldirs -j$(nproc) >/dev/null
    cp -f libcrypto.a libssl.a $PREFIX/lib/
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
    do_meson fontconfig -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Duuid=internal
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
    ./configure --prefix=$PREFIX --host=$TARGET$API \
        --cross-prefix=$TOOLCHAIN/bin/${TARGET}${API}- \
        --enable-static --enable-pic --disable-cli --disable-opencl --disable-lavf
    make -j$(nproc); make install
}
b_x265() {
    fetch x265 https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.0.1.tar.gz x265
    local d=$SRC/x265/source
    rm -rf "$d/build"; mkdir -p "$d/build"; cd "$d/build"
    cmake -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$API -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_CLI=OFF \
        -DENABLE_ASSEMBLY=ON -DENABLE_NEON=ON \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON ..
    cmake --build . -j"$(nproc)"; cmake --install .
    write_pc x265 4.0.1 "-lx265"
}
b_dav1d() {
    fetch dav1d https://code.videolan.org/videolan/dav1d/-/archive/1.5.1/dav1d-1.5.1.tar.bz2 dav1d
    do_meson dav1d -Dtests=false -Ddocs=false -Dasm=enabled
}
b_aom() {
    gitclone aom https://aomedia.googlesource.com/aom aom v3.11.0
    do_cmake aom -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TOOLS=OFF \
        -DENABLE_DOCS=OFF -DCONFIGURE_TESTS=OFF -DAOM_TARGET_CPU=arm64 \
        -DENABLE_NEON=ON -DCONFIG_RUNTIME_CPU_DETECT=ON
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
rustflags = ["-C", "link-arg=--sysroot=$SYSROOT", "-C", "link-arg=-static-libstdc++",
             "-C", "link-arg=-L$PREFIX/lib"]
EOF
    cargo build --release --target aarch64-linux-android
    install -m 644 target/aarch64-linux-android/release/librav1e.a $PREFIX/lib/
    install -m 644 rav1e.h $PREFIX/include/
    write_pc rav1e 0.7.1 "-lrav1e -lcsydyz -lnum_bigint -lnum_traits"
}
b_vpx() {
    fetch vpx https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.0.tar.gz vpx
    cd "$SRC/vpx"
    ./configure --prefix=$PREFIX --target=arm64-android-gcc \
        --enable-static --disable-shared --disable-examples --disable-unit-tests \
        --disable-tools --disable-docs --disable-better-hw-compression \
        --extra-cflags="-fPIC -I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib"
    make -j$(nproc) libs
    make install
}
b_xvid() {
    fetch xvid https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.bz2 xvid
    cd "$SRC/xvid/build/generic"
    ./configure --prefix=$PREFIX --host=$TARGET$API --build=x86_64-pc-linux-gnu
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
b_theora() { fetch theora https://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.xz theora; do_autotools theora --disable-examples --disable-spec; }
b_lame()   { fetch lame https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz lame; do_autotools lame --disable-frontend; }
b_amrnb()  { fetch amr https://sourceforge.net/projects/opencore-amr/files/opencore-amr/opencore-amr-0.1.6.tar.gz opencore-amr; do_autotools opencore-amr; }
b_amrwb()  { fetch voamr https://sourceforge.net/projects/opencore-amr/files/vo-amrwbenc/vo-amrwbenc-0.1.3.tar.gz vo-amrwbenc; do_autotools vo-amrwbenc; }
b_gme()    { gitclone gme https://bitbucket.org/mpyne/game-music-emu.git gme; do_cmake gme; }
b_mpg123() { fetch mpg123 https://mpg123.de/mpg123-1.32.9.tar.bz2 mpg123; do_autotools mpg123 --disable-modules --disable-network --with-realtime=none; }
b_openmpt() {
    fetch openmpt "https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-0.7.13.0%2Bautotools.tar.gz" openmpt
    do_autotools openmpt --disable-openmpt123 --disable-tests --disable-example \
        --without-sdl --without-liblzo2 --enable-mpg123
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
b_vidstab() { fetch vidstab https://public.hronopik.de/vid.stab/files/libvidstab-1.1.1.tar.gz vidstab; do_cmake vidstab; }
b_mysofa()  { fetch mysofa https://github.com/hoene/libmysofa/archive/refs/tags/v1.3.2.tar.gz mysofa; do_cmake mysofa -DJSON_TESTS=OFF -DCMOD_TESTS=OFF; }
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
    do_cmake jxl -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
        -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
        -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_SKCMS=OFF \
        -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_ENABLE_VIEWERS=OFF
}
b_vmaf() {
    fetch vmaf https://github.com/Netflix/vmaf/archive/refs/tags/v3.0.0.tar.gz vmaf
    cd "$SRC/vmaf/libvmaf"
    rm -rf build
    meson setup build . --cross-file "$BUILD_ROOT/cross.txt" --prefix=$PREFIX \
        --default-library=static --buildtype=release \
        -Denable_tests=false -Denable_docs=false -Dbuilt_in_models=true -Dasm=true
    ninja -C build; ninja -C build install
}

# ============================================================================
# 第 6 层：Vulkan / GPU（清单里最重）
# ============================================================================
b_glslang() {
    fetch glslang https://github.com/KhronosGroup/glslang/archive/refs/tags/15.1.0.tar.gz glslang
    do_cmake glslang -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DENABLE_HLSL=OFF -DBUILD_TESTING=OFF
}
b_placebo() {
    fetch placebo https://code.videolan.org/videolan/libplacebo/-/archive/v6.338.0/libplacebo-v6.338.0.tar.bz2 placebo
    cd "$SRC/placebo"
    git submodule update --init --depth 1 src/vulkan src/gl 2>/dev/null || true
    do_meson placebo -Dvulkan=enabled -Dglslang=enabled -Dlcms=true \
        -Ddemos=false -Dtests=false -Dopengl=disabled -Dgles=disabled
}

# ============================================================================
# 第 7 层：网络 / 容器 / 光盘
# ============================================================================
b_xml2() {
    fetch xml2 https://github.com/GNOME/libxml2/archive/refs/tags/v2.13.5.tar.gz xml2
    do_cmake xml2 -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF \
        -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
        -DLIBXML2_WITH_ZLIB=ON -DLIBXML2_WITH_LZMA=ON
}
b_srt() {
    fetch srt https://github.com/Haivision/srt/archive/refs/tags/v1.5.3.tar.gz srt
    if have libcrypto.a; then
        do_cmake srt -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF \
            -DENABLE_TESTS=OFF -DUSE_ENCLIB=openssl
    else
        do_cmake srt -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF \
            -DENABLE_TESTS=OFF -DUSE_ENCLIB=mbedtls -DENABLE_MBEDTLS=OFF
    fi
}
b_libssh() { fetch libssh https://www.libssh.org/archive/libssh-0.11.1.tar.xz libssh; do_cmake libssh -DWITH_EXAMPLES=OFF -DWITH_GSSAPI=OFF -DWITH_SERVER=OFF -DUNIT_TESTING=OFF -DWITH_ZLIB=ON; }
b_zmq()    { fetch zmq https://github.com/zeromq/libzmq/releases/download/v4.3.5/zeromq-4.3.5.tar.gz zmq; do_cmake zmq -DZMQ_BUILD_TESTS=OFF -DWITH_LIBSODIUM=OFF -DWITH_TLS=OFF; }
b_bluray() { fetch bluray https://download.videolan.org/pub/videolan/libbluray/1.3.4/libbluray-1.3.4.tar.xz bluray; do_autotools bluray --disable-bdjava-jar --disable-examples; }
b_dvdread() { fetch dvdread https://download.videolan.org/pub/videolan/libdvdread/6.1.2/libdvdread-6.1.2.tar.xz dvdread; do_autotools dvdread --with-libcss=no; }
b_dvdnav()  { fetch dvdnav https://download.videolan.org/pub/videolan/libdvdnav/6.1.1/libdvdnav-6.1.1.tar.xz dvdnav; do_autotools dvdnav --with-libcss=no; }

# ============================================================================
# 第 8 层：Android 上无意义的（X11 / V4L2 / OpenCL），试了不行就丢
# ============================================================================
b_xcb()  {
    fetch xcb https://www.x.org/releases/individual/lib/xcb-1.17.1.tar.xz xcb
    do_autotools xcb --disable-static=false
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
run_step openssl    b_openssl
run_step libpng     b_libpng
run_step freetype   b_freetype
run_step fribidi    b_fribidi
run_step harfbuzz   b_harfbuzz
run_step fontconfig b_fontconfig
run_step libass     b_libass
run_step x264       b_x264
run_step x265       b_x265
run_step dav1d      b_dav1d
run_step aom        b_aom
run_step svtav1     b_svtav1
run_step rav1e      b_rav1e
run_step vpx        b_vpx
run_step xvid       b_xvid
run_step opus       b_opus
run_step ogg        b_ogg
run_step vorbis     b_vorbis
run_step theora     b_theora
run_step lame       b_lame
run_step amrnb      b_amrnb
run_step amrwb      b_amrwb
run_step gme        b_gme
run_step mpg123     b_mpg123
run_step openmpt    b_openmpt
run_step soxr       b_soxr
run_step bs2b       b_bs2b
run_step fftw       b_fftw
run_step samplerate b_samplerate
run_step rubberband b_rubberband
run_step zimg       b_zimg
run_step vidstab    b_vidstab
run_step vmaf       b_vmaf
run_step mysofa     b_mysofa
run_step lcms2      b_lcms2
run_step webp       b_webp
run_step brotli     b_brotli
run_step highway    b_highway
run_step jxl        b_jxl
run_step glslang    b_glslang
run_step placebo    b_placebo
run_step xml2       b_xml2
run_step srt        b_srt
run_step libssh     b_libssh
run_step zmq        b_zmq
run_step bluray     b_bluray
run_step dvdread    b_dvdread
run_step dvdnav     b_dvdnav
run_step xcb        b_xcb
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
flag libogg.a               --enable-libogg
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
flag liblcms2.a             --enable-liblcms2
flag libwebp.a              --enable-libwebp
flag libjxl.a               --enable-libjxl
flag libxml2.a              --enable-libxml2
flag libzmq.a               --enable-libzmq
flag libzmq.so              --enable-libzmq
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
flag libxcb.a               --enable-libxcb
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

./configure \
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
    ${ENABLE_FLAGS[@]+"${ENABLE_FLAGS[@]}"}

make -j$(nproc)
make install

BIN=$PREFIX/bin/ffmpeg
[ -x "$BIN" ] || { echo "FATAL: 未产出 ffmpeg 可执行文件"; exit 1; }
cp -f "$BIN" "$BUILD_ROOT/ffmpeg-unstripped"
"$STRIP" --strip-unneeded "$BIN"
cp -f "$BIN" "$PREFIX/lib/libffmpeg.so"
chmod 755 "$PREFIX/lib/libffmpeg.so"

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
} | tee "$BUILD_ROOT/build-report.txt"

echo ""
echo "=== 完成 ==="
