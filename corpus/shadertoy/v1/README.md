# HolyToy Shadertoy corpus v1

This is a small, versioned compile-compatibility corpus for HolyToy. It contains **20** real Shadertoy shader projects and **20** separately preserved GLSL passes, collected on `2026-07-14T06:17:27Z`.

## Selection

The initial scope was intentionally reduced to 20 projects. The set is a fixed, manually documented visual-domain split: **10 2D/screen-space** projects and **10 3D** projects. Classification comes from the authors' titles, descriptions, tags, and source purpose—not from HolyToy compiler outcomes.

Every accepted project is exactly one `Image` pass in the **20 single-pass / no-channel** stratum. The generator and validator reject any project with an `iChannel*` input, texture/sampler operation, `texelFetch`, Buffer, Common, Sound, Cubemap, webcam, video, `mainVR`, or any auxiliary pass. Standard Shadertoy built-ins such as `iResolution`, `iTime`, `iFrame`, `iDate`, and `iMouse` remain in scope.

The 3D half deliberately includes sphere tracing, path tracing, grid raycasting, camera/lens math, compact voxel-style traversal, Gaussian/AO math, and distance-field scenes. The 2D half includes compact procedural rendering, quines, frame-indexed behaviour, colour-map math, and integer-coordinate noise. This keeps v1 focused on pure fragment-language compatibility before media and pass-graph support are added.

## Provenance and license policy

Every accepted project is attributed in its metadata with the creator handle and canonical Shadertoy URL. The v1 source snapshots are pinned to specific author-maintained repositories:

- Reinder Nijhoff backup: [`2def3ce132b4f5d9590e9eee0c17bd37a011835c`](https://github.com/reindernijhoff/shadertoy/tree/2def3ce132b4f5d9590e9eee0c17bd37a011835c) — per-shader README license evidence; `15` accepted CC BY-NC-SA 4.0 projects.
- `beans_please` backup: [`6baf7720d28d4440e8ebdabf9b971c34a7356545`](https://github.com/bean-mhm/shaders/tree/6baf7720d28d4440e8ebdabf9b971c34a7356545) — repository root AGPL-3.0 license plus README assertion that it is the creator's personal Shadertoy backup; `5` accepted AGPL-3.0-only projects.

Public visibility alone was not treated as permission. The supplied Shadertoy candidate `MdVXzw` was inspected normally in Shadertoy and is recorded in `rejected.jsonl` as a **deferred valid candidate**, not a licensing denial: Shadertoy's current Terms describe CC BY-NC-SA 3.0 as the default when an author has not supplied another license, but this 20-item release only saves raw source from reproducible pinned author snapshots.

No accepted project references external media because the pure-fragment gate disallows channels and texture operations.

## Preservation policy

- Reinder pass files are copied byte-for-byte from the pinned backup, including UTF-8 BOMs and non-ASCII comments.
- `beans_please` pass files are the exact `code` strings from the pinned JSON snapshot, UTF-8 encoded without normalization, repair, transpilation, or formatting.
- `metadata.json` is a semantic mirror of the matching `manifest.jsonl` object.
- SHA-256, byte count, and ASCII-only status describe each saved byte sequence.

## Manifest schema

`manifest.jsonl` has one JSON object per accepted shader. Each object contains the stable Shadertoy ID, author and canonical page URL, retrieval/publication metadata where known, tags, license identifier and evidence, provenance, coverage labels, and its Image pass. The pass records its name/kind, relative source path, source URL, raw SHA-256, byte count, ASCII status, and an explicitly empty input list.

`rejected.jsonl` records inspected candidates not saved in this version, including license status and retrieval error information.

## Validation

Run:

```bash
python3 corpus/shadertoy/v1/validate.py
```

The validator parses all JSON/JSONL, checks unique IDs and accepted/rejected separation, verifies metadata mirrors, paths, UTF-8, SHA-256, byte counts, ASCII flags, explicit license evidence, the pure Image-only/no-auxiliary-input policy, unexpected files, and obvious browser/session material markers. It does not compile any shader.

## Limits and biases

- This is a compile corpus, not yet a visual-correctness oracle.
- It is a deliberately small, non-random 20-project calibration set with a 10/10 2D/3D split; it is not representative of all Shadertoy styles or current site contents.
- Two creator-maintained backups make provenance reproducible but bias authorship and snapshot dates.
- Reinder publication dates are recorded as date-only. The `beans_please` snapshot exposes a raw Shadertoy epoch timestamp but does not say whether it is creation or update time, so it is retained under `source_metadata` rather than guessed as publication time.
- `15` saved passes contain non-ASCII bytes. Reinder files retain a UTF-8 BOM by design; TempleOS ingestion must handle that separately without changing this authoritative corpus.
