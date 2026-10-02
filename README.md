# gh-workflows

Reusable GitHub Actions workflows, callable from any of my repos.

## Available workflows

| Workflow | Stack | Trigger |
|---|---|---|
| `java-spring.yml` | Java 21 + Spring Boot | push to main, PR |
| `node-ts.yml` | Node 20 + TypeScript | push to main, PR |
| `docker-publish.yml` | Docker + GHCR | push tags `v*` |
| `docusaurus-portal.yml` | Docusaurus docs portal: verify + build image once + optional deploy | PR, push to `development` |
| `promote-image.yml` | Any image built with the `tree-` convention: promote without rebuilding | push to `main` |
| `deploy-compose.yml` | Deploy an image to a Docker Compose service over SSH | called by the two above (or directly) |

## Usage

```yaml
jobs:
  build:
    uses: yazkyChristianNicolas/gh-workflows/.github/workflows/java-spring.yml@main
    with:
      java-version: '21'
```

## Build once, promote: `docusaurus-portal.yml` + `promote-image.yml`

Two pipelines for a `development` → `main` branch flow, with one GitHub environment each:

```
feature/*  --PR-->  development  --PR-->  main
   verify          build image         promote the same image
                   deploy to dev       deploy to production
```

- **Build** (`docusaurus-portal.yml`, on push to `development`): `npm ci`, typecheck,
  `npm run build`, then builds the image **once** and pushes it as
  `ghcr.io/<owner>/<repo>:tree-<git tree>` (plus `sha-<commit>`), and deploys it to the
  `development` environment.
- **Promote** (`promote-image.yml`, on push to `main`): does **not** build. It looks up
  `tree-<git tree of main>`: merging `development` into `main` (merge commit or squash)
  creates a new commit but keeps the same tree, so it finds the exact image that was
  tested in development. It tags it `production` and `production-sha-<commit>` and deploys
  it. If there is no image for that tree, the content never went through `development`
  (e.g. a commit made straight to `main`) and the promotion fails.
- **Deploy** (`deploy-compose.yml`, used by both): over SSH, writes the image tag into the
  server's compose `.env` and restarts only that service.

Because the same image runs everywhere, **it must not bake environment-specific values**
(URLs, ids). Read them when the container starts; for a static site, build with
placeholders and replace them in an entrypoint script (reference: the
`berlinesa-developers-platform` Dockerfile and `docker/40-portal-config.sh`).

### Usage

```yaml
# .github/workflows/development.yml
name: Development

on:
  pull_request:
  push:
    branches: [development]

permissions:
  contents: read
  packages: write

jobs:
  portal:
    uses: yazkyChristianNicolas/gh-workflows/.github/workflows/docusaurus-portal.yml@main
    with:
      push-image: ${{ github.event_name == 'push' }}
      deploy: ${{ github.event_name == 'push' }}
      environment: development
      compose-service: developers-portal
      tag-variable: DEVELOPERS_PORTAL_TAG
    secrets: inherit
```

```yaml
# .github/workflows/production.yml
name: Production

on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write

jobs:
  promote:
    uses: yazkyChristianNicolas/gh-workflows/.github/workflows/promote-image.yml@main
    with:
      environment: production
      compose-service: developers-portal
      tag-variable: DEVELOPERS_PORTAL_TAG
    secrets: inherit
```

### `docusaurus-portal.yml` inputs

| Input | Default | Description |
|---|---|---|
| `node-version` | `24` | Node.js version for the verify job. |
| `typecheck` | `true` | Run `npm run typecheck` before building. |
| `build-env` | `''` | `KEY=VALUE` per line for `npm run build` and `docker build` args. Must be identical for every environment (the image is promoted as is). Not for secrets. |
| `image-name` | `ghcr.io/<owner>/<repo>` | Image name without tag. |
| `push-image` | `false` | Build and push the image. If an image for the same tree already exists, it is reused instead of rebuilt. |
| `deploy` | `false` | Deploy the pushed image to `environment`. |
| `environment` | `development` | GitHub environment to deploy to. |
| `compose-dir`, `compose-service`, `tag-variable`, `healthcheck-url` | | Passed to `deploy-compose.yml`. |

### `promote-image.yml` inputs

| Input | Default | Description |
|---|---|---|
| `environment` | `production` | GitHub environment to promote to. |
| `image-name` | `ghcr.io/<owner>/<repo>` | Image name without tag. |
| `compose-dir`, `compose-service`, `tag-variable`, `healthcheck-url` | | Passed to `deploy-compose.yml`. |

### `deploy-compose.yml` inputs

| Input | Default | Description |
|---|---|---|
| `image` | — | Full image reference (`name:tag`). Only the tag is written to the server. |
| `environment` | — | GitHub environment with the deploy secrets and variables. |
| `compose-dir` | `/opt/stack` | Compose project directory on the server. |
| `compose-service` | — | Compose service to update. |
| `tag-variable` | `IMAGE_TAG` | Variable the compose file reads the image tag from. Use one per service. |
| `healthcheck-url` | environment variable `HEALTHCHECK_URL` | URL that must answer 2xx after the deploy (10 attempts, 6 s apart). Empty to skip. |

### Per-environment configuration

Create the GitHub environments `development` and `production` in the calling repo, each with:

| Kind | Name | Value |
|---|---|---|
| Variable | `DEPLOY_ENABLED` | `true` to deploy. While unset, the deploy job is skipped (not failed). |
| Variable | `HEALTHCHECK_URL` | Optional. Public URL checked after the deploy. |
| Secret | `DEPLOY_HOST` | Server IP or hostname. |
| Secret | `DEPLOY_USER` | SSH user allowed to run `docker` (member of the `docker` group). |
| Secret | `DEPLOY_SSH_KEY` | Private key of a key pair dedicated to deploys, authorized for `DEPLOY_USER`. |
| Secret | `DEPLOY_KNOWN_HOSTS` | Output of `ssh-keyscan -t ed25519 <host>`, so the runner pins the host key. |

Optionally, add required reviewers to `production` to approve each promotion.

The callers must grant `packages: write` (see the usage examples).

### Server contract

- Docker and the Compose plugin installed; `DEPLOY_USER` can run `docker`.
- Logged in to GHCR once, with a token that has `read:packages`
  (`echo $TOKEN | docker login ghcr.io -u <user> --password-stdin`), since images are private.
- A compose project in `compose-dir` where each service takes its tag from its own
  variable. The pipeline keeps that variable in the project's `.env`, so a manual
  `docker compose up -d` keeps the deployed version. To roll back, re-run the deploy of an
  older commit.
- Environment-specific values go in the service's `environment`, not in the image.

Example with both environments on one server behind Caddy (automatic HTTPS per domain):

```yaml
# /opt/stack/compose.yml
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data

  developers-portal:
    image: ghcr.io/owner/berlinesa-developers-platform:${DEVELOPERS_PORTAL_TAG:-production}
    restart: unless-stopped
    environment:
      PORTAL_SITE_URL: https://developers.example.com
      PORTAL_API_URL: https://api.example.com

volumes:
  caddy_data:
```

```caddyfile
# /opt/stack/Caddyfile
developers.example.com {
  reverse_proxy developers-portal:80
}
```

With both environments on the same server, keep a **single** Caddy (only one process can
bind 80/443): put the development services in their own compose project (e.g.
`compose-dir: /opt/stack-dev`) attached to an external network shared with Caddy, and route
the development domains to them from the same Caddyfile.
