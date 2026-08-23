---
name: deploy-project
description: >-
  Deploy the current project to a live public HTTPS URL with a real PostgreSQL
  database, using InstaDeploy. Use when the user asks to deploy, publish, host,
  or "put this online", or asks for a link to share. Handles preparing the
  project first — a Dockerfile, migrating SQLite to Postgres, a production
  build — then deploys and returns the URL.
---

# Deploy this project with InstaDeploy

You are deploying the user's project to InstaDeploy. It builds the project into
a container, runs it on Cloud Run, gives it a PostgreSQL database, and returns a
public HTTPS URL that stays the same across redeploys.

**Your job is to prepare the project so it can be hosted, then deploy it.** Most
vibe-coded projects need one or two changes first. That is expected.

## 0. Read the rules first

```bash
instadeploy --instructions
```

**Do this before you change or generate anything.** It returns the
preconditions, a Dockerfile template for each stack, the manifest schema and the
deploy protocol. It is served live, so it is always current — do not work from
memory of a previous run.

## 1. Check the project against the preconditions

Read the project. For each precondition in the instructions, decide whether it
already holds.

The ones that matter most in practice:

| | What to look for |
|---|---|
| **SQLite** | `better-sqlite3`, `sqlite3`, `aiosqlite`, `provider = "sqlite"`, `sqlite://`. **This is the most common problem.** Cloud Run's filesystem is ephemeral — a SQLite app deploys, works, and loses every row on the next cold start. It has to move to PostgreSQL. |
| **Dev server** | `nodemon`, `next dev`, bare `vite`, `--reload`, `flask --debug` as the start command. A dev server does not serve a build, and debug mode must not be public. |
| **`$PORT`** | The app must read `PORT` from the environment and bind `0.0.0.0`. A hardcoded port produces a container that starts and is never reachable. |
| **Broken start command** | A start script referencing a gitignored file (`--env-file=.env.local` is the classic) builds fine and then exits at boot. |
| **Local file storage** | Uploads or generated files written to disk vanish. Same problem as SQLite. |

## 2. Fix what is missing — and show your work

**Adding deployment config** (a `Dockerfile`, an `instadeploy.yaml`) is routine.
Mention it and continue.

**Changing the user's application** — migrating SQLite to Postgres, changing how
the server starts — is a bigger step. **Show the diff and ask before doing it.**

> If the user declines a SQLite migration, **stop. Do not deploy.** The app will
> work and then lose their data, and they will find out later, probably in front
> of someone. Explain that and let them come back.

**Never overwrite an existing `Dockerfile`.** If the repo has one, validate it
and use it as-is. Only generate one when none exists.

For a Dockerfile, adapt the template from the instructions for the detected
stack rather than writing one from scratch.

## 3. Deploy

Use the bundled scripts — they handle the archive exclusions, the request
digest and the polling, which are easy to get subtly wrong:

The plugin puts `instadeploy` on your PATH. Call it by that name — permission
rules match the command text, so a path into the home directory would depend on
where the plugin happens to be installed and would stop matching the moment that
changed.

> If `instadeploy: command not found`, this skill was installed as a bare
> directory rather than as a plugin. Everything still works; use
> `~/.claude/skills/deploy-project/scripts/deploy.sh` in place of `instadeploy`
> below, and allow that path instead. Installing the plugin is the tidier fix.

```bash
# First deploy (no instadeploy.yaml yet):
instadeploy --name "my-app" --database postgres

# Later deploys — the project id in instadeploy.yaml is picked up automatically:
instadeploy
```

The script prints the deployment state as it goes and the URL when it is ready.

### If you deploy by hand instead

`POST $INSTADEPLOY_API/v1/deployments?wait=90` as `multipart/form-data` with a
`metadata` part and a `source` part, plus `Authorization`, `Idempotency-Key` and
`InstaDeploy-Request-Digest`. The digest formula is in the instructions. Use a
**new** idempotency key for each real deploy, and the **same** one when retrying
after a lost response.

## 4. Handle the response

- **`200` with `state: "ready"`** — done. Give the user the `url`.
- **`400` with `PRECONDITIONS_NOT_MET`** — the project was rejected before
  building. Read `fixHint` and `filesToFix`, fix them, deploy again.
- **`202`** — still running. Poll `statusUrl` every 5 seconds until
  `terminal: true`. **Do this yourself; do not ask the user to check.**
- **`state: "failed"`** — read `fixHint`, `filesToFix`, and
  `GET /v1/deployments/{id}/logs`. Fix and redeploy with a new idempotency key.

**Repair up to three times before asking the user for help.** The user should
see a working link, not a running commentary of failures.

If a redeploy fails, `projectUrl` tells you what is still serving — say *"the new
version failed; your app is still running at X"*, never imply it went down.

## 5. Report

Give the user:

- the **URL**
- what you changed and why, if anything
- whether it has a database
- that `instadeploy.yaml` should be committed — it is what keeps the URL stable

## Rules

- Read `/v1/instructions` before generating anything.
- Never overwrite an existing `Dockerfile`.
- Show a diff before changing application code; let the user decline.
- Never deploy SQLite or local-file persistence. Stop instead.
- Never put a secret value in the manifest, the source, or a request. Declare
  names only.
- Poll to a terminal state yourself.
- Report the link only when `state` is `ready`.

## Setup

```bash
export INSTADEPLOY_API="https://instadeploy-api-315525417718.europe-west1.run.app"
export INSTADEPLOY_TOKEN="idp_..."
```

If `INSTADEPLOY_TOKEN` is unset, tell the user to get one:

> Sign in at https://instadeploy-api-315525417718.europe-west1.run.app. Your key
> is on the page with the two export lines ready to copy.

Then ask them to paste it. Do not guess one, and do not commit it to the repo.

## Permissions

Claude Code blocks network calls to hosts it has not been told about, so a first
deploy can fail on a permission denial rather than on anything to do with the
project. That is the sandbox working, not a fault.

If a call is denied, tell the user to merge this into `~/.claude/settings.json`.
Claude Code reloads settings without a restart.

```json
{
  "permissions": {
    "allow": [
      "Bash(instadeploy:*)",
      "WebFetch(domain:instadeploy-api-315525417718.europe-west1.run.app)"
    ]
  }
}
```

One rule, naming one program. Do **not** suggest `Bash(curl:*)` instead: that
grants curl to every host on the internet to save the user one line, and a
host-scoped curl rule does not actually bind — a URL can carry our hostname in a
query string while pointing somewhere else entirely.

Approving the prompt interactively works too, but only for that session.

Do not look for a way around a denied call. A permission refusal is the user's
decision, and routing the same request through a different tool to dodge it
defeats the point of their asking to be asked.

## Limits

Three projects and $2 of deployment credit per account, shared across projects.
Deleting a project from the dashboard frees its slot.

These arrive as errors with their own codes, and none of them are worth
retrying — say what happened and stop:

| Code | What it means |
|---|---|
| `PROJECT_QUOTA_EXCEEDED` | Three projects already exist. Delete one, or pass `projectId` to redeploy an existing one. |
| `CREDIT_EXHAUSTED` | The $2 is used up. The account's apps have been stopped. |
| `ACCOUNT_SUSPENDED` | Same cause, seen from the account rather than the deploy. |
| `DEPLOYS_PAUSED` | The operator paused deploys. Nothing was lost; try later. |
