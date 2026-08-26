# InstaDeploy for Claude Code

Say "deploy this" in your project. You get a live HTTPS URL and a real
PostgreSQL database, usually in about a minute.

The plugin prepares the project first — writes a Dockerfile if there isn't one,
catches the things that would deploy successfully and then break in production
(SQLite on an ephemeral filesystem is the usual one), and only then deploys.

## Install

In Claude Code, run these **one at a time** — pasting both together makes Claude
Code read them as a single command and reject the marketplace name:

```
/plugin marketplace add AmrElmekawy/InstaScale-plugin
```

```
/plugin install instascale@instascale
```

## Set up

Sign in at <https://app.instascale.ai> and copy
your API key. Then merge this into `~/.claude/settings.json` and restart Claude
Code:

```json
{
  "env": {
    "INSTASCALE_TOKEN": "isc_...",
    "INSTASCALE_API": "https://app.instascale.ai"
  },
  "permissions": {
    "allow": [
      "Bash(instascale:*)",
      "WebFetch(domain:app.instascale.ai)"
    ]
  }
}
```

The dashboard shows this block with your key already in it.

One file rather than exports in a shell profile, because a variable set in a
different terminal from the one Claude Code is running in is the failure that
wastes an afternoon.

The permission half cannot be skipped: Claude Code refuses network calls to
hosts it has not been told about, and a plugin cannot grant itself permissions.
That is the sandbox working. One rule, naming one program, once.

That file now holds your API key, so treat it like a password and keep it out of
any repository.

## Limits

Three projects and $2 of deployment credit per account, shared across projects.
Deleting a project from the dashboard frees its slot.

## Development

This repository is generated. The plugin is developed alongside the API it
talks to, because the skill and the server's contract change together.
