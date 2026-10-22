# repo-setup

Configures a repository for the build-once / promote flow of this repo's workflows
(`docusaurus-portal.yml`, `promote-image.yml`, `deploy-compose.yml`), so a new project
doesn't need the setup done by hand in the GitHub UI:

```
feature/*  --PR-->  development  --PR-->  main
                    deploys to the        deploys to the
                    `development` env     `production` env
```

There are only two long-lived branches, `development` and `main`. `development` and
`production` are the names of the GitHub **environments** each branch deploys to.

```bash
./setup-repo.sh configs/<project>.json --dry-run   # shows what it would change
./setup-repo.sh configs/<project>.json             # applies it
```

It is idempotent: it converges the repository to the config and can be re-run after editing
it. **The config is the source of truth**: a value changed by hand in GitHub for a key that
is in the config is overwritten on the next run (e.g. `DEPLOY_ENABLED`).

Requires `gh` (logged in as a user with admin access to the repository) and `jq`.

## New project in one command

`new-project.sh` creates the repository, writes the `development.yml` / `production.yml`
callers, generates `configs/<repo>.json` and runs `setup-repo.sh`:

```bash
./new-project.sh owner/my-app --domain example.com --sub app \
  --compose-service my-app --tag-variable MY_APP_TAG --stack node --dry-run   # shows everything
./new-project.sh owner/my-app --domain example.com --sub app \
  --compose-service my-app --tag-variable MY_APP_TAG --stack node
```

It checks that all secrets are in `secrets.env` before creating anything, and it is idempotent.
It does not generate the Dockerfile nor the server's compose/Caddy blocks.

## What it configures

| Area | What |
|---|---|
| Default branch | Creates `default_branch` from the current default branch if missing, makes it the default (new PRs target it) and deletes branches after merge. |
| Rulesets | `protect-<branch>` for each of `protected_branches`: PR required (with `required_approvals`), `required_checks` must pass, no force push, no deletion. Private repositories need GitHub Pro (skipped with a warning otherwise). |
| Actions | `GITHUB_TOKEN` read-only by default (the workflows request what they need); Actions may open pull requests. |
| Environments | One per entry in `environments`, tied to the `branch` that deploys to it (deploys from any other branch are rejected), optional required `reviewers`, its `variables` and `secrets`. |
| Repository | `variables` and `secrets`. |

## Config

```json
{
  "repository": "owner/repo",
  "default_branch": "development",
  "protected_branches": ["development", "main"],
  "required_checks": ["portal / verify"],
  "required_approvals": 0,
  "environments": {
    "development": {
      "branch": "development",
      "variables": { "DEPLOY_ENABLED": "true", "COMPOSE_DIR": "/opt/stack-dev" }
    },
    "production": {
      "branch": "main",
      "reviewers": ["github-login"],
      "variables": { "DEPLOY_ENABLED": "false", "COMPOSE_DIR": "/opt/stack" },
      "secrets": []
    }
  },
  "variables": { "API_NUMBER": "1" },
  "secrets": ["DEPLOY_HOST", "DEPLOY_USER", "DEPLOY_SSH_KEY", "DEPLOY_KNOWN_HOSTS"]
}
```

- `required_checks`: check names as they appear on a PR. For the reusable workflows they are
  `<caller job id> / <job>`, e.g. `portal / verify`.
- `secrets` (repository or per environment) are **names only**. With a single server, put the
  `DEPLOY_*` secrets at repository level: both environments read them. Use an environment's
  `secrets` when it deploys somewhere else.

## Secrets

Values come from a local file **outside any git repository**, default
`~/.config/gh-workflows/secrets.env` (override with `GH_SETUP_SECRETS`). See
`secrets.env.example`:

```bash
DEPLOY_HOST=203.0.113.10
DEPLOY_SSH_KEY=@~/.ssh/berlinesa_deploy       # @path: read the value from a file
```

The same file serves every repository, so adding a project is: write its config, run the
script. Keep the file readable only by you (`chmod 600`).

## Not covered

- The server side (deploy user, GHCR login, compose projects): see the main README's
  "Server contract".
- Restricting `main` to PRs coming **only** from `development`: rulesets cannot express the
  source branch. The promotion pipeline already refuses content that was not built on
  `development`.
- PRs opened by workflows with `GITHUB_TOKEN` (e.g. a spec sync) don't trigger other
  workflows, so a required check never reports on them: close and reopen the PR, or push a
  commit, to run it.
