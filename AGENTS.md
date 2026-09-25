# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## booTTY

- booTTY is Ghostty's source cut down to its macOS app. Code for other
  platforms, libghostty-vt, the WASM builds and Ghostty's project scaffolding
  were cut. booTTY merges upstream Ghostty now and then, through the merge
  script `README.md` points to.
- Never restore or recreate a path on the cut list (`.cutlist`).
- When kept code breaks because it reaches cut code, change only what breaks,
  with the smallest edit that builds:
  - An import of a cut file becomes `struct {}` on the same line, tagged
    `// booTTY: cut`.
  - In build code (`build.zig`, `src/build/`, `pkg/*/build.zig`), a branch
    taken only for a cut value becomes `@panic("<feature> was cut from booTTY")`,
    and a step that always builds a cut artifact is deleted.
- Leave dead platform code alone: the Linux and Windows branches in shared
  files, the GTK-only settings in `src/config/Config.zig`, dead selector values
  such as `gtk` and `opengl`, the GObject hooks, and the Linux and Windows glue
  in `src/os/`.
- Guides and comments still mention libghostty-vt, WASM, GTK or Linux builds in
  places, and those builds are gone. Where a guide says `test-lib-vt`, run
  `zig build test -Dtest-filter=<name>`, and skip `-Demit-lib-vt` and wasm32
  checks. The code rules they protect still hold, such as no libc or `src/simd`
  in the codecs in `src/terminal/compress/`.
- `CONTEXT.md` defines booTTY's domain terms (Window, Workspace, Tab, Split,
  agent status). Use its words, and avoid the ones it marks _Avoid_.

## Where things live

- Swift app: `macos/` (see `macos/AGENTS.md`). `macos/Sources/Ghostty/` calls
  the C API.
- C API: `include/ghostty.h`.
- Zig core: `src/`, reached through the embedded runtime
  (`src/apprt/embedded.zig`).
- Metal renderer: `src/renderer/Metal.zig` and `src/renderer/metal/`.
- CoreText fonts: `src/font/face/coretext.zig` and
  `src/font/shaper/coretext.zig`.
- Config: `src/config/Config.zig`.

## Commands

- Setup, including Xcode and nushell, is in `README.md`. The formatters come
  from Homebrew: `brew install swiftlint prettier`.
- **Build:** `zig build`
  - Add `-Demit-macos-app=false` to build only the library, which is faster.
- **Mac app:** `macos/build.nu`, as `macos/AGENTS.md` describes.
- **Test (Zig):** `zig build test`
  - Prefer targeted tests with `-Dtest-filter=<test name>` because the full
    test suite is slow.
- **Formatting (Zig):** `zig fmt build.zig build.zig.zon src pkg` (not
  `zig fmt .`, which would also rewrite the fetched packages in `zig-pkg/`)
- **Formatting (Swift):** `swiftlint lint --strict --fix`
- **Formatting (other):** `prettier -w .`

## Issues and PRs

- Never open issues or PRs on `ghostty-org/ghostty`.
- booTTY's GitHub issues are off. Plans live as local markdown maps in
  `.scratch/<effort>/`.
- Open a PR on booTTY only when the user asks for one.
