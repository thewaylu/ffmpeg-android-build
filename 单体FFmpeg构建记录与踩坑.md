# FFmpeg 9.0.2 单体 libffmpeg.so（Android arm64）构建记录与踩坑

> 记录时间：2026-11-03 深夜。全程用 GitHub Actions 交叉编译，run #71 → #98（约 28 轮），
> 其中红叉失败约 20 轮。本文只写**真实发生过**的现象与根因，不写假设。

---

## 一、最终结果

> run #101（commit `fb6a6e1`）：失败库 0，`vulkan 状态: 启用`，`被临时摘掉的开关: 无`。

| 项目 | 结果 |
|---|---|
| 产物 | `libffmpeg.so` 59,461,536 字节（strip 后）；未 strip 215 MB；artifact 压缩包 27 MB |
| 形态 | PIE 可执行 ELF（`Type: DYN`），AArch64 —— App 用 `Bin.exec` 直接执行它 |
| 动态依赖 | **仅 7 个系统库**：`libm libandroid libcamera2ndk libmediandk libdl libc liblog`（vulkan 走运行时加载，没有 `NEEDED libvulkan.so`） |
| 依赖库 | 49 个编译成功，1 个主动放弃（libssh） |
| 启用开关 | 36 个库开关 + `--enable-vulkan` + `--enable-mediacodec` + `--enable-jni` + `--enable-lcms2` |
| 装机位置 | `/sdcard/Android/data/com.silentlexx.ffmpeggui/files/bin/ffmpeg_9.02.so`（u0_a471:u0_a471, 770） |
| 独立运行验证 | `LD_LIBRARY_PATH=/system/lib64:/vendor/lib64` 下 `-version` 正常输出 |
| 真实转码验证 | x265+opus ✓ x264+mp3 ✓ SVT-AV1+aac ✓（回读为 libdav1d 解码）JPEG XL ✓ |
| 手机实测（vs Termux 9.0.2） | 编码器 214 / 218，**解码器 547 / 547 零差异**，滤镜 494 / 535 |

### 与 Termux 官方 9.0.2 的差距（vulkan/openmpt 已找回后）

Termux 配置行是权威目标（45 个 `--enable-*`）。当前差距：

- **解码器：零差异**（547 = 547，openmpt 回来后 mod/s3m/xm/it 补齐）
- 软件编码器：**无差异**（x264/x265/aom/dav1d/svtav1/vpx/xvid/opus/vorbis/theora/lame/amrb 系/gme/openmpt/soxr/zimg/vmaf/mysofa/webp/jxl/xml2/zmq/srt/openssl/bluray/dvd*/ass/freetype/fribidi/harfbuzz/fontconfig/lcms2 全在）
- 仍缺的 4 个编码器：`librav1e` + `av1_vulkan` / `ffv1_vulkan` / `prores_ks_vulkan`
  （`h264_vulkan` / `hevc_vulkan` 已随 `--enable-vulkan` 回来）
- 仍缺的 41 个滤镜：`*_vulkan` 与 `*_opencl` 的 GPU 版本 + `libplacebo` + `vidstab*`

**剩余差距基本收敛到一个根因：`libplacebo`。**
FFmpeg 8+ 把绝大多数 `*_vulkan` 滤镜和大部分 vulkan 编码器迁到了 placebo 后端，
所以只开 `--enable-vulkan` 只能带回 `h264/hevc_vulkan` 和少量滤镜。
placebo 卡在其 meson 的 `find_library('SPIRV')` 不接受纯静态库
（`libSPIRV.a` 我们已经编出来了，在 `$PREFIX/lib` 里）。



---

## 二、构建架构（build.sh 的骨架）

```
分层构建 49 个依赖库  →  按实际产物动态拼 ffmpeg 开关  →  configure/make  →
把 $PREFIX/bin/ffmpeg 复制成 libffmpeg.so  →  NEEDED 白名单校验  →  推到 dist 分支
```

几个关键设计：

1. **开关按产物动态拼装**（`flag <探测文件> <开关>`）。绝不硬写 `--enable-libxxx`，
   否则少编一个库就整个 configure 失败。
2. **每个库必须有产物校验**（`run_step <名> <函数> <期望的 .a>`）。返回 0 但没有 `.a`
   叫"假成功"，必须判失败。
3. **增量缓存带参数指纹**：done 标记文件名是 `名字.$(declare -f 函数 | cksum)`，
   改了编译参数 → 签名变 → 自动重建。
4. **失败日志自动回传**：`if: failure()` 用 `actions/github-script` + `GITHUB_TOKEN` 开
   issue，正文含完整 build-report。**不需要人复制日志**，也不需要 token 下载 artifact。
5. **成功产物推到 `dist` 分支**（`git push --force`，用 `GITHUB_TOKEN`），这样
   `git clone -b dist` 就能取，绕开 artifact 下载需要登录的问题。

---

## 三、坑清单（按"值得记住"排序）

### A 类：bash / 脚本自身的坑（最浪费时间，因为报错完全看不出因果）

**A1. `local` 同行多变量赋值 —— 变量未定义**

```sh
local name=$1 fn=$2 log=$LOGDIR/$name.log   # ✗ name: unbound variable
```

bash 的 `local` 会**先展开整行**再赋值，`$name` 此时还是空。`set -u` 下直接崩，
表现为脚本启动 1 秒失败。run #70/#71 就是这么死的。修法：拆两行。
同类：`expect=${3:-}`（`set -u` 下 `$3` 未定义会崩，`local expect=$3` 不会 —— 但独立赋值会）。

**A2. `fetch` 在解压前 `rm -rf` 源目录 → 46 个库连锁失败**

原逻辑下载后先 `rm -rf "$SRC/$dir"`，如果下载其实失败了（curl 返回 0 字节），
目录被删空，后续所有库都"没有源码"。修法：下载 → 校验存在性 + 魔数 → 解压成功才删临时文件。

**A3. xz 魔数写成 `fd75`（正确是 `fd37`）**

所有 `.tar.xz`（含 ffmpeg 本体）被误判为"下载内容不是压缩包"而拒绝。run #75 全线失败。
一个字符的错，日志里只表现为"拒绝"，极难看出是自己写错常数。

**A4. 多源 URL 只加了参数没加循环**

commit `081e3a5` 把 ffmpeg 源写成 `"url1 url2"`（一个参数含空格），但 `fetch()` 函数体
仍是单 URL 调用 → curl 报 `URL rejected: Malformed input to a URL function`。
教训：**改了参数形态必须同时改解析处**，否则下一轮必然失败。

**A5. `configure` 只重定向 stderr**

FFmpeg 的真实错误在 stdout（`Unknown option` / `ERROR: xxx not found`），
`> log 2>/dev/null` 会把唯一有用的信息丢掉。必须 `>"$log" 2>&1`。

**A6. 报告只打印"第一条错误行"**

libssh 的第一条错误是 `Could NOT find NaCl`（可选依赖的 warning），真正的 fatal 在其后。
表现为"看起来没问题但就是失败"。修法：同时附日志尾部。

**A7. `head -12` 把关键信息截掉**

逐库探测的输出里，前 12 行全是 `deprecated` warning，真正的
`ld.lld: error: undefined symbol: ov_open_callbacks` 在第 13 行之后。
修法：`grep -E 'error|undefined|cannot'` 再取前几行。

---

### B 类：Android / bionic 与 NDK 的坑

**B1. bionic 没有 `libpthread`**

`-lpthread` 直接 `unable to find library`。两个来源都要处理：
- 自己的 `--extra-libs` 里删掉
- **依赖库的 `.pc` 里写死了 `-lpthread`**（srt/zmq/harfbuzz 的 `Libs.private`），
  `pkg-config --static` 会把它塞进 ffmpeg 的探测命令 → 表现为
  `ERROR: srt >= 1.3.0 not found using pkg-config`（错误信息完全不提 pthread，极易误判）。
  修法：链接前 `sed -i 's/[[:space:]]-lpthread//g' $PREFIX/lib/pkgconfig/*.pc`

**B2. `std::__ndk1::*` 未定义符号**

libjxl_threads / x265 / rubberband 这些 C++ 静态库需要 libc++ 静态版：
`--extra-libs` 追加 `-lc++_static -lc++abi`。

**B3. `libc++_shared.so` 混进 NEEDED**

`.pc` 里写 `-lc++` 或 `-lstdc++` 时，链接器会解析到 sysroot 的 `libc++_shared.so` 桩，
单体就多了个外部依赖。修法：sed 把 `-lstdc++` / `-lc++`（后面跟空格或行尾）统一换成
`-lc++_static -lc++abi`。注意别把 `-lc++_static` 自己二次替换。

**B4. `$PREFIX/lib` 里只要留着 `.so` 副本，`-lxxx` 就优先选它**

这是 NEEDED 里混入 `libzmq.so`、`libopenmpt.so.4` 的**真正根因**。
链接器对 `-lzmq` 的处理是"同一目录里 .so 优先于 .a"。
修法：ffmpeg 链接前 `find $PREFIX/lib -maxdepth 1 -name '*.so*' -delete`。
副作用可控：只有 `.so` 的库（如 libv4l2）探测会失败，而自动降级机制会把那个开关摘掉。

**B5. NDK 交叉模式下 CMake 的 `find_library` 被 rooted 挡住**

NDK 的 `android.toolchain.cmake` 设了 `CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY`，
所以 `OPENSSL_ROOT_DIR=$PREFIX` 也找不到 `$PREFIX/lib/libcrypto.a`。
修法：显式给三个 cache 变量绕开查找：
`-DOPENSSL_INCLUDE_DIR=… -DOPENSSL_CRYPTO_LIBRARY=$PREFIX/lib/libcrypto.a -DOPENSSL_SSL_LIBRARY=…`

**B6. libzmq 不吃 `BUILD_SHARED_LIBS`**

它用自己的 `BUILD_SHARED` / `BUILD_STATIC` 开关，默认 `BUILD_SHARED=ON`。
必须显式 `-DBUILD_SHARED=OFF -DBUILD_STATIC=ON`。

**B7. vulkan：NDK 有头、有 stub 库，但没有 pkg-config 元数据**

FFmpeg 9 用 `check_pkg_config vulkan "vulkan >= 1.3.251"` 找它，缺 `.pc` 就
`ERROR: vulkan requested but not found`，**整个 configure 退出**。
修法：自己造一个 `vulkan.pc`，`Version: 1.3.$VK_HEADER_VERSION`（低于 251 就写 251），
`Cflags: -I$SYSROOT/usr/include`，`Libs: -lvulkan`。

**B8. 老 autotools 的 `config.sub` 不认 `aarch64-linux-android`**

表现为 `configure: error: /bin/bash build-aux/config.sub aarch64-linux-android failed`，
上一行是 `machine 'aarch64-linux' not recognized`。theora 1.1.1、bs2b 3.1.0 都中过。
修法：把 `/usr/share/automake-*/config.{sub,guess}` 拷过去覆盖。
注意 bs2b 的 config.sub 在 `build-aux/` 子目录。

---

### C 类：静态合并特有的坑（单体构建的核心难点）

**C1. 依赖库的全局符号与 FFmpeg 内部符号撞名 —— `duplicate symbol`**

```
ld.lld: error: duplicate symbol: dec_init
>>> defined at ffmpeg_dec.c            (fftools/ffmpeg_dec.o)
>>> defined at dec.c                   (libbluray_la-dec.o in libbluray.a)
```

libbluray 的 `dec_init` 漏写 `static`，是全局符号。
**不要用 `-Wl,--allow-multiple-definition`**：它"先出现者胜"，ffmpeg 的实现会赢，
而 libbluray 内部对 `dec_init` 的调用会绑到 ffmpeg 那个完全不同的实现上 → 运行时错乱。
也不要用 `objcopy --localize-symbol`：局部化后跨文件的调用会变成 undefined。
正确做法：**源码改名**（定义与调用一起改）：

```sh
find "$SRC/bluray/src" \( -name '*.c' -o -name '*.h' \) -print0 \
  | xargs -0 -r sed -i 's/\bdec_init\b/bluray_dec_init/g'
```

**C2. "假成功"库：构建返回 0 但产物名不对，导致开关永远不生效**

xvid 的产物叫 `xvidcore.a`（没有 `lib` 前缀），而探测和 ffmpeg 都按 `lib*.a` 找 →
`--enable-libxvid` **从未生效过**，但 xvid 一直显示在"成功 49 库"名单里。
修法：`cp -f "$xal" $PREFIX/lib/libxvidcore.a` + `run_step xvid b_xvid libxvidcore.a`。
同类：xvid 还漏装 `xvid.h`（`build/generic` 的 make install 不装头），而 ffmpeg 的
libxvid 探测要同时看到头文件和符号。

**C3. `.pc` 少了传递依赖 → 探测失败但错误信息不提真因**

libopenmpt 内嵌的 modplug 用 libvorbisfile 解 OGG，`.pc` 里不写 `-lvorbisfile` 就报
`undefined symbol: ov_open_callbacks / ov_streams`，而 ffmpeg 只告诉你
`ERROR: libopenmpt >= 0.2.6557 not found using pkg-config`。
`libvorbisfile.a` 其实早就编出来了。

**C4. 只有 shared 版本的库不能直接删 `.so`**

libopenmpt 的 **makefile 版只产出 `.so`，没有 `.a`**。我按"删 .so 逼链接器用 .a"的思路
执行 `rm -f $PREFIX/lib/libopenmpt.so*`，等于把库删空 —— 而且这个空状态被存进了 CI 缓存，
下一轮该库显示 `(cached)` 直接跳过，于是表现为"库明明成功了，ffmpeg 却说找不到"。
修法：换 **autotools 版** tarball + `do_autotools`（`--enable-static --disable-shared`）。
教训：**删产物之前必须先确认另一种形态存在**。

**C5. 手写 `.pc` 覆盖掉官方 `.pc`，会永久丢失传递依赖**

这个坑绕了三轮才看清。libopenmpt 的 autotools 安装会生成带
`Requires.private: ogg vorbisfile mpg123` 的 `.pc`；我用 `write_pc` 写了一份只有
`-lopenmpt -lm …` 的覆盖掉它。后果是逐轮"打地鼠"：

```
第 1 轮  undefined symbol: ov_open_callbacks  → 我补 -lvorbisfile
第 2 轮  undefined symbol: mpg123_new         → 说明还缺 mpg123
```

而 ffmpeg 永远只报一句 `ERROR: libopenmpt >= 0.2.6557 not found using pkg-config`，
完全看不出是依赖传递问题。正确做法是**让官方 `.pc` 生效**，最多用 sed 微调它
（比如把 `-lstdc++` 换成 `-lc++_static`），不要整份重写。
凡是 autotools/CMake 自己会装 `.pc` 的库，都不要 `write_pc` 覆盖。

---

## 三B、vulkan 为什么"探测通过却仍被判定不可用"

逐库静态探测的结果是 `[vkCreateInstance via vulkan] 通过`，但 configure 依然报
`ERROR: vulkan requested but not found`。原因不在链接，而在**头文件的版本宏**：
FFmpeg 9 会读 `vulkan_core.h` 里的 `VK_HEADER_VERSION` 并要求 >= 251，
而 NDK r27 sysroot 自带的那份偏旧。`.pc` 里把 `Version:` 写成 1.3.275 是没用的
（那只是 pkg-config 的比较值，宏还是老值）。

修法：从 Khronos 拉 Vulkan-Headers 装到 `$PREFIX/include/vulkan`，并让 `vulkan.pc`
的 `includedir` 优先指向它。

**然后踩到第二层**：新版 Vulkan-Headers 把视频编解码头拆到了兄弟目录，
`vulkan_core.h` 里有 `#include <vk_video/vulkan_video_codec_av1std.h>`。
只拷 `include/vulkan/` 的结果是：

```
install/include/vulkan/vulkan_core.h:11357: fatal error:
    'vk_video/vulkan_video_codec_av1std.h' file not found
```

即"修 A 引入 B"——装新头本身是对的，但**必须整份拷 `include/`**
（`vk_video/`、`vk_struct_helper/` 都要）。

这个坑的教训：**`.pc` 的版本字段和头文件里的版本宏是两回事**，交叉编译时
sysroot 自带的头经常比上游要求的老，而报错信息不会告诉你是版本问题；
另外装"纯头文件包"时不要按目录名挑，要整个 include 拷过去。

---

## 三C、依赖库的 `.pc` 元数据不可信

即使不再覆盖官方 `.pc`，libopenmpt 的 `Requires.private` 也**没有列全**：
它的 modplug 用外部 libmpg123 解嵌入的 MP3（`SampleFormatMP3.cpp` 引用
`mpg123_new` / `mpg123_param2`），但官方 `.pc` 只写了 ogg/vorbis 那几个。

最终不再逐轮猜缺什么，而是在 ffmpeg 的 `--extra-libs` 里一次性兜住：

```
--extra-libs="… -lc++_static -lc++abi -lmpg123 -lvorbisfile -lvorbis -logg"
```

前提：这些 `.a` 都已存在（清单核对过），否则会反过来拖死所有 configure 探测。
教训：**上游 `.pc` 的依赖声明在交叉编译场景下经常不完整**，逐轮"报一个补一个"
每轮要等 5–20 分钟，不如一次性把候选依赖列进链接参数再验证。

---



### D 类：上游项目本身的坑

**D1. libvpx 的头是"不完整安装"，而全局 CFLAGS 带 `-I$PREFIX/include`**

```
install/include/vpx/vpx_frame_buffer.h:22: fatal error: './vpx_tpl.h' file not found
```

libvpx 的 `make install` 不装 `vpx_tpl.h` / `vpx_integer.h`，但装了引用它们的头。
一旦上一轮缓存里存在 `install/include/vpx`，本轮编译 libvpx 自己就会命中这套残缺头。
**所以它时好时坏**——取决于缓存里有没有那个目录（run #84 失败、#85 成功）。
修法：构建 libvpx 前 `rm -rf $PREFIX/include/vpx`，并用局部 `CFLAGS="-fPIC -O2"` 隔离。

**D2. rubberband 3.x 起改成 meson 工程，没有 `configure.ac`**

`autoreconf: error: 'configure.ac' is required`。改 `do_meson` 后注意 meson 的
内置选项名是 **下划线** `-Dauto_features=disabled`（写成连字符报 `Unknown option`）。
另外它需要 FFTW **双精度**，而原先 fftw 带 `--enable-single` 只产出 `libfftw3f` → 顺带修。

**D3. bs2b 3.1.0 里 `bml37.c` / `cbs2b.c` 已合并进 `bs2b.c`**

按老资料编三个文件必然 `no such file`。`src/` 目录里只有 `bs2b.c` 是库实现。
最终绕开 autotools，手工编一个 `.c` + `ar` 打包，反而最稳。

**D4. FFmpeg 的"非法开关"会让整个 configure 退出**

踩过：`--enable-libogg`（ogg 没有独立开关）、`--enable-liblcms2`（真名是 `--enable-lcms2`）、
`--enable-libxcb`（要配 `--enable-libxcb-shm/-xfixes/-shape`）、`--enable-libmpg123`、
`--enable-libresample`（后两个 FFmpeg 9 已无此选项）。
**一个未知选项 = 零产物**，且报错只有一行 `Unknown option "--enable-xxx"`。
所以开关名要以目标平台的权威配置行为准（这里就是 Termux 的 `configuration:` 行）。

**D5. ffmpeg.org 对 CI 连续 SSL 超时**

`curl: (28) SSL connection timeout`。修法：多候选源轮试（ffmpeg.org → GitHub tag 归档）
+ curl 失败再用 wget 兜底。GitHub 的 `refs/tags/n9.0.2.tar.gz` 归档可用，只是没有
`RELEASE` 文件（版本号显示不受影响）。

**D6. rav1e 被全局 LDFLAGS 污染 host 构建**

`libz.a incompatible with elf64-x86-64` —— cargo 给 build script 编译 host 工具时
继承了指向 aarch64 的 `LDFLAGS`/`CFLAGS`。需要 `env -u LDFLAGS -u CFLAGS -u PKG_CONFIG_*`。
最终因功能与 aom/svtav1 重复而放弃。

---

### E 类：CI 与工具链的坑

**E1. 缓存的 `done/` 标记不带参数指纹 → 改了编译参数不生效**

soxr 加了 `-DWITH_OPENMP=OFF` 却完全不生效（旧标记仍在，直接跳过重建），
下一轮还是同样的 `__kmpc_fork_call` 错误。这是**最阴**的一类浪费：
你以为在验证修复，其实在验证旧产物。

**E2. 缓存里的旧 `$PREFIX/bin/ffmpeg` 冒充本轮成功**

run #91 只用 **2 分钟就变绿**：本轮 configure 其实失败了，但脚本用
`[ -x "$BIN" ]` 当成功标准，而 `$BIN` 是上一轮 `make install` + strip 后留在缓存里的。
于是拿旧产物冒充新结果，还推上了 `dist` 分支。
修法：进 ffmpeg 段先 `rm -f $PREFIX/bin/ffmpeg $PREFIX/lib/libffmpeg.so …`，
并且 `FF_OK != 1` 或单体不合格一律 `exit 1` 让 CI 变红。

**E3. 并行 run 共享同一缓存 key → 结果抖动**

run #84 与 #85 同时跑（两次 push 间隔 49 秒），vpx 一个失败一个成功。
之后坚持"一次只推一个 commit，等结果再推下一个"。

**E4. 自动降级逻辑"无条件先摘 vulkan"**

我的重试循环第一次失败时不管错误是什么都先摘 `--enable-vulkan`。
而逐库探测显示 `vkCreateInstance via vulkan` **链接通过** —— vulkan 是被冤枉的，
真凶是 openmpt。代价是白丢 5 个 GPU 编码器和三十几个滤镜。
修法：只在错误行真的提到 vulkan 时才摘它。

**E5. `raw.githubusercontent.com` 有 CDN 缓存**

我取 `dist` 分支的 build-report.txt，拿到的是**上一轮**的内容，于是误判"诊断代码没执行"。
改用 `GET /repos/{o}/{r}/contents/{path}?ref=dist`（base64）才拿到真实文件。

**E6. Git Bash 的 https 通道不可用**

`fatal: Unsupported SSL backend 'schannel'`，`GIT_SSL_BACKEND=openssl` 也被顶掉。
统一走 SSH（`GIT_SSH_COMMAND="ssh -i …/id_ed25519_github"`）。
另外 node 的 fetch 缺 CA → 必须 `node --use-system-ca`。

**E7. 产物回传速度**

本机到 GitHub raw 约 10 KB/s、手机约 15 KB/s，55 MB 要一小时以上。
最终靠 IDM 多线程下载 Actions artifact（26 MB 压缩包）解决。

---

## 四、方法论（这次真正管用的三件事）

1. **让 CI 自己把日志送回来看得见的地方**。失败自动开 issue（正文含完整报告），
   全程不需要人复制粘贴日志。这是能把迭代次数扛到 28 轮的前提。
2. **每一步都要"证明它真的做了"**：库要校验 `.a` 存在、缓存要带参数指纹、
   进 ffmpeg 前要删旧产物、产物要过 NEEDED 白名单。
   这次约一半的红叉来自"某处谎报成功"，而不是真编译错误。
3. **判断"是不是单体"只看 `readelf -d` 的 NEEDED 清单**，不看文件大小、
   不看构建是否绿。为此专门加了白名单校验，不合格就 `rm` 产物 + `exit 1`。

---

## 五、验证方法（可复用）

```sh
# 1) 形态与依赖
readelf -h   libffmpeg.so | grep -E 'Type|Machine'     # 期望 DYN + AArch64
readelf -d   libffmpeg.so | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'
#    合格线：只允许 libm/libc/libdl/liblog/libandroid/libmediandk/libcamera2ndk

# 2) 手机上只给系统路径也要能跑
adb/ssh: LD_LIBRARY_PATH=/system/lib64:/vendor/lib64 ./libffmpeg.so -hide_banner -version
#    注意 scp 过去要 chmod 755，否则 "can't execute: Permission denied"

# 3) 与 Termux 版逐项对比
$S -hide_banner -encoders | awk '/^ ../{print $2}' | sort > s.enc
$T -hide_banner -encoders | awk '/^ ../{print $2}' | sort > t.enc
comm -13 s.enc t.enc        # Termux 有而单体没有的

# 4) 真实转码（比 -version 更能证明库真链上了）
./libffmpeg.so -f lavfi -i testsrc=size=640x360:rate=25:duration=3 \
               -f lavfi -i sine=frequency=440:duration=3 \
               -c:v libx265 -preset ultrafast -c:a libopus out.mkv
```

`mediacodec`（`h264_mediacodec` 等硬编硬解）**只能在 App 进程内验**，root shell 里跑不通。

---

## 六、当前遗留

| 项 | 状态 | 说明 |
|---|---|---|
| `libopenmpt` | **已找回**（run #101） | 官方 `.pc` 生效 + `--extra-libs` 补 `-lmpg123 -lvorbisfile -lvorbis -logg`，带回 mod/s3m/xm/it |
| `--enable-vulkan` | **已找回**（run #101） | 整份拷 Vulkan-Headers 的 `include/`（含 `vk_video/`）后一次通过；且 NEEDED 里没有 libvulkan，走运行时加载 |
| `libssh` | 主动放弃 | CMake install 找不到自身静态产物，四轮未解；只服务 sftp 协议 |
| `libv4l2` | 主动放弃 | 只出 `.so`；是视频采集接口，App 内转码用不到 |
| `rav1e` / `placebo` / `vidstab` / `xcb` | 主动放弃 | 理由见第一节 |
| 自动开 issue 的步骤 | 调试结束后应关闭 | 历史 issue #1–#24 可在网页直接删除 |
| 逐库探测的 `FFLIBS` 变量 | 小瑕疵 | 没同步 `--extra-libs` 的新增依赖，所以报告里 openmpt 探测仍显示"失败"，而真实 configure 已通过——看 `vulkan 状态` 和 `被临时摘掉的开关` 才准 |


---

## 八、收尾状态与下次继续的入口

**当前已知可用版本**：commit `fb6a6e1` / run #101 / 产物 59,461,536 字节，
已打 tag **`single-9.0.2-working`**。下次直接从它开始，不要回退到更早的脚本。

### 唯一剩下的突破口：libplacebo

FFmpeg 8+ 把 `*_vulkan` 滤镜和 `av1/ffv1/prores_ks_vulkan` 编码器接到 placebo 后端，
所以 placebo 一进，能同时带回约 30 个滤镜和 3 个编码器。

它此前失败的确切位置（run #79 时代）：

```
libplacebo 的 meson.build: find_library('SPIRV') 只找 shared，
纯静态构建下找不到 → 配置失败
```

突破口（下次按顺序试）：

1. **`libSPIRV.a` 已经编出来了**（glslang 的产物，在 `$PREFIX/lib` 里），
   所以不是缺库，是缺 pkg-config 元数据。给 placebo 造一份
   `$PREFIX/lib/pkgconfig/SPIRV.pc`（`Libs: -L${libdir} -lSPIRV -lSPVRemapper`），
   让它用 `dependency('SPIRV')` 而不是 `find_library`。
2. 若仍走 `find_library`，用 meson 的 `-Dc_args`/`-Dlink_args` 或
   `--build.pkg_config_path` 提示；实在不行就 patch 它的 `meson.build`
   把 `find_library('SPIRV')` 换成 `dependency('SPIRV', static: true)`。
3. placebo 还要 `-Dlcms=enabled`（我们 `liblcms2.a` 有）、`-Dvulkan=enabled`、
   `-Dglslang=enabled`；注意它的 lcms 选项值必须是 `enabled/disabled/auto`，
   **不能写 `true`**（这个坑踩过，报 `Value "true" is not one of the choices`）。
4. 一旦 placebo 装上，ffmpeg 侧要加 `--enable-libplacebo` 和 `--enable-libglslang`
   （两个都是合法开关，Termux 旧配置行里出现过 `--enable-libglslang`）。

### 其它可选项（收益低，按需）

- `--enable-opencl`：Termux 有。需要 `CL/cl.h` + `-lOpenCL`，NDK sysroot 都提供，
  但产物会多一条 `NEEDED libOpenCL.so`（系统提供，可接受）。
- `libvidstab`：卡在 `emmintrin.h`（x8 intrinsics）。arm64 上要给它加
  `-DVIDEO_STABILIZER_NO_SSE=1` 之类的宏或注释掉那段，属于改上游源码。
- `libssh`：四轮未解，最后一招是不用它的 CMake install，改为
  `cmake --build` 后手工 `find build -name '*.a'` 拷进 `$PREFIX/lib`。
- `rav1e`：cargo 交叉构建 + host 工具污染，收益与 aom/svtav1 重复，建议永久放弃。

### 运维提醒

- 失败自动开 issue 的步骤**仍保留着**（下次继续攻还要用）。
  历史 issue #1–#24 是调试产物，可在网页仓库的 Issues 里勾选删除；
  删除需要仓库管理员权限，API 方式：`DELETE /repos/{owner}/{repo}/issues/{n}`。
- 推之前 `bash -n build.sh`；**一次只推一个 commit**（并行 run 会抢缓存导致结果抖动）。
- 取 `dist` 分支的报告要用 API 的 `contents` 端点，不要用
  `raw.githubusercontent.com`（有 CDN 缓存，会拿到上一轮的）。


## 九、下次升级版本怎么操作

1. 改 `build.sh` 里的 `FFMPEG_VER` 与依赖库版本号。
2. **同步更新权威配置行参照物**：从设备 Termux 里取
   `ffmpeg -version` 的 `configuration:` 行，用它核对 `flag` 列表里的开关名
   —— 这次至少 5 个红叉是开关名写错导致的。
3. 缓存 key 里带 `hashFiles('build.sh')`，改了脚本自动换新缓存；
   但 `restore-keys` 会命中旧缓存，所以**参数指纹机制不能去掉**。
4. 推之前 `bash -n build.sh`，并且**一次只推一个 commit**（避免并行 run 抢缓存）。
5. 产物合格线：`NEEDED` 白名单 + 手机上只给系统路径能跑 `-version`。
