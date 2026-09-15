# `tools/deb/` -- this repository's Debian packaging, gate and publisher

This repository owns its packaging (mica-build-env `RULES.md` at the release
`locks/pins/mica-build-env.pin` names: consumers own their scripts). The scripts started
as mica-build-env c076e24 `deb/` and are this repository's from then on.

| File | Runs | Does |
| --- | --- | --- |
| `producers.sh` | host | discovers the producers: every directory with `producer.env` + `Dockerfile` |
| `build.sh` | host, packs in the mica-build-env `base` image at the target architecture | one producer's archives for one architecture into `_out/debs/<arch>/pool` |
| `pack.sh` | inside the build, as the `packer` context | one `.deb` from a staged tree |
| `version.sh` | host | `<VERSION>+git<commit12>[.dirty]-1`, one stamp for the pool |
| `preflight.sh` | host | every missing producer input at once, before `make pool` |
| `repo.sh` | host, in the mica-build-env `base` image | `Packages`, `SHA256SUMS`, `manifest.txt` for a pool |
| `package-gate.sh` | host, in the mica-build-env `base` image | the pool gates of `RULES.md` section 6, including a byte-identical rebuild |
| `publish.sh` | CI release job | the release's board's `<registry>/<repository>:pool.<board>.<arch>.<YYYYMMDD-HHMM>` |
| `registry.sh`, `registry.env`, `oci.sh`, `control-fields.py` | sourced / host | the registry, the release a checkout is, the OCI client, control fields without dpkg |

Images come only from `tools/from.sh`, out of `locks/mica-build-env.lock`: the
build-env images by name, third-party images by their upstream rows.

## `producer.env`

Plain `KEY=value`: no logic, no command substitution.

| Key | Required | Meaning |
| --- | --- | --- |
| `PACKAGES` | yes | the Debian packages this producer emits |
| `ARCHES` | yes | `amd64`, `arm64`, or `all` (architecture-independent, a member of every pool; not mixed with an architecture) |
| `ENABLEMENT` | yes | `<package>=<count>` of `multi-user.target.wants` links each package ships; the gate holds it |
| `BUILD_CONTEXTS` | no | `<name>=<repository-relative path>`, passed as `--build-context` |
| `FROM_IMAGES` | no | `<build-arg>=<IMAGE_ key>` further bases; `MICA_BUILD_BASE` (the packer) is always supplied |
| `BUILD_ARGS` | no | extra `<name>=<value>` build arguments |
| `PREPARE` | no | a script beside `producer.env`, run on the host first; what it leaves in `MICA_DEB_STAGE` is the `bin` context |
| `PREFLIGHT` | no | `1` when that hook honours `MICA_DEB_PREFLIGHT=1` (check inputs, build nothing) |
| `FOR_EACH` | no | a repository-relative glob of `KEY=value` files: one instance per match, named `<producer>@<directory>`; the file's assignments are set when `producer.env` is read (`boards/*/board.env` for the board and kernel producers) |
| `CONTROL_DIR` | no | where the control templates are; default `<producer dir>/control` |

The Dockerfile declares `ARG MICA_BUILD_BASE`, `FROM ${MICA_BUILD_BASE} AS pack`,
copies `pack.sh` from the `packer` context and runs it once per package with
`MICA_DEB_VERSION`, `MICA_DEB_ARCH`, `SOURCE_DATE_EPOCH` (HEAD's commit time),
`MICA_DEB_SOURCE_REPO` and `MICA_DEB_SOURCE_COMMIT`; the control template
carries `@VERSION@` and `@ARCH@` and none of `Installed-Size`,
`Mica-Source-Repo` or `Mica-Source-Commit`, which the packer writes.
