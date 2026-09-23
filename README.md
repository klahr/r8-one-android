# r8 One for Android

The [QDOS](https://github.com/quadrate-language/qdos) calculator as an Android
app. The shell runs on QDOS's SDL3 simulator backend, which SDLActivity loads as
`libmain.so`.

Everything it is built from is a submodule under `external/`, so a checkout
builds without downloading anything:

| Submodule | What |
|---|---|
| `external/qdos` | the shell and the simulator backend |
| `external/quadrate` | the Quadrate interpreter, parser and runtime |
| `external/libu8t` | Quadrate's UTF-8 tokeniser, normally a meson wrap |
| `external/SDL` | SDL3, native library and its Java half |

## Building

Needs the Android SDK and NDK, JDK 17, meson, ninja and cmake.

```bash
git submodule update --init
./build.sh                                  # native libraries only
./build.sh apk                              # and a debug APK
./build.sh install                          # and install it over adb
R8_ABIS="arm64-v8a x86_64" ./build.sh apk   # the emulator too
```

`ANDROID_NDK_HOME` picks the NDK; without it the newest in the SDK is used. The
APK lands in `app/build/outputs/apk/debug/`.

## F-Droid

`build.sh` with no target is the native step F-Droid runs before its own Gradle
build. `fdroid/` holds a draft of the fdroiddata metadata, and
`fastlane/metadata/` the store listing F-Droid reads from this repository.

## License

GPL-3.0-or-later, as QDOS. SDL is zlib, libu8t GPL-3.0, Quadrate GPL-3.0 and
Apache-2.0.
