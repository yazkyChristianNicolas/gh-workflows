# gh-workflows

Reusable GitHub Actions workflows, callable from any of my repos.

## Available workflows

| Workflow | Stack | Trigger |
|---|---|---|
| `java-spring.yml` | Java 21 + Spring Boot | push to main, PR |
| `node-ts.yml` | Node 20 + TypeScript | push to main, PR |
| `docker-publish.yml` | Docker + GHCR | push tags `v*` |

## Usage

```yaml
jobs:
  build:
    uses: yazkyChristianNicolas/gh-workflows/.github/workflows/java-spring.yml@main
    with:
      java-version: '21'
```
