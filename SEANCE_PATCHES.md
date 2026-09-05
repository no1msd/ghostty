# Séance embedding patches

This fork merges upstream `492300cad104195411d12217dd22f1cd05f31376`
(2026-09-04, Zig 0.16.0) into the existing Séance branch. All seven original
patch commits remain ancestors; the merge adapts their behavior to the new APIs.

| Original commit | Behavior retained | Current implementation |
| --- | --- | --- |
| `4614b99b5` | Linux embedding with a host-owned OpenGL context; render on the application thread; recreate GPU resources after GTK reparenting | `GHOSTTY_PLATFORM_NONE`, embedded `must_draw_from_app_thread`, OpenGL context setup, and `ghostty_surface_renderer_realize/unrealize` in `include/ghostty.h`, `src/apprt/embedded.zig`, and `src/renderer/OpenGL.zig` |
| `08dc96920` | Export static libghostty to downstream Zig builds | `ghostty_static` compile artifact remains available; a named lazy path of the same name exposes upstream's complete combined archive, including bundled dependencies |
| `7e6de610a` | Build the embedded core without Xcode | `skip-macos-artifacts` selects OpenGL and disables both macOS app and XCFramework emission; Metal shaders are only initialized for Metal |
| `704009cd7` | Preserve indexed scrollback colors and refresh after theme changes | `vt_indexed` binding/export mode omits palette expansion; `Termio.changeConfig` notifies the renderer after updating colors |
| `a8ea4c69f` | Keep shared libraries out of the static archive | `SharedDeps.linkSystemLib` skips static compilation; the final consumer links system libraries |
| `6e3117a8e` | Supply headers without embedding system `.so` files | Freetype, Oniguruma, ImGui, and HarfBuzz retain include-only handling; HarfBuzz's new C translator keeps pkg-config inputs while its generated module omits system link objects |
| `3ceb26f30` | Provide Fontconfig headers to static consumers | Fontconfig's exported module includes upstream headers without linking a second Fontconfig implementation |

Additional Zig 0.16 compatibility: the Linux PTY name lookup declares the libc
`ptsname_r` ABI directly. Zig 0.16 mistranslates glibc's fortified inline wrapper;
the direct call retains the explicit buffer size and avoids that wrapper.

Validated on Arch Linux with Zig 0.16.0:

- Normal and `--system` ReleaseSafe builds of Séance.
- Indexed-color binding parser and existing VT foreground-color formatter tests.
- Séance unit tests and all 24 socket/terminal end-to-end tests under Xvfb.
- Integration tests for indexed scrollback save/restore, CLI screen reads,
  clipboard copy/paste, and terminal input after splits, moves, and closes.
- Screenshots of the system-library build confirm drawing after reparenting
  and closing panes; an idle config reload changes the rendered background.
- Combined archives contain only relocatable ELF objects, with no shared-library
  members. The executable imports system Fontconfig and defines no `Fc*` symbols.

macOS was reviewed for preservation of the embedding build options but was not
built or exercised on this Linux host.
