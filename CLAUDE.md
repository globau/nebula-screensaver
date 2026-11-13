# Nebula

macOS screensaver (`.saver` bundle): endless flight through a crisp, filamentary supernova-remnant nebula, rendered with a filmic hdr pipeline. Swift + Metal, arm64, macOS 14+, only HiDPI screens matter. No Xcode project; everything builds via `make`.

## Ownership
Claude is the maintainer of this code and has complete ownership of it, with standing permission to refactor, restructure, rename or rewrite anything as it sees best. No need to ask before reorganising; keep this file accurate when doing so.

## Goal
The user wants a "Hollywood CGI" look first; CPU/GPU cost is to be tuned once the visuals are right.

## Layout
- `Sources/Saver/NebulaView.swift` — `ScreenSaverView` subclass (`@objc(NebulaView)`, the `NSPrincipalClass`). Frames come from `NSView.displayLink`, not `animateOneFrame`.
- `Sources/Saver/Tuning.swift` — all tunable constants; `shaderMacros` injects `WORLD_PERIOD` into the shader so it has a single source.
- `Sources/Saver/GPUTypes.swift` — `Uniforms`, `BloomStep`, mirrored by the structs at the top of `Shaders.metal`.
- `Sources/Saver/Random.swift` — `SplitMix64`.
- `Sources/Saver/FlightPath.swift` — endless centripetal Catmull-Rom spline (arc-length parametrised) through randomly swerving waypoints, after a straight run at the start.
- `Sources/Saver/Camera.swift` — starts at a seeded random position, heading and route (the saver seeds each view randomly, so every launch and screen differs); follows the path (faster during the intro), banks into turns, up vector by parallel transport. `worldPosition` is unwrapped; `position` is wrapped for the shaders.
- `Sources/Saver/MetalContext.swift` — shared device, pipelines and the baked 3D noise and sheet textures (one instance for every per-screen view).
- `Sources/Saver/Renderer.swift` — per-view camera, render targets and frame encoding.
- `Sources/Saver/Shaders.metal` — all gpu code (see the pass list below).
- `README.md`, `LICENSE` (MIT), `docs/screenshot.jpg` — the public repo's front page; the screenshot is seed 5 at 75 s, rendered 2880x1800 at 2x and saved as a 1920 px JPEG with `sips`. README prose follows the user's conventions: two spaces after full stops, straight quotes, ` - ` for dashes, and it states plainly that the project is vibe coded.
- `Sources/Harness/main.swift` — test app hosting the view in a window (Cmd+Q quits); `--snapshot path --time T --size WxH --scale S [--seed N]` (seed defaults to 1 so snapshots are comparable) renders the last 60 frames before T at `Tuning.frameRate` (so temporal history converges) offscreen, writes the final frame to PNG and prints average GPU time.

## Frame passes
1. Nebula raymarch at half point resolution (`Tuning.nebulaPointDivisor`) into rgba16f plus r32f radiance-weighted depth, with rays jittered per frame by a 16-frame Halton sequence.
2. Temporal upscale into point-resolution history (`historyPointDivisor`): the new frame is reconstructed from its jittered samples with a gaussian of their true distances, last frame's result is reprojected through the camera motion at the coarse depth and clamped to the 3x3 neighbourhood, and the blend weight (`Tuning.temporalBlend`) is scaled by how close this frame's sample landed. Sheets are widened only to the history pixel footprint. Ping-pong history textures; history is invalidated on resize. Fast-moving hard edges show one-point stair steps because the clamp rejects most history there.
3. Bloom: 13-tap downsample chain from the resolved nebula (Karis average on the first level), tent upsample accumulated back up.
4. Final: chromatic aberration, bloom mix, exposure, vignette, saturation, ACES fit tonemap, sRGB encode, grain, dither.

## Rendering notes
- No stars: the scene is an endless Vela/Crab-like remnant the camera is inside once the intro is over.
- Everything is built from emissive sheets: isosurfaces of a baked fbm field whose gradient is baked alongside it (`sheet` rgba16f texture: value, gradient per unit texture coordinate), so the signed distance `(v - level)/|grad|` costs one fetch. Seen edge-on, a sheet's column grows as 1/cos (plus an extra rim term), so face-on sheets are faint veils and edge-on ones are crisp arcs and strands, the look of shock fronts.
- Each sheet's gaussian slab is integrated exactly over a march step (erf of the signed distances at both ends of the step), so sheets can be much thinner than a step; the step is a fixed `0.25 + 0.018 t` and cost does not depend on sheet width. Slabs thinner than the pixel footprint are widened to it (energy is kept by the normalisation).
- Layers: large blue shells (several nearby levels give parallel layered sheets, wrinkled by shifting the level with detail noise); gold and red filigree (finer tile) in patches; diffuse hydrogen-red haze; light dust absorption. Region, warp and detail fields from the rg `noise` texture drive the masks and colours.
- Intro: the flight starts inside an empty pocket (`Tuning.pocketRadius`, centre `pocketOffset` behind the start, kept unwrapped in the renderer and passed as `Uniforms.pocket`, the camera's offset from it). Emission and dust are scaled by a smoothstep on the distance past its wall, which is bent by the warp field and frayed by detail; just past the wall the nebula's own sheets are brightened into a rim. A separate emissive sheet on the wall was tried and read as grey smoke puffs. The march starts where the ray can first reach the wall, so the empty opening seconds are cheap. The pocket must be larger than the view distance or the wall shows from the first frame, so to keep the intro short the camera crosses it fast (`introBoost`, easing to cruising speed over `introDuration`). The path runs straight for the boosted distance plus the camera's bank look-ahead, so it does not turn or bank while boosted; at that speed turns were too fast and gave the boost away. Roughly: black at first, the edge at 4 to 9 s, fully inside by 12 to 15 s depending on the route.
- The field is domain-warped before sampling; the gradient ignores the warp's Jacobian.

## Build
- Releases: `VERSION` holds a plain number (not semver), used as both `CFBundleShortVersionString` and `CFBundleVersion` of the saver. The saver is signed with the first Developer ID Application identity in the keychain (ad-hoc if none) with the hardened runtime; the harness stays ad-hoc. `make notarise` submits to Apple with the `notarytool` keychain profile and staples, `make dist` does a clean notarised build into `build/nebula-$(VERSION).zip`, and `make release` checks the tree is clean, pushed and current, then tags `v$(VERSION)` and creates the GitHub release. Modelled on the user's globau/android-notification-bridge Makefile. Bump `VERSION` by hand before releasing.
- `make` (saver + harness), `make run`, `make snapshot [TIME=..] [SIZE=..] [SCALE=..] [SEED=..]` (defaults to a 2x Retina frame at 60 s, past the intro) -> `build/snapshot.png`, `make thumbnail [SEED=..] [TIME=..]` (regenerates `Resources/thumbnail.png` and `thumbnail@2x.png`, the 90x58 System Settings tile, from seed 3 at 60 s by default; needs the gpu, so the images are checked in), `make install`.
- Shaders are compiled at runtime from `Shaders.metal` in the bundle's Resources (the offline Metal Toolchain is not installed); shader compile errors only show at runtime, so run a snapshot after any shader edit.
- `-module-cache-path build/ModuleCache` is needed because the sandbox blocks the default cache in `/var/folders`.
- The Claude sandbox blocks GPU access (`MTLCreateSystemDefaultDevice()` returns nil); running the harness or snapshots needs an unsandboxed run, which the user has approved for the harness binary.
- CPU-only logic (flight path, camera) can be checked by compiling those sources with a scratch `main.swift` in `$TMPDIR` inside the sandbox.

## Invariants
- Every noise tile the shader uses (shell, filigree, warp, detail, region) must divide `Tuning.worldPeriod` so the camera position can wrap without seams.
- Gpu struct members are all `float4` so Swift and MSL layouts match; keep it that way.

## Quirks
- `legacyScreenSaver` caches the loaded bundle; `make install` runs `killall legacyScreenSaver` (`|| true`, as it normally is not running at install time). `WallpaperLegacyExtension` also loads third-party saver bundles and may host the System Settings preview; unconfirmed whether it caches Nebula, so suspect it if the preview looks stale after an install.
- Instances can linger after the saver stops; the view stops its display link on the `com.apple.screensaver.willstop` distributed notification.
