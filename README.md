# internal: cdxgen-packages

Hub for syncing cdxgen's published packages.

## Background

The cdxgen repositories moved to their own org, <https://github.com/cdxgen>, so
new container images are published under `ghcr.io/cdxgen/*`. Consumers pulling
`ghcr.io/cyclonedx/*` predate that move and are still out there, so this repo
mirrors images from the new namespace back into the
[CycloneDX org](https://github.com/orgs/CycloneDX/packages).

## Mirroring

`.github/workflows/images-mirror.yml` runs every 12 hours and on demand. It
discovers every `cdxgen*` container package in the `cdxgen` org, then for each
one decides which tags to copy and `skopeo copy --multi-arch all`s them.

Tag selection lives in `scripts/select-tags.sh` rather than inline in the
workflow, so it can be run against captured tag lists. A mirror that quietly
copies the wrong tags produces green runs and wrong images, which is not a
failure CI notices by itself.

### What gets mirrored

In priority order:

1. `latest`
2. Rolling tags for each series in `rolling_majors` (default `v12,v13`) —
   `v13`, `v13.0`, `v12`, `v12.7`, and so on. These are selected in their own
   right rather than derived from whichever releases made the cut, so a series
   keeps receiving updates even after it stops getting releases and falls out
   of the newest-N window.
3. The five newest releases.
4. Pre-releases, but only for a series that has no releases yet.
5. `master`, last, so it can never displace a release.

### What never gets mirrored

| Pattern | Why |
| ------- | --- |
| `sha256-*` | cosign/attestation referrers, not runnable images |
| `*-amd64`, `*-arm64`, `*-ppc64le` | per-architecture halves published before the manifest list is merged; copying one makes a multi-arch tag look single-arch |
| `*-nydus` | lazy-loading conversions, meaningless outside their snapshotter |
| `feature-*`, `fix-*`, `dependabot-*`, `renovate-*` | branch builds |

An explicit `versions` input bypasses these exclusions: naming a tag is an
informed choice.

### Running it by hand

`workflow_dispatch` inputs:

| Input | Default | Purpose |
| ----- | ------- | ------- |
| `versions` | *(empty)* | Copy exactly these tags instead of the default selection. Matched with and without a leading `v`. |
| `rolling_majors` | `v12,v13` | Series whose rolling tags are always mirrored |
| `mirror_master` | `true` | Also mirror `master` |
| `dry_run` | `false` | Report what would be copied without copying |

Each run writes a per-image table of tags and results to the job summary.

## Tests

```bash
./scripts/test-select-tags.sh
```

Fixtures under `scripts/fixtures/` are real `skopeo list-tags` output. Refresh
with:

```bash
skopeo list-tags docker://ghcr.io/cdxgen/cdxgen \
  | jq -r '.Tags[]' > scripts/fixtures/cdxgen-tags.txt
```

`cdxgen-v13-tags.txt` is that capture plus the tags a v13 release adds, so the
v13 path is covered before v13 exists.
