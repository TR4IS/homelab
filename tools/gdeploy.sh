#!/usr/bin/env bash
# gdeploy - send a project from this PC to the server and restart it. The server never needs GitHub.
#   gdeploy [project]          dry run: uploads to a temp folder, test-builds, changes NOTHING live
#   gdeploy [project] --go     really deploys (about 1 minute of downtime), with backup + rollback
# Run inside the project folder, or name a folder from your Code folder.
# Needs deploy.conf in the project (SERVER, REMOTE_DIR, CONTAINER, KEEP, INIT_JSON).
set -euo pipefail

src="${BASH_SOURCE[0]//\//}"; src="$(readlink -f "$src" 2>/dev/null || echo "$src")"
CODE_DIR="${CODE_DIR:-$(dirname "$(cd "$(dirname "$src")" && pwd)")}"
GO=0; PROJ=""
for a in "$@"; do case "$a" in --go) GO=1;; -h|--help) sed -n '2,6p' "$src" | sed 's/^# \{0,1\}//'; exit 0;; *) PROJ="$a";; esac; done
[ -z "$PROJ" ] || cd "$CODE_DIR/$PROJ"
cd "$(git rev-parse --show-toplevel)"
stop() { echo "STOP: $*"; exit 1; }

[ -f deploy.conf ] || stop "no deploy.conf in $(pwd)"
INIT_JSON=""; KEEP=""; REQUIRE_ENV=1; COMPOSE_FILES=""; SERVICES=""; PUBLIC_URL=""; BACKUP_VOLUMES=""; . ./deploy.conf
: "${SERVER:?}" "${REMOTE_DIR:?}" "${CONTAINER:?}"

echo "Project: $(basename "$(pwd)")   ->   $SERVER:$REMOTE_DIR   ($CONTAINER)"
git fetch -q origin
[ -z "$(git status --porcelain)" ] || stop "unsaved changes here. Run gsync first so GitHub has exactly what you deploy."
[ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}')" ] || stop "this commit is not on GitHub yet (or you are behind). Run gsync first."
[ "$(git branch --show-current)" = main ] || [ "${GDEPLOY_ANY_BRANCH:-0}" = 1 ] || stop "you are not on main."
COMMIT="$(git log -1 --format='%h %cs %s' | cut -c1-80)"
echo "Deploying: $COMMIT"
[ "$GO" = 1 ] && echo "MODE: REAL DEPLOY" || echo "MODE: dry run (nothing live changes)"

STAGE="/tmp/gdeploy-$CONTAINER-$$"
echo; echo "== Uploading code (tracked files only, no secrets)"
git archive --format=tar HEAD | ssh -o BatchMode=yes "$SERVER" "rm -rf '$STAGE' && mkdir -p '$STAGE' && tar -x -C '$STAGE'"

HDR="$(printf 'DIR=%q\nSTAGE=%q\nCONTAINER=%q\nKEEP=%q\nINIT_JSON=%q\nGO=%q\nCOMMIT=%q\nREQUIRE_ENV=%q\nCOMPOSE_FILES=%q\nSERVICES=%q\nBACKUP_VOLUMES=%q\n' \
  "$REMOTE_DIR" "$STAGE" "$CONTAINER" "$KEEP" "$INIT_JSON" "$GO" "$COMMIT" "$REQUIRE_ENV" "$COMPOSE_FILES" "$SERVICES" "$BACKUP_VOLUMES")"
{ printf '%s\n' "$HDR"; cat <<'REMOTE'
set -euo pipefail
say() { printf '\n== %s\n' "$*"; }
LC_NAME="$(echo "$CONTAINER" | tr 'A-Z' 'a-z')"
drop_stage() { rm -rf "$STAGE" "$STAGE.sh"; }

say "Checks on the server"
FILES=""; for f in $COMPOSE_FILES; do FILES="$FILES -f $f"; done
[ -d "$DIR" ] || echo "(first deploy: $DIR does not exist yet and will be created)"
[ -f "$STAGE/Dockerfile" ] && [ -f "$STAGE/docker-compose.yml" ] || { echo "STOP: Dockerfile / docker-compose.yml missing in the upload"; drop_stage; exit 1; }
[ ! -e "$STAGE/.env" ] || { echo "STOP: .env is inside the upload"; drop_stage; exit 1; }
if [ "$REQUIRE_ENV" = 1 ] && [ ! -f "$DIR/.env" ]; then
  if [ "$GO" = 1 ]; then echo "STOP: no .env in $DIR"; drop_stage; exit 1; fi
  echo "WARNING: no .env in $DIR yet - a real deploy will refuse to run until it exists."
fi
HAVE_OLD=0; docker inspect "$CONTAINER" >/dev/null 2>&1 && HAVE_OLD=1
# "managed by compose" only counts if it belongs to THIS folder's compose project (another stack, e.g. Portainer's, gets replaced instead)
PROJ="$(basename "$DIR" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]//g')"
COMPOSE_MODE=0
[ "$HAVE_OLD" = 1 ] && [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER")" = "$PROJ" ] && COMPOSE_MODE=1
echo "old container: $([ $HAVE_OLD = 1 ] && docker ps -a --filter name=^/$CONTAINER\$ --format '{{.Status}}' || echo none)   managed by compose: $COMPOSE_MODE"

say "Test build (the running bot is not touched)"
docker build -q -t "$LC_NAME:test" "$STAGE" >/dev/null < /dev/null && echo "image builds OK"

if [ "$GO" != 1 ]; then
  docker rmi "$LC_NAME:test" >/dev/null 2>&1 || true
  drop_stage
  say "DRY RUN PASSED - nothing live was changed. Run again with --go to deploy."
  exit 0
fi

TS="$(date +%Y%m%d-%H%M%S)"; BK="$HOME/backups/$LC_NAME-$TS"; mkdir -p "$BK" "$DIR"
say "Backup -> $BK"
for f in $KEEP; do if [ -e "$DIR/$f" ] && [ "$f" != node_modules ]; then cp -a "$DIR/$f" "$BK/"; fi; done
( cd "$DIR" && tar czf "$BK/old-code.tgz" --exclude=./node_modules --exclude=./logs --exclude=./.git . ) < /dev/null
[ "$HAVE_OLD" = 1 ] && docker inspect "$CONTAINER" > "$BK/old-container.json"
for v in $BACKUP_VOLUMES; do   # data volumes (databases, photos): copy them before anything is touched
  docker run --rm -u "$(id -u):$(id -g)" -v "$v":/d:ro -v "$BK":/b --entrypoint tar curlimages/curl czf "/b/volume-$v.tgz" -C /d . < /dev/null
  echo "volume $v saved: $(du -h "$BK/volume-$v.tgz" | cut -f1)"
done
PREV_IMG=""
if [ "$COMPOSE_MODE" = 1 ]; then
  PREV_IMG="$(docker inspect -f '{{.Image}}' "$CONTAINER")"; docker tag "$PREV_IMG" "$LC_NAME:previous"
  printf 'cd %s\ndocker tag %s:previous %s:latest\ndocker compose%s up -d --no-build %s\n' "$DIR" "$LC_NAME" "$LC_NAME" "$FILES" "$SERVICES" > "$BK/ROLLBACK.txt"
else
  cat > "$BK/ROLLBACK.txt" <<RB
cd $DIR
docker compose$FILES down || true
docker rm -f $CONTAINER 2>/dev/null || true
tar xzf $BK/old-code.tgz -C $DIR
[ -d $BK/dot-git ] && { rm -rf $DIR/.git; mv $BK/dot-git $DIR/.git; }
docker rename $CONTAINER-old $CONTAINER
docker start $CONTAINER
RB
fi
trap 'echo; echo "FAILED. To go back to the old bot run:  bash '"$BK"'/ROLLBACK.txt"' ERR

say "Switch (downtime starts)"
if [ "$COMPOSE_MODE" = 0 ] && [ "$HAVE_OLD" = 1 ]; then
  docker rm "$CONTAINER-old" >/dev/null 2>&1 || true
  docker stop "$CONTAINER" >/dev/null && docker rename "$CONTAINER" "$CONTAINER-old"
  [ -d "$DIR/.git" ] && mv "$DIR/.git" "$BK/dot-git"
fi
EXC=(--exclude /node_modules); for f in $KEEP; do EXC+=(--exclude "/$f"); done
rsync -a --delete "${EXC[@]}" "$STAGE"/ "$DIR"/ < /dev/null
for f in $KEEP; do
  if [ -d "$STAGE/$f" ]; then mkdir -p "$DIR/$f"; rsync -a "$STAGE/$f/" "$DIR/$f/" < /dev/null
  elif [ -e "$STAGE/$f" ] && [ ! -e "$DIR/$f" ]; then cp -a "$STAGE/$f" "$DIR/$f"; fi
done
[ -z "$INIT_JSON" ] || [ -f "$DIR/$INIT_JSON" ] || echo '{}' > "$DIR/$INIT_JSON"
[ ! -f "$DIR/.env" ] || chmod 600 "$DIR/.env"
echo "$COMMIT" > "$DIR/.deployed-commit"
( cd "$DIR" && docker compose$FILES up -d --build $SERVICES < /dev/null )

say "Check (waiting 15 s)"
sleep 15
( cd "$DIR" && docker compose$FILES ps ) < /dev/null
docker logs --tail 25 "$CONTAINER" 2>&1
drop_stage
echo
echo "If the status and logs above look healthy, you are done."
[ "$COMPOSE_MODE" = 0 ] && [ "$HAVE_OLD" = 1 ] && echo "The old container is kept as $CONTAINER-old. Remove it when happy:  docker rm $CONTAINER-old"
echo "Go back any time:  bash $BK/ROLLBACK.txt"
REMOTE
} | ssh -o BatchMode=yes "$SERVER" "cat > '$STAGE.sh'"
ssh -o BatchMode=yes "$SERVER" "bash '$STAGE.sh'; rc=\$?; rm -f '$STAGE.sh'; exit \$rc"
if [ "$GO" = 1 ] && [ -n "$PUBLIC_URL" ]; then
  echo; echo "== Public check: $PUBLIC_URL"
  sleep 3; curl -sS -m 20 -L -o /dev/null -w "HTTP %{http_code}  (%{size_download} bytes)\n" "$PUBLIC_URL" || echo "could not reach $PUBLIC_URL"
fi
