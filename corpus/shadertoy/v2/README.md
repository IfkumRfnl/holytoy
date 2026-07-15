# HolyToy Shadertoy corpus v2

This is the second versioned compatibility corpus for HolyToy. It contains
**51** real Shadertoy shader projects (51 separately preserved GLSL Image
passes) across **two strata**, collected on `2026-07-15T10:57:00Z`. It is a
self-contained sibling of `corpus/shadertoy/v1`, which stays frozen and
unreferenced; the 20 v1 projects are carried into v2 byte-for-byte under the
same IDs with only a `carried_forward_from` provenance note added.

## Strata

- **`single_no_channels` (39 projects)**: exactly one `Image` pass, no
  `iChannel*` input and no texture/sampler/`texelFetch`/Buffer/Common/
  Sound/Cubemap/webcam/video/`mainVR` usage. Same gates as v1, with one
  precision fix: the purity scan runs on comment-stripped source, because
  two accepted pure shaders (`lsB3zD` Doom 2, `Xtf3zn` Tokyo) mention the
  word "texture" only in prose comments.
- **`single_texture_channels` (12 projects)**: exactly one `Image` pass
  whose only inputs are **static still-texture channels**, each recorded in
  `passes[].inputs` with channel index, input kind, and the Shadertoy media
  path plus the evidence source. No keyboard, video, music, webcam, buffer,
  or cubemap inputs. The media files themselves are NOT shipped. These
  entries are **expected to fail compile** in HolyToy today: they exist to
  corpus-measure the missing texture/channel runtime instead of leaving it
  invisible (AGENTS.md, deliberate-incompatibility rule).

A multipass/buffer stratum is **explicitly deferred**: the manifest schema
has no pass-graph yet and no runtime could consume it.

## Composition targets and shortfall

The plan targeted >=20 new `single_no_channels` projects (>=40 total) and
8-12 `single_texture_channels` projects. The two pinned snapshots yield only
**19** qualifying new stratum-A candidates after the license and purity
gates (12 from the Reinder backup, 7 from the beans_please backup), so
stratum A totals **39, one short of the 40 target**. Per the plan's rule the
shortfall is recorded here rather than relaxing the gates or adding a third
source. Stratum B had 15 qualifying candidates; it was capped at 12 (6
Reinder + 6 beans_please) and the 3 deferred candidates are recorded in
`rejected.jsonl`. The 2D/3D split is 25/26.

## Provenance and license policy

Identical to v1. Sources are the SAME two pinned author-maintained
snapshots:

- Reinder Nijhoff backup: [`2def3ce132b4f5d9590e9eee0c17bd37a011835c`](https://github.com/reindernijhoff/shadertoy/tree/2def3ce132b4f5d9590e9eee0c17bd37a011835c)
  — per-shader README License section required (CC BY-NC-SA 4.0); README
  `Inputs` sections are the channel-input evidence for stratum B.
- `beans_please` backup: [`6baf7720d28d4440e8ebdabf9b971c34a7356545`](https://github.com/bean-mhm/shaders/tree/6baf7720d28d4440e8ebdabf9b971c34a7356545)
  — repository root AGPL-3.0 plus README backup assertion; the snapshot's
  `renderpass[].inputs` records are the channel-input evidence.

Public visibility alone was not treated as permission. Candidates with
missing per-shader license evidence, `mainVR`, undocumented channel
bindings, or auxiliary passes (Buffer/Common/Sound) were rejected;
individually inspected rejections are in `rejected.jsonl`.

## Preservation policy

Same as v1: Reinder pass files are copied byte-for-byte from the pinned
backup (including UTF-8 BOMs and non-ASCII comments); beans_please pass
files are the exact `code` strings from the pinned JSON snapshot, UTF-8
encoded without normalization. `metadata.json` is a semantic mirror of the
matching `manifest.jsonl` object. Guest-safe ASCII transfer copies are
derived at run time by `tools/glsl_prep.py`, never stored here.

## Validation

```bash
python3 corpus/shadertoy/v2/validate.py
```

Checks everything v1's validator checked (JSON/JSONL structure, unique IDs,
metadata mirrors, paths, UTF-8, SHA-256, byte counts, ASCII flags, license
evidence, browser/session material markers, unexpected files) plus the
per-stratum input gates described above. It does not compile any shader.

## Limits and biases

- Two creator-maintained backups keep provenance reproducible but bias
  authorship and style; stratum A leans 3D on the Reinder side and 2D on
  the beans_please side.
- Reinder publication dates are date-only; beans_please timestamps keep
  their unresolved publication-vs-update semantics under `source_metadata`.
- Stratum B entries cannot run anywhere in HolyToy yet and have no
  committed visual references; they are measured compile-stage IOUs for the
  texture/channel runtime plan.
