---
name: deploy-project
description: >-
  Deploy the current project to a live public HTTPS URL with a real PostgreSQL
  database, using InstaScale. Use when the user asks to deploy, publish, host,
  or "put this online", or asks for a link to share. Handles preparing the
  project first — a Dockerfile, migrating SQLite to Postgres, a production
  build — then deploys and returns the URL.
---

# Deploy this project with InstaScale

You are deploying the user's project to InstaScale. It builds the project into
a container, runs it on Cloud Run, gives it a PostgreSQL database, and returns a
public HTTPS URL that stays the same across redeploys.

**Your job is to prepare the project so it can be hosted, then deploy it.** Most
vibe-coded projects need one or two changes first. That is expected.

## 0. Read the rules first

```bash
instascale --instructions
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

**Adding deployment config** (a `Dockerfile`, an `instascale.yaml`) is routine.
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

The plugin puts `instascale` on your PATH. Call it by that name — permission
rules match the command text, so a path into the home directory would depend on
where the plugin happens to be installed and would stop matching the moment that
changed.

> If `instascale: command not found`, this skill was installed as a bare
> directory rather than as a plugin. Everything still works; use
> `~/.claude/skills/deploy-project/scripts/deploy.sh` in place of `instascale`
> below, and allow that path instead. Installing the plugin is the tidier fix.

```bash
# First deploy (no instascale.yaml yet):
instascale --name "my-app" --database postgres

# Later deploys — the project id in instascale.yaml is picked up automatically:
instascale
```

The script prints the deployment state as it goes and the URL when it is ready.

### If you deploy by hand instead

`POST $INSTASCALE_API/v1/deployments?wait=90` as `multipart/form-data` with a
`metadata` part and a `source` part, plus `Authorization`, `Idempotency-Key` and
`InstaScale-Request-Digest`. The digest formula is in the instructions. Use a
**new** idempotency key for each real deploy, and the **same** one when retrying
after a lost response.

### Secrets and environment variables

**The script handles this.** If the project has a `.env`, `instascale` uploads
every key in it to the secrets endpoint before deploying, and Cloud Run injects
them at boot.

You do not need to ask the user to paste anything, and there is no dashboard
form for this — if you find yourself inventing one, stop and re-read this
section.

```bash
instascale                              # uses .env if present
instascale --env-file .env.production   # a different file
instascale --no-secrets                 # ignore .env entirely
```

Rules that matter:

- **Never put a value in `instascale.yaml`.** That file is committed. A
  service-role key there is permanent and public the moment the repo is.
- **Never put a value in a deploy request or the source.** The archive becomes
  an image anyone who can pull it can read. `.env*` is already excluded from
  the archive; keep it that way.
- **Never print a value.** Your transcript is somewhere neither you nor the
  user can erase. Print names.
- To manage them directly: `PUT /v1/projects/{id}/secrets` with
  `{"secrets":{"NAME":"value"}}`, `GET` for names, `DELETE .../secrets/{name}`.
  There is no endpoint that reads a value back, by design.

If the user brings their own database — Supabase, Neon — put its `DATABASE_URL`
in `.env` and **omit `database:` from the manifest**. Declaring `postgres` as
well provisions one they did not ask for.

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
- that `instascale.yaml` should be committed — it is what keeps the URL stable

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

`INSTASCALE_TOKEN` and `INSTASCALE_API` come from the user's
`~/.claude/settings.json`. If the token is unset, tell them:

> Sign in at https://app.instascale.ai. The
> dashboard shows a settings block with your key already in it — merge it into
> `~/.claude/settings.json` and restart Claude Code.

Do not guess a token, do not commit one, and do not offer to write it into the
project.

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
      "Bash(instascale:*)",
      "WebFetch(domain:app.instascale.ai)"
    ]
  }
}
```

One rule, naming one program. Do **not** suggest `Bash(curl:*)` instead: that
grants curl to every host on the internet to save the user one line, and a
host-scoped curl rule does not actually bind — a URL can carry our hostname in a
query string while pointing somewhere else entirely.

Approving the prompt interactively works too, but only for that session.

**Never put the token on a command line.** It is already in the environment, so
`INSTASCALE_TOKEN=... instascale` adds nothing and is refused by the classifier
as an inline credential — which reads as a network problem and is not one. Run
`instascale` plain.

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
