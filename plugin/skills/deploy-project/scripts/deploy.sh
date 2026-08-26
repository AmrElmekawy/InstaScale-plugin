#!/usr/bin/env bash
#
# Deploy the current directory to InstaScale.
#
# Exists so every agent does not reinvent tar exclusions, the request digest and
# the polling loop — each of which is easy to get subtly wrong in a way that
# only shows up as a confusing 409 or a duplicate deployment.
#
#   instascale                              # redeploy (reads instascale.yaml)
#   instascale --name my-app                # first deploy
#   instascale --name my-app --database postgres
#   instascale --env-file .env.production      # secrets from a named file
#   instascale --no-secrets                    # ignore .env entirely
#
set -euo pipefail

API="${INSTASCALE_API:-${INSTADEPLOY_API:-}}"
: "${API:?set INSTASCALE_API}"

# --instructions fetches the readiness contract and exits.
#
# It lives in this script rather than being a separate curl so that ONE
# permission rule covers everything the skill does. A rule that has to allow
# bare `curl` grants curl to every host on the internet; a rule naming this
# script grants exactly this script.
#
# Handled before the token is required, because the endpoint is unauthenticated
# and an agent should be able to read the rules before it has a key.
if [ "${1:-}" = "--instructions" ]; then
  curl -sS "$API/v1/instructions"
  exit $?
fi

TOKEN="${INSTASCALE_TOKEN:-${INSTADEPLOY_TOKEN:-}}"
: "${TOKEN:?set INSTASCALE_TOKEN}"

NAME="" ; DATABASE="" ; HEALTH="/" ; MIGRATION="" ; WAIT=90
ENVFILE="" ; NOSECRETS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="$2";      shift 2 ;;
    --database)    DATABASE="$2";  shift 2 ;;
    --health-path) HEALTH="$2";    shift 2 ;;
    --migration)   MIGRATION="$2"; shift 2 ;;
    --wait)        WAIT="$2";      shift 2 ;;
    --env-file)    ENVFILE="$2";   shift 2 ;;
    --no-secrets)  NOSECRETS=1;    shift 1 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- project identity -------------------------------------------------------
# The id lives in instascale.yaml and is what makes a redeploy land on the same
# URL and the same database. Deriving identity from the directory name would
# mean a rename creates a second service with an empty database — which to the
# user is indistinguishable from their data being deleted.
#
# The pre-rename file name is still read for exactly that reason: a project
# whose id we stop finding does not fail, it silently becomes a NEW project.
PROJECT_ID=""
CONFIG=""
for f in instascale.yaml instadeploy.yaml; do
  [ -f "$f" ] && { CONFIG="$f"; break; }
done
if [ -n "$CONFIG" ]; then
  PROJECT_ID="$(sed -n 's/^[[:space:]]*id:[[:space:]]*\(.*\)$/\1/p' "$CONFIG" | head -1 | tr -d '"'"'"' ')"
  [ -z "$NAME" ] && NAME="$(sed -n 's/^[[:space:]]*name:[[:space:]]*\(.*\)$/\1/p' "$CONFIG" | head -1 | tr -d '"'"'"' ')"
  [ -z "$DATABASE" ] && DATABASE="$(sed -n 's/^[[:space:]]*type:[[:space:]]*\(.*\)$/\1/p' "$CONFIG" | head -1 | tr -d '"'"'"' ')"
fi
# Migrate in place once the id has been read, so the old name disappears
# without the project ever losing its identity.
if [ "$CONFIG" = "instadeploy.yaml" ] && [ -n "$PROJECT_ID" ]; then
  mv instadeploy.yaml instascale.yaml
  CONFIG=instascale.yaml
  echo "renamed instadeploy.yaml to instascale.yaml (same project, same URL) - commit it"
fi
if [ -z "$PROJECT_ID" ] && [ -z "$NAME" ]; then
  echo "no instascale.yaml and no --name: cannot tell which project this is" >&2
  exit 2
fi

# --- secrets ----------------------------------------------------------------
# Values from .env go to the secrets endpoint, never into the archive or the
# manifest. The archive already excludes .env*, and instascale.yaml is a file
# the user is told to COMMIT — a service-role key in either is permanent.
#
# Secrets are scoped to a project, so this needs the project id. A first deploy
# does not have one until the response arrives; that case is handled after the
# deploy, below.
upload_secrets() {
  _pid="$1"
  _file="$2"
  [ -z "$_pid" ] && return 0
  [ -f "$_file" ] || return 0

  _payload="$(python3 - "$_file" <<'PARSE_ENV'
import json, sys
out = {}
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("export "):
        line = line[len("export "):].lstrip()
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    k, v = k.strip(), v.strip()
    # Strip one layer of matching quotes, the usual .env convention.
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    if k and v:
        out[k] = v
print(json.dumps({"secrets": out}))
PARSE_ENV
)"

  _count="$(printf '%s' "$_payload" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["secrets"]))')"
  [ "$_count" = "0" ] && return 0

  # NAMES are printed, values never are: this output lands in an agent
  # transcript, which is the one place we can neither control nor erase.
  echo "uploading $_count secret(s) from $_file:"
  printf '%s' "$_payload" | python3 -c 'import sys,json;[print("  -",k) for k in sorted(json.load(sys.stdin)["secrets"])]'

  _code="$(printf '%s' "$_payload" | curl -sS -o "$WORK/secrets.out" -w '%{http_code}' \
    -X PUT "$API/v1/projects/$_pid/secrets" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @-)"
  if [ "$_code" != "200" ]; then
    echo "could not store secrets (HTTP $_code):" >&2
    cat "$WORK/secrets.out" >&2
    return 1
  fi
  return 0
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Default to .env when the caller did not name a file.
if [ -z "$ENVFILE" ] && [ -f .env ]; then
  ENVFILE=.env
fi
if [ "$NOSECRETS" = "0" ] && [ -n "$ENVFILE" ] && [ -n "$PROJECT_ID" ]; then
  upload_secrets "$PROJECT_ID" "$ENVFILE" || exit 1
fi

# --- archive ----------------------------------------------------------------
# These exclusions are not cosmetic: node_modules alone can be 100x the size of
# the source, and .env* must never reach the image, where it is permanent and
# readable by anyone who can pull it.
tar --no-xattrs -czf "$WORK/source.tar.gz" \
  --exclude='./.git' --exclude='./node_modules' --exclude='./.venv' \
  --exclude='./venv' --exclude='./__pycache__' --exclude='./.next' \
  --exclude='./dist' --exclude='./build' --exclude='./target' \
  --exclude='./.env' --exclude='./.env.*' --exclude='./.DS_Store' \
  --exclude='./instascale-source.tar.gz' \
  . 2>/dev/null

# --- metadata ---------------------------------------------------------------
# Written once and hashed as-is. A retry must resend byte-identical content, so
# never regenerate this between attempts.
{
  printf '{'
  [ -n "$PROJECT_ID" ] && printf '"projectId":"%s",' "$PROJECT_ID"
  printf '"projectName":"%s",' "$NAME"
  printf '"manifest":{"name":"%s","healthPath":"%s"' "$NAME" "$HEALTH"
  if [ -n "$DATABASE" ] && [ "$DATABASE" != "none" ]; then
    printf ',"database":{"type":"%s"' "$DATABASE"
    [ -n "$MIGRATION" ] && printf ',"migration":"%s"' "$MIGRATION"
    printf '}'
  fi
  printf '}}'
} > "$WORK/metadata.json"

# --- request digest ---------------------------------------------------------
# SHA256("instascale-request-v1" || 0x00 || uint64be(len(metadata)) ||
#        metadata || sourceDigestBytes)
# The RAW 32 bytes of the source digest, not its hex text — hashing the hex
# gives a different answer and every retry would look like a different request.
DIGEST="$(python3 - "$WORK/metadata.json" "$WORK/source.tar.gz" <<'PY'
import hashlib, struct, sys
meta = open(sys.argv[1], 'rb').read()
src  = hashlib.sha256(open(sys.argv[2], 'rb').read()).digest()
h = hashlib.sha256()
h.update(b"instascale-request-v1\x00")
h.update(struct.pack(">Q", len(meta)))
h.update(meta)
h.update(src)
print("sha256=" + h.hexdigest())
PY
)"

# A new key per real deploy; reuse it only when retrying after a lost response.
KEY="$(python3 -c 'import uuid;print(uuid.uuid4())')"

echo "deploying ${NAME:-$PROJECT_ID} ($(du -h "$WORK/source.tar.gz" | cut -f1))..."

RESP="$(curl -sS -X POST "$API/v1/deployments?wait=$WAIT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: $KEY" \
  -H "InstaScale-Request-Digest: $DIGEST" \
  -F "metadata=<$WORK/metadata.json" \
  -F "source=@$WORK/source.tar.gz")"

# --- interpret --------------------------------------------------------------
show() { python3 -c '
import sys, json
d = json.load(sys.stdin)
err = d.get("error")
if isinstance(err, dict):
    print("FAILED:", err.get("code",""), "-", err.get("message",""))
    if d.get("filesToFix"): print("files to fix:", ", ".join(d["filesToFix"] or []))
    v = d.get("validation") or {}
    # `or []` rather than a .get default: the key is PRESENT and null, so the
    # default never applies and the loop raised TypeError over a perfectly good
    # error message.
    for f in (v.get("errors") or []):
        print("  [{}] {}: {}".format(f.get("precondition",""), f.get("file","-"), f.get("message","")))
        if f.get("fix"): print("      fix:", f["fix"])
    for f in (v.get("warnings") or []):
        print("  warning [{}] {}".format(f.get("precondition",""), f.get("message","")))
    sys.exit(1)
print("state:", d.get("state"))
if d.get("url"):        print("URL:", d["url"])
if d.get("projectId"):  print("projectId:", d["projectId"])
if d.get("errorMessage"): print("error:", d["errorMessage"])
if d.get("fixHint"):    print("hint:", d["fixHint"])
if d.get("filesToFix"): print("files to fix:", ", ".join(d["filesToFix"]))
if not d.get("terminal"): print("statusUrl:", d.get("statusUrl"))
sys.exit(0 if d.get("state") == "ready" else 2 if d.get("terminal") else 3)
'; }

set +e
echo "$RESP" | show
CODE=$?
set -e

# 3 means still running: poll it ourselves rather than handing that to the user.
#
# A function because there are TWO deploys on a first run — the initial one and
# the repeat that carries the secrets. Polling only the first left the second
# still building when the script exited, so the app was reported as deployed
# while the revision without its secrets was the one serving.
poll_if_running() {
  [ "$CODE" -eq 3 ] || return 0
  STATUS="$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["statusUrl"])')"
  for _ in $(seq 1 60); do
    sleep 5
    RESP="$(curl -sS "$API$STATUS" -H "Authorization: Bearer $TOKEN")"
    if echo "$RESP" | python3 -c 'import sys,json;sys.exit(0 if json.load(sys.stdin)["terminal"] else 1)'; then
      break
    fi
    echo "  $(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')..."
  done
  set +e; echo "$RESP" | show; CODE=$?; set -e
  return 0
}

poll_if_running

# --- first deploy: upload secrets, then deploy once more ---------------------
# A first deploy has no project id until the response arrives, so its secrets
# could not be uploaded beforehand. Upload them now and deploy again — otherwise
# the first revision runs without the variables the app needs and fails for a
# reason the user cannot see from the outside.
if [ $CODE -eq 0 ] && [ -z "$PROJECT_ID" ] && [ "$NOSECRETS" = "0" ] && [ -n "$ENVFILE" ] && [ -f "$ENVFILE" ]; then
  NEW_PID="$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("projectId",""))')"
  if [ -n "$NEW_PID" ] && upload_secrets "$NEW_PID" "$ENVFILE"; then
    echo "redeploying so the secrets are present at boot..."
    # A NEW idempotency key: this is a second real deploy, not a retry of the
    # first. Reusing the key would return the first deployment unchanged.
    KEY="$(python3 -c 'import uuid;print(uuid.uuid4())')"
    RESP="$(curl -sS -X POST "$API/v1/deployments?wait=$WAIT" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Idempotency-Key: $KEY" \
      -H "InstaScale-Request-Digest: $DIGEST" \
      -F "metadata=<$WORK/metadata.json" \
      -F "source=@$WORK/source.tar.gz")"
    set +e; echo "$RESP" | show; CODE=$?; set -e
    poll_if_running
  fi
fi

# --- record the project id --------------------------------------------------
# Committing this is what keeps the URL and the database stable next time.
if [ $CODE -eq 0 ] && [ -z "$PROJECT_ID" ]; then
  NEW_ID="$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["projectId"])')"
  if [ ! -f instascale.yaml ]; then
    {
      echo "version: 1"
      echo ""
      echo "# Written by InstaScale. COMMIT THIS FILE — it is what makes the next"
      echo "# deploy land on the same URL and the same database."
      echo "project:"
      echo "  id: $NEW_ID"
      echo "  name: $NAME"
      echo ""
      echo "runtime:"
      echo "  healthPath: $HEALTH"
      [ -n "$DATABASE" ] && [ "$DATABASE" != "none" ] && {
        echo ""
        echo "database:"
        echo "  type: $DATABASE"
        [ -n "$MIGRATION" ] && echo "  migration: \"$MIGRATION\""
      }
    } > instascale.yaml
    echo ""
    echo "wrote instascale.yaml — commit it, or the next deploy creates a new"
    echo "project with a different URL and an empty database."
  fi
fi

exit $CODE
