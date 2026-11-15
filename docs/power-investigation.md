# GPU power investigation handover

13 November 2026, updated 15 November 2026

The raymarch dominates rendering time.  On 13 November two small shader optimisations were retained.  On 15 November ablation profiling found the bottlenecks (texture-cache misses, then sheet-integration arithmetic) and three more changes cut GPU power by 39% on an M3 Pro.  Start with "Next steps" at the end.

## Constraints and current state

- Preserve the existing appearance, render resolutions and 30 fps.  Byron explicitly ruled out further resolution or frame-rate reductions.  Small, accepted look changes are recorded with each change.
- Judge changes by `make profile` power runs; unpaced snapshots are only a screen (see "The operating point").

`CLAUDE.md` and `README.md` describe the profiling tools.  This handover preserves the findings independently of the conversation and local build artefacts.

## Changes retained

### Filigree guard

In `Sources/Saver/Shaders.metal`, the filigree colour, mask and three sheet integrations run only when `next.region.x > 0.52`.  Outside that region the contribution was already zero.

Alternating fixed-seed snapshots measured approximately 6.43 to 6.21 ms/frame, a 3.4% reduction, at 2880x1800 pixels, 2x scale, seed 1 and 60 seconds.  Two other routes also improved.  The main snapshot differed in 1,261 of 5,184,000 pixels, by at most one 8-bit channel value; no visible change was found.

### Zero-contribution sheet integrations

The `crossing` function now returns zero when both endpoints are more than 4.5 sheet widths on the same side.  At those distances the original error-function approximation already rounds both endpoints to the same +/-1 in float precision, so subtracting them gives zero.  This avoids two exponential/square-root evaluations and the remaining integration arithmetic.

The near-constant-distance Gaussian branch deliberately remains before this check.  Its behaviour and small tails are preserved.

Six full-resolution snapshot comparisons were pixel-identical: seed 1 at 4, 8, 15 and 60 seconds; seed 3 at 75 seconds; seed 5 at 120 seconds.  Snapshot GPU timings generally improved by approximately 3–5% after the intro.  A fresh paired paced diagnostic measured 7.119 to 7.025 ms/frame, a more modest 1.3% improvement, with both runs sustaining 30 fps for 1,800 frames.  This is a GPU-time result, not a confirmed power saving.

Both the saver and harness builds passed.  No resolution, frame-rate, sheet-table or march-step changes were retained.

## Profiling tools

### Sustained processor power

```sh
make profile
```

Run from Terminal.  `powermetrics` requires interactive `sudo` authentication before sampling.  An agent's non-interactive `sudo -n` attempt required a password, so Byron ran the real power captures.

Defaults are a 20-second idle baseline, 30-second renderer warmup, then 60 seconds of offscreen rendering: 2880x1800 pixels, 2x scale, seed 1, flight time 60–120 seconds, paced at 30 fps.  The target uses private storage and one frame in flight.  It excludes window presentation and compositor costs.  CPU, GPU and combined readings cover system-wide processors, not total machine or display power.

Results under `build/profiles/` include raw samples, errors, settings, source and executable hashes, frame-rate statistics and a summary.  Duplicate GPU lines in `powermetrics` output are counted once.  Incomplete samples and a frame rate below 98% of the target fail the run.  Completion is reported in Terminal without audio.

Overrides include `SIZE`, `SCALE`, `SEED`, `TIME`, `WARMUP`, `SAMPLES`, `BASELINE_SAMPLES` and `INTERVAL`.  Rendering duration is `SAMPLES * INTERVAL / 1000` seconds.  `TIME` must be at least `WARMUP`.

### Per-pass GPU diagnostic

```sh
make timings
```

This uses the same default rendering settings, warmup and flight segment.  It needs Metal GPU access outside the sandbox, but no `sudo`.  `DURATION` defaults to 60 seconds.  For a short smoke test:

```sh
make timings WARMUP=1 DURATION=2
```

Optional hooks in `Renderer` attach stage-boundary timestamp counters.  `Sources/Harness/PassTimings.swift` resolves samples after command completion and calibrates GPU ticks against CPU nanoseconds.  Results under `build/timings/` include `passes.txt`, `pass-timestamps.csv`, `timing-clock.txt`, renderer settings and whole-frame timings.

Stage intervals may overlap or include dependency waits.  A pass's vertex-start-to-fragment-end interval proved misleading: it made bloom appear expensive because its vertex work could start long before its fragments.  The diagnostic reports vertex and fragment intervals separately; percentages refer to summed fragment intervals, not whole-frame time.  Large bloom vertex intervals must not be interpreted as equivalent shader arithmetic cost.

Timestamp collection introduces diagnostic overhead.  It remains disabled in the normal saver, snapshots and `make profile`.  A regression check confirmed normal profiles did not produce counter results, and a fixed-seed snapshot was byte-identical before and after the instrumentation changes.

### Image comparisons

```sh
make snapshot TIME=60 SIZE=2880x1800 SCALE=2 SEED=1
```

Save the original bundle and snapshots before changing shaders.  Compare decoded RGB pixels, not just PNG file sizes or visual impressions.  Cover the intro, pocket wall and established flight across several seeds.  Snapshot timing runs are unpaced; do not treat their timing improvement as a direct power percentage.

## Measurements

### Controlled power captures

All three runs below rendered 1,800 frames in approximately 60.005 seconds at 30 fps.  Values are watts; the GPU time column is milliseconds per frame.

| Shader state | GPU baseline | GPU rendering | GPU increase | Combined increase | GPU time |
|---|---:|---:|---:|---:|---:|
| Before filigree guard | 0.038 | 5.930 | 5.892 | 6.156 | 9.254 |
| Filigree guard | 0.030 | 5.854 | 5.824 | 5.893 | 8.934 |
| Filigree and integration guards | 0.092 | 5.723 | 5.631 | 4.720 | 7.630 |

Local result directories, in the same order:

- `build/profiles/20261113-082114-mc8C0S`
- `build/profiles/20261113-082640-UmyiKF`
- `build/profiles/20261113-085410-S6eQsh`

The final run's CPU baseline was 1.578 W, versus 0.666 W during rendering.  That elevated baseline explains the negative CPU increase and exaggerates the apparent combined-power saving.  It is not evidence that rendering reduces CPU power.

GPU rendering power fell by 0.131 W between the last two runs; baseline-adjusted GPU power fell by 0.193 W.  These are promising differences, but concurrent Mac use and changing run conditions prevent confidently attributing them entirely to the shader change.  The much larger change in GPU milliseconds across these runs likewise exceeds the gain in the fresh paired timing comparison.

### Pass breakdown

With the filigree guard, before the integration guard, the full diagnostic produced:

| Pass | Fragment ms/frame | Share of summed fragment intervals |
|---|---:|---:|
| Raymarch | 8.733 | 84.0% |
| Temporal resolve | 1.406 | 13.5% |
| Bloom down | 0.108 | 1.0% |
| Bloom up | 0.051 | 0.5% |
| Final | 0.099 | 1.0% |

Whole-frame GPU time was 9.029 ms, demonstrating why overlapping stage intervals cannot simply be added to obtain frame time.  Raw results: `build/timings/run-pnIQn1/`.

The fresh paired comparison for the integration guard is under `build/raymarch-comparison/Original-timings-z368KD/` and `build/raymarch-comparison/Guarded-timings-qUf5fE/`.  Here, “Original” already includes the filigree guard.  Snapshot comparisons and experimental bundles are also under `build/raymarch-comparison/`.

Build artefacts may disappear after `make clean`; the tables above preserve the important results.  Initial idle readings from a failed `StarsaverHarness` launch were not rendering measurements: the correct executable is `build/NebulaHarness.app/Contents/MacOS/NebulaHarness`.  Earlier random windowed and fullscreen runs are not controlled comparisons with this fixed-seed offscreen workload.

## Experiments discarded

These did not demonstrate a reliable improvement beyond the retained check, or ran slightly slower.  Do not reinstate them merely because they appear cheaper algebraically.

- Early saturation inside each error-function evaluation, and a simplified integral for opposite-sign saturated endpoints.
- Reciprocal-gradient reuse and reciprocal-square-root normalisation.  The tested snapshot differed by at most one channel value, but timing did not improve reliably.
- Bypassing pocket-wall and rim calculations for rays conservatively proven to remain outside their influence.  No reliable timing benefit.
- Conservative bounds for entire shell and filigree groups.  The tested snapshot was identical, but gains were too small/noisy to justify the additional logic.
- Copying baked noise into shader-read-only volumes to permit driver texture optimisations.  Images were identical; no lossless-compression performance benefit was demonstrated.  Do not assume this proves whether the hardware compressed these 3D textures.
- Explicit level-zero noise sampling.  Images were identical, with slightly worse timings in the comparison.

The original suggested next investigation (find the raymarch's hardware bottleneck) was carried out on 15 November; see the ablation results below and "Next steps" at the end.

## Raymarch bottleneck: ablation results

15 November 2026, M3 Pro (18-core GPU), 2880x1800 at 2x.

`xctrace record --template 'Metal System Trace' --instrument 'Metal GPU Counters'` works unsandboxed, but from the command line it only records the default counter ("RT Unit Active"); choosing the performance-limiter counter set needs the Instruments GUI.  Instead, the bottleneck was found by ablation: shader variants with one component removed, swapped into copies of the harness bundle (shaders compile at runtime from Resources), timed with unpaced snapshots at seed 1, 60 s, interleaved and repeated.

Unpaced snapshots run near full GPU clock and were consistent to about 0.5 ms.  Paced runs are not useful for A/B on this machine: the GPU lowers its clock to fill the frame interval, so paced GPU milliseconds stay at about 23-25 ms whatever the workload, varying 10% between identical runs.  Power needs `make profile`.

| Variant | ms/frame |
|---|---:|
| Base | 16.3-17.6 |
| No sheet integration, fetches kept | 16.9-17.6 |
| No shell integration | 15.7-16.0 |
| No filigree, including its fetch | 9.5-9.7 |
| No detail fetch | 8.0-8.1 |
| No texture fetches | 8.6-8.8 |
| Detail tile 4x coarser, same fetches | 8.1-8.2 |
| Filigree tile 4x coarser, same fetches | 10.9-11.0 |
| Detail fetch independent of warp | 16.5 |
| Step jitter uniform per frame | 9.9-10.0 |
| Step jitter per 2x2 / 4x4 / 8x8 block | 13.8 / 11.6 / 10.6 |

Conclusions: the integration arithmetic costs nothing measurable, and fetch latency/dependency is not the limit.  The cost is texture-cache misses on the finely tiled fields.  The main cause was the per-pixel step jitter, which offsets neighbouring rays by up to a whole step (several detail texels at mid range), so the threads of a SIMD group sample unrelated texels.

### Retained: 8x8 block step jitter

The step offset now comes from `ign(floor(pos / 8))`.  Snapshot GPU time fell from about 16.4 to 10.5 ms at seed 1, 60 s, and by 25-35% at seed 1 at 8 and 15 s, seed 3 at 75 s and seed 5 at 120 s.  Images differ from the original by mean 0.2-0.7 of an 8-bit level (PSNR 46-54 dB, lowest in the intro); the differences are fine per-pixel noise along moving edges where history is rejected, with no visible block structure in stills.  Watched live, Byron saw some blockiness along edges as they approach the camera and accepted it; do not grow the blocks beyond 8x8 without checking that.

Power, `make profile` defaults, alternating original and new builds; every run rendered 1,800 frames at 30.00 fps, with idle GPU baselines of 0.012-0.013 W:

| Run | GPU rendering | GPU increase | Combined increase |
|---|---:|---:|---:|
| Original 1 | 4.324 | 4.312 | 4.333 |
| Block jitter 1 | 3.660 | 3.647 | 3.605 |
| Original 2 | 4.368 | 4.356 | 4.480 |
| Block jitter 2 | 3.660 | 3.647 | 3.600 |

GPU power fell by about 0.69 W (15%), combined baseline-adjusted power by about 0.80 W (18%).  The power saving is smaller than the 35% reduction in unpaced GPU time because the paced GPU lowers its clock rather than idling.  Results: `build/profiles/Base/` and `build/profiles/New/`.

### Retained: 8-bit noise volume

The `noise` volume (region, warp, detail) is `rg8Unorm` instead of `rg16Float`; its values were already saturated to 0-1.  Unpaced against the block-jitter build: seed 1 at 60 s 10.45 to 7.85 ms, seed 3 at 75 s 10.36 to 7.91, seed 5 at 120 s 9.92 to 7.35, seed 1 at 8 s 9.58 to 8.63.  Images differ by mean 0.05-0.14 of an 8-bit level (PSNR 56-61 dB), visually identical in amplified-difference crops.

Power, alternating with the block-jitter build (two runs each, all 1,800 frames at 30.00 fps): GPU increase 3.663 and 3.652 W against 3.513 and 3.482 W, a 0.16 W (4.4%) saving.  The second 8-bit run had CPU activity (0.52 W rendering) that does not affect the GPU figure.  Results: `build/profiles/New/2026111516*` and `build/profiles/Rg8/`.

### The operating point: why power falls less than GPU time

`powermetrics` reports GPU frequency residency in `power.txt`.  At 30 fps every build keeps the GPU about 79% active; the governor absorbs less work by moving time from 618 MHz to the 338 MHz floor (338 MHz residency: original 31%, block jitter 39%, 8-bit noise 41%; average active frequency 530, 491 and 481 MHz).  Consequences:

- Unpaced snapshots run at up to 1380 MHz, where cache misses cost the most cycles.  At the saver's 340-620 MHz they cost fewer cycles, so memory fixes save less power than snapshot milliseconds suggest, and arithmetic may matter more there than the max-clock ablations show (removing all sheet integration saved nothing unpaced).  Test arithmetic changes with `make profile`, not snapshots.
- The GPU is already mostly at its lowest frequency and voltage, so further savings come from fewer active cycles at that floor, with diminishing returns per millisecond.

### Arithmetic after the memory fixes

Power ablation on top of 8-bit noise, removing all sheet integration (fetches kept; not shippable): GPU increase 2.605 and 2.585 W against 3.513, 3.482, 3.483 and 3.517 W, a 0.90 W (26%) saving, with 74% residency at 338 MHz.  Unpaced it saved 28% (7.86 to 5.66 ms), so with the cache misses fixed, unpaced snapshots track power for arithmetic changes reasonably.

### Retained: group skip

`groupMissed` tests the five shells (levels 0.465-0.535) and the three filigree sheets once per step, against the group's level range and widest sheet, and skips the loop when both endpoints are beyond `crossing`'s cutoff for every sheet.  This was discarded earlier as too small, but only because cache misses hid the arithmetic.  Unpaced against 8-bit noise: seed 1 at 60 s 7.88 to 6.11 ms, seed 1 at 8 s 8.71 to 6.77, seed 3 at 75 s 7.95 to 5.98, seed 5 at 120 s 7.48 to 5.64, close to the no-integration ablation.  All four snapshots byte-identical.

Power, alternating with 8-bit noise: GPU increase 2.621 and 2.631 W against 3.482 and 3.511 W in the same session, a 0.87 W (25%) saving, within 0.03 W of the no-integration ablation.  The GPU now spends about 74% of its time at 338 MHz and under 5% at 618 MHz; active residency stays near 77%.  Results: `build/profiles/Group/`.

### Cumulative, 15 November 2026

GPU power above idle at the profile defaults: original 4.33 W, block jitter 3.65 W, 8-bit noise 3.50 W, group skip 2.63 W; 1.71 W (39%) in total.  The GPU is now almost always at its lowest frequency, so further work reductions lower active residency at that floor rather than the clock.  The remaining cost is mostly the fetches and per-step work outside the integration; next candidates are mipmapped noise (look change at distance) and fewer or cheaper fine-field fetches.

### Discarded: half-precision colour accumulation

Uncommitted work from the other Mac converted the per-step colour arithmetic to `half`.  Unpaced: 16.3-16.8 ms against 16.3-16.5 ms for the original; no gain, consistent with arithmetic not being the limit.  Saved as `build/exp/half-precision.patch`.

## Next steps

State at the end of 15 November 2026: block jitter, 8-bit noise and the group skip were committed for release by Byron.  GPU power 2.63 W above idle, about 74% of the time at the 338 MHz floor.

Method, which worked well: build ablation or candidate shaders into copies of the harness bundle under `build/exp/` (shaders compile at runtime from `Contents/Resources/Shaders.metal`; Swift changes need a rebuilt binary), screen with interleaved unpaced snapshots across seed 1 at 8 and 60 s, seed 3 at 75 s and seed 5 at 120 s, compare decoded pixels, then confirm with an alternating power run that Byron starts from Terminal:

```sh
caffeinate -i zsh -c 'for a in A B A B; do /bin/zsh Scripts/profile.zsh build/exp/$a.app/Contents/MacOS/NebulaHarness build/profiles/$a 2880x1800 2 1 60 30 30 10 2000; done'
```

Four runs take about 7.5 minutes, and the Mac must be left idle.  Read frequency residency from `power.txt` as well as the summary.  The unsandboxed shell has a different `$TMPDIR`; keep generated files in the project or scratchpad.

Candidates, in suggested order:

1. Re-ablate the current build first.  The cost structure changed twice today; measure what the remaining 2.63 W is made of (each fetch, the filigree path, pocket and haze arithmetic, the temporal resolve) before choosing.  Ablate at the profile operating point with power runs for anything that looks significant unpaced.
2. Fewer fine-field fetches, image-identical: the filigree fetch runs wherever `region.x > 0.52`, even when the shell-group-style test would show no filigree sheet can be crossed; look for a cheap conservative predictor.  Note the sentinel issue under review follow-ups below when touching this path.
3. Mipmapped `noise` and `sheet` volumes sampled at a level matched to step length or footprint.  Probably the largest remaining saving, but it softens distant detail, and lower mips shrink sheet gradients (changing sheet distances); needs Byron's visual review.  Detail first, filigree second, shells least.
4. Cheaper `erfApprox`.  With the group skip, fewer integrations remain, so the gain is smaller; not image-identical.
5. Temporal resolve was 13.5% of fragment time before the raymarch got cheaper, so it is now a larger share.  Ablate it to see its power cost before optimising; preserve its reconstruction and history behaviour.

Not worth repeating: larger jitter blocks (uniform per-frame jitter is only 0.6 ms faster than 8x8, and Byron saw some blockiness at 8x8); half-precision colour; paced GPU milliseconds as an A/B measure.

## Separate review follow-ups

These came from the initial code review and were not addressed by the power optimisation:

- `NebulaView.tick` obtains a drawable on the main run loop.  `nextDrawable()` can block when the drawable pool is exhausted, delaying host events under GPU backpressure.  Investigate non-blocking admission of outstanding frames or moving acquisition/encoding off the main thread if this becomes a practical problem.  No freeze was reproduced in this session.
- Skipped filigree samples use `Field{ 10.0, 1.0, 0.0 }`.  On entering a patch, integrating from that sentinel to a real value can imply a false sheet crossing.  This is a static correctness finding, not a reproduced visible artefact.  A future fix should track sample validity and obtain the missing endpoint before integrating, with separate visual validation.

## Relevant Metal documentation

- [Sampling GPU data into counter sample buffers](https://developer.apple.com/documentation/metal/sampling-gpu-data-into-counter-sample-buffers)
- [Converting GPU timestamps into CPU time](https://developer.apple.com/documentation/metal/converting-gpu-timestamps-into-cpu-time)
- [Optimising texture data](https://developer.apple.com/documentation/metal/optimizing-texture-data)
