# gh-workflows

Reusable GitHub Actions workflows, callable from any of my repos.

## Available workflows

| Workflow | Stack | Trigger |
|---|---|---|
| `java-spring.yml` | Java 21 + Spring Boot | push to main, PR |
| `node-ts.yml` | Node 20 + TypeScript | push to main, PR |
| `docker-publish.yml` | Docker + GHCR | push tags `v*` |
| `docusaurus-portal.yml` | Docusaurus docs portal → GHCR → server via SSH + Docker Compose | PR (verify), push to main (verify + image + deploy) |

## Usage

```yaml
jobs:
  build:
    uses: yazkyChristianNicolas/gh-workflows/.github/workflows/java-spring.yml@main
    with:
      java-version: '21'
```

## `docusaurus-portal.yml`

Pipeline for Docusaurus documentation portals packaged as a Docker image (the site is built
inside the image's Dockerfile and served by nginx). Three jobs:

1. **verify**: `npm ci`, `npm run typecheck` (optional) and `npm run build`.
2. **image** (`push-image: true`): builds and pushes `ghcr.io/<owner>/<repo>:sha-<short>`,
   plus `latest` on the default branch.
3. **deploy** (`deploy: true`): over SSH, writes the new tag into the server's compose
   `.env`, then `docker compose pull` + `up -d --no-deps` of that single service. Optional
   health check against a public URL.

### Usage

```yaml
# .github/workflows/portal.yml in the portal repo
name: Portal

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read
  packages: write

jobs:
  portal:
    uses: yazkyChristianNicolas/gh-workflows/.github/workflows/docusaurus-portal.yml@main
    with:
      build-env: |
        PORTAL_SITE_URL=${{ vars.PORTAL_SITE_URL }}
        PORTAL_API_URL=${{ vars.PORTAL_API_URL }}
      push-image: ${{ github.event_name == 'push' }}
      deploy: ${{ github.event_name == 'push' }}
      compose-service: developers-portal
      tag-variable: DEVELOPERS_PORTAL_TAG
      healthcheck-url: https://developers.example.com/
    secrets: inherit
```

### Inputs

| Input | Default | Description |
|---|---|---|
| `node-version` | `24` | Node.js version for the verify job. |
| `typecheck` | `true` | Run `npm run typecheck` before building. |
| `build-env` | `''` | `KEY=VALUE` per line. Exported for `npm run build` and passed as `docker build` args. Not for secrets. |
| `image-name` | `ghcr.io/<owner>/<repo>` | Image name without tag. |
| `push-image` | `false` | Build and push the image. |
| `deploy` | `false` | Deploy the pushed image. Requires `push-image`. |
| `environment` | `production` | GitHub environment of the deploy job (secrets, required reviewers). |
| `compose-dir` | `/opt/stack` | Compose project directory on the server. |
| `compose-service` | — | Compose service to update. Required to deploy. |
| `tag-variable` | `IMAGE_TAG` | Variable the compose file reads the image tag from. Use one per service. |
| `healthcheck-url` | `''` | URL that must answer 2xx after the deploy (10 attempts, 6 s apart). |

### Secrets (only for deploy)

Repo or `production` environment secrets, passed with `secrets: inherit`:

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | Server IP or hostname. |
| `DEPLOY_USER` | SSH user allowed to run `docker` (member of the `docker` group). |
| `DEPLOY_SSH_KEY` | Private key of a key pair dedicated to deploys, authorized for `DEPLOY_USER`. |
| `DEPLOY_KNOWN_HOSTS` | Output of `ssh-keyscan -t ed25519 <host>`, so the runner pins the host key. |

The caller must grant `packages: write` (see the usage example).

### Server contract

- Docker and the Compose plugin installed; `DEPLOY_USER` can run `docker`.
- Logged in to GHCR once, with a token that has `read:packages`
  (`echo $TOKEN | docker login ghcr.io -u <user> --password-stdin`), since images are private.
- A compose project in `compose-dir` where the portal's service takes its tag from
  `tag-variable`. The pipeline keeps that variable in the project's `.env`, so a manual
  `docker compose up -d` keeps the deployed version. To roll back, re-run the workflow for
  an older commit.

Minimal example with Caddy as the reverse proxy (automatic HTTPS per domain):

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
    image: ghcr.io/owner/berlinesa-developers-platform:${DEVELOPERS_PORTAL_TAG:-latest}
    restart: unless-stopped

volumes:
  caddy_data:
```

```caddyfile
# /opt/stack/Caddyfile
developers.example.com {
  reverse_proxy developers-portal:80
}
```
