# vernaillen/workflows

One CI/CD pipeline, shared by every app that ships as a Docker image to the
self-hosted registry on the Coolify server.

```
check ──▶ build ──▶ deploy
```

A caller is about ten lines. Everything that used to be copy-pasted — the pnpm
setup, the pinned action SHAs, the layer cache, the registry login, the branch
gating, the Coolify call — lives in
[`.github/workflows/coolify-deploy.yml`](.github/workflows/coolify-deploy.yml)
and is maintained once.

## Why a reusable workflow

`vernaillen` is a **User** account, not an Organization, so org-level *required
workflows* and *rulesets* are unavailable. Of what remains:

| Mechanism | Shares | Stays linked after adoption |
|---|---|---|
| Composite action | steps only, no jobs/gating | yes |
| Starter workflow | a template | **no** — copy-once |
| Org ruleset | a whole workflow | n/a on a User account |
| **Reusable workflow** | **whole jobs, gating, secrets** | **yes** |

The starter workflow already in `vernaillen/.github` is the cautionary tale: it
still pins `actions/checkout@v4`, `pnpm` 9, Node 20 and a
`NUXT_UI_PRO_LICENSE` secret for a package that no longer exists. Nothing
copied from it ever heard about any of that. A reusable workflow cannot rot
that way — there is one copy, and fixing it fixes every caller on their next
run.

## The one convention

**Every repository exposes `pnpm run check`.** The pipeline always runs exactly
that command. What it does is the repository's business:

```jsonc
// harmonics.be — no typecheck script, no tests (yet)
"check": "nuxt prepare && pnpm run lint"

// radio.vernaillen.dev
"check": "nuxt prepare && pnpm run lint && pnpm run typecheck && pnpm run build"

// vernaillen.astro — Playwright's webServer serves dist/, so build comes first
"check": "pnpm lint && pnpm typecheck && pnpm build && pnpm test:e2e"
```

This is the decision that makes the CI file genuinely uniform. The alternative
— `lint: true`, `typecheck: true`, `test: false`, `build-before-test: true` —
grows an input per repository per quarter, and the workflow slowly becomes a
badly-typed configuration language. Putting the variation in `package.json`
also means `pnpm check` locally runs precisely what CI runs, with nothing to
keep in sync.

The `check-command` input exists for bringing a repository *onto* the
convention, not for living outside it.

## Using it

```yaml
# .github/workflows/ci.yml
name: ci

on:
  push:
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  # Never cancel a main-branch run: it is the one that pushes and deploys.
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

jobs:
  pipeline:
    uses: vernaillen/workflows/.github/workflows/coolify-deploy.yml@v1
    with:
      image-name: my-app
      coolify-url: ${{ vars.COOLIFY_URL }}
      coolify-app-uuid: ${{ vars.COOLIFY_APP_UUID }}
    secrets: inherit
```

`secrets: inherit` passes the repository's secrets through. Naming them
explicitly also works and is worth it when a repository holds secrets that this
pipeline has no business seeing:

```yaml
    secrets:
      REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
      REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
      COOLIFY_TOKEN: ${{ secrets.COOLIFY_TOKEN }}
```

See [`examples/caller.yml`](examples/caller.yml) for an annotated version, and
the three live callers: `harmonics.be`, `vernaillen.astro`,
`radio.vernaillen.dev`.

### Three things that surprise everyone

1. **`env:` does not propagate.** A caller-level `env:` block is invisible
   inside a called workflow. Anything the pipeline needs must be an input or a
   secret.
2. **Job names change.** A called job shows up as `pipeline / check`, not
   `check`. Any branch-protection rule naming the old check by name must be
   renamed, or the branch stays blocked forever on a check that can no longer
   report.
3. **`vars` and `secrets` are not interchangeable.** `vars.X` silently
   evaluates to an empty string when `X` only exists as a secret — which is
   exactly how `vernaillen.astro` baked an empty `PUBLIC_RADIO_URL` into every
   build for months. If a build arg looks empty, check which of the two lists
   it is actually in.

## Reference

### Inputs

| Input | Type | Default | |
|---|---|---|---|
| `image-name` | string | **required** | Image name in the registry, no host, no tag. |
| `registry` | string | `registry.apps.vernaillen.dev` | Registry host. |
| `node-version` | string | `26` | Node used by the `check` job only; the image uses whatever its Dockerfile pins. |
| `check-command` | string | `pnpm run check` | The one command that decides whether the commit is good. |
| `playwright-browsers` | string | `''` | Space-separated browsers to install and cache, e.g. `chromium`. Empty skips it. |
| `runs-on` | string | `ubuntu-latest` | Runner label for all three jobs. |
| `context` | string | `.` | Docker build context. |
| `dockerfile` | string | `Dockerfile` | Path **relative to the repository root, not to `context`**. |
| `build-args` | string | `''` | Newline-separated `KEY=VALUE`. Public values only — build args are readable in the image history. |
| `smoke-test` | boolean | `true` | Boot the image and wait for an HTTP answer before pushing. |
| `smoke-port` | number | `3000` | Port the container listens on. |
| `smoke-path` | string | `/` | Path requested on the booted container. |
| `smoke-timeout` | number | `60` | Seconds to wait for an answer. |
| `coolify-url` | string | `''` | Coolify instance URL, no trailing slash. Empty skips the deploy job. |
| `coolify-app-uuid` | string | `''` | Coolify application UUID. Empty skips the deploy job. |
| `deploy-branch` | string | `main` | Branch whose green builds are pushed and deployed. |

`coolify-url` deliberately has **no default**: this repository is public and
the control-plane URL is not. `registry` keeps its default because that host is
already public in `radio.vernaillen.dev`.

### Secrets

All optional, so the self-test can exercise the whole pipeline with no
credentials at all.

| Secret | Needed for |
|---|---|
| `REGISTRY_USERNAME` | the push (`deploy-branch` runs only) |
| `REGISTRY_PASSWORD` | the push |
| `COOLIFY_TOKEN` | the deploy job; the job fails loudly if the Coolify inputs are set and this is empty |
| `BUILD_SECRETS` | newline-separated `id=value`, mounted as `--mount=type=secret,id=<id>`, never stored in a layer |
| `SMOKE_ENV` | newline-separated `KEY=VALUE` handed to the smoke-test container as an env file |

### Outputs

| Output | |
|---|---|
| `image` | fully qualified image name, no tag |
| `tag` | the commit SHA the image was tagged with |
| `pushed` | `'true'` when this run actually pushed |

## What the pipeline does

### check

Checkout, pnpm (version read from `packageManager` in `package.json` — the only
place it should ever be pinned, which is why the three repositories can sit on
pnpm 10 and 12 side by side), Node with a pnpm cache,
`pnpm install --frozen-lockfile`, then the check command via `eval` so a
`&&`-chained command chains instead of passing `&&` as an argument. On failure
with `playwright-browsers` set, `playwright-report/` is uploaded.

`--frozen-lockfile` is not negotiable: CI must never quietly resolve a
different dependency tree than the one that was committed.

### build

Buildx (docker-container driver, required for the GHA layer cache), one build
with `load: true`, then — before anything is pushed — the image is started and
polled until it answers `GET <smoke-path>` on `<smoke-port>`. Container logs
are always grouped into the run log, and the wait aborts the moment the
container stops, so a crash loop fails in seconds instead of burning the whole
timeout.

Only then does the registry login happen, and the push goes
**`:<sha>` first, `:latest` second** — so Coolify, which pulls `:latest`, can
never pull a half-finished push.

This is generalised from `radio.vernaillen.dev`, the only one of the three that
already verified its image could start. An image that cannot boot now cannot
reach the registry, let alone production. The build itself runs on every
branch, so a broken Dockerfile is caught on a feature branch; only the push and
the deploy are gated on `deploy-branch`.

### deploy

A single authenticated `POST /api/v1/deploy?uuid=…&force=true`. `force=true`
because Coolify will not otherwise notice that `:latest` moved. The job has
`permissions: {}` — a curl needs no token — and is skipped entirely unless the
previous job actually pushed and both Coolify inputs are set, so a repository
can adopt the pipeline before its Coolify application exists.

## Configuring a repository

```bash
./scripts/configure-repo.sh --repo vernaillen/my-app --dry-run   # prints lengths only
./scripts/configure-repo.sh --repo vernaillen/my-app
```

It resolves each value from the environment, then `~/.env`, then `./.env`, then
an interactive prompt; discovers the Coolify application UUID by name via the
Coolify API; and pipes every value to `gh` over stdin, so no secret ever
appears in the process list, the shell history or the output. It is idempotent
— re-run it whenever a credential rotates.

## Maintaining this repository

### The self-test is the point

Three repositories depend on one file, so a typo here breaks all three at once.
[`.github/workflows/self-test.yml`](.github/workflows/self-test.yml) calls
`uses: ./.github/workflows/coolify-deploy.yml`, which resolves to **the same
commit** — so what is tested is exactly what would be released. The fixture
under [`test/fixture`](test/fixture) exercises install, check, a Docker build
with both a build argument and a mounted build secret, the local load, the boot
and the HTTP probe. It needs no credentials: `deploy-branch` names a branch
that cannot exist, so login, push and deploy are never reached.

That is also what makes `renovate.json` safe to automerge minor, patch and
digest action bumps: the full pipeline runs on the bump itself. One PR here
replaces one PR per dependant repository.

### Releasing

Callers pin `@v1`. Moving that tag is the release:

```bash
./scripts/release.sh v1        # after the self-test is green on main
```

Breaking changes get a new major (`v2`) and the callers move over one at a
time; `v1` keeps working until the last one has moved. Pinning to a SHA also
works and is the right choice if a caller ever needs to be frozen.

## Repository layout

```
.github/workflows/coolify-deploy.yml   the pipeline
.github/workflows/self-test.yml        runs the pipeline against test/fixture
test/fixture/                          two files: a Dockerfile and a /healthz server
examples/caller.yml                    annotated caller template
scripts/configure-repo.sh              sets secrets and variables on a caller repo
scripts/release.sh                     moves the v1 tag
```
