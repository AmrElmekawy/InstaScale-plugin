# InstaDeploy for Claude Code

Say "deploy this" in your project. You get a live HTTPS URL and a real
PostgreSQL database, usually in about a minute.

The plugin prepares the project first — writes a Dockerfile if there isn't one,
catches the things that would deploy successfully and then break in production
(SQLite on an ephemeral filesystem is the usual one), and only then deploys.

## Install

```
/plugin marketplace add AmrElmekawy/instadeploy-plugin
/plugin install instadeploy@instadeploy
```

## Set up

Sign in at <https://instadeploy-api-315525417718.europe-west1.run.app>. Your API
key is on the page with the two export lines ready to copy:

```bash
export INSTADEPLOY_TOKEN="idp_..."
export INSTADEPLOY_API="https://instadeploy-api-315525417718.europe-west1.run.app"
```

Put them in `~/.zshrc` so they survive a new terminal.

Then merge this into `~/.claude/settings.json`:

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

Claude Code refuses network calls to hosts it has not been told about, and a
plugin cannot grant itself permissions — that is the sandbox working. One rule,
naming one program, once. Claude Code reloads settings without a restart.

## Limits

Three projects and $2 of deployment credit per account, shared across projects.
Deleting a project from the dashboard frees its slot.

## Development

This repository is generated. The plugin is developed alongside the API it
talks to, because the skill and the server's contract change together.
