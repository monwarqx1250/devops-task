#!/usr/bin/env bash
#
# deploy-app.sh - deploy an image tag on the EC2 host and roll back on failure.
#
# Installed to /usr/local/bin/deploy-app.sh by the Terraform user data and run
# by CI through AWS SSM:
#   deploy-app.sh <image-tag>      deploy a tag; on failed health check, restore the previous tag
#   deploy-app.sh --rollback       redeploy the previously recorded tag
#   deploy-app.sh --current        print the currently deployed tag
#
# Configuration comes from /etc/devops-task/deploy.env (written by user data).
# Exit codes: 0 deployed, 1 deploy failed but rollback succeeded, 2 deploy and rollback failed, 3 usage error

set -euo pipefail

readonly CONFIG=/etc/devops-task/deploy.env
readonly STATE_DIR=/var/lib/devops-task
readonly CURRENT_FILE="$STATE_DIR/current_tag"
readonly PREVIOUS_FILE="$STATE_DIR/previous_tag"
readonly CONTAINER=app

# shellcheck source=/dev/null
[[ -r "$CONFIG" ]] && . "$CONFIG"
: "${ECR_REPOSITORY_URL:?ECR_REPOSITORY_URL is not set in $CONFIG}"
: "${AWS_REGION:?AWS_REGION is not set in $CONFIG}"
: "${LOG_GROUP:?LOG_GROUP is not set in $CONFIG}"
: "${APP_ENVIRONMENT:=staging}"
: "${LOG_LEVEL:=info}"
: "${HOST_PORT:=80}"
: "${HEALTH_TIMEOUT_SECONDS:=60}"

log() { printf '%s deploy-app: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

registry_login() {
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "${ECR_REPOSITORY_URL%%/*}" >/dev/null
}

run_container() {
  local tag="$1"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" \
    --restart unless-stopped \
    --init \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    --memory 256m --cpus 0.5 \
    -p "${HOST_PORT}:3000" \
    -e PORT=3000 \
    -e LOG_LEVEL="$LOG_LEVEL" \
    -e ENVIRONMENT="$APP_ENVIRONMENT" \
    -e APP_VERSION="$tag" \
    --log-driver awslogs \
    --log-opt awslogs-region="$AWS_REGION" \
    --log-opt awslogs-group="$LOG_GROUP" \
    --log-opt awslogs-stream="app-$(hostname)" \
    "${ECR_REPOSITORY_URL}:${tag}" >/dev/null
}

healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while ((SECONDS < deadline)); do
    if curl -fsS -m 3 "http://127.0.0.1:${HOST_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

deploy() {
  local tag="$1" previous=""
  [[ -r "$CURRENT_FILE" ]] && previous="$(<"$CURRENT_FILE")"

  log "deploying ${ECR_REPOSITORY_URL}:${tag} (previous: ${previous:-none})"
  registry_login
  if ! docker pull -q "${ECR_REPOSITORY_URL}:${tag}" >/dev/null; then
    log "ERROR: cannot pull tag ${tag}; leaving the running container untouched"
    return 2
  fi

  run_container "$tag"
  if healthy; then
    mkdir -p "$STATE_DIR"
    if [[ -n "$previous" && "$previous" != "$tag" ]]; then
      printf '%s\n' "$previous" >"$PREVIOUS_FILE"
    fi
    printf '%s\n' "$tag" >"$CURRENT_FILE"
    log "OK: ${tag} is healthy"
    docker image prune -af --filter "until=168h" >/dev/null 2>&1 || true
    return 0
  fi

  log "ERROR: ${tag} failed its health check; last log lines:"
  docker logs --tail 20 "$CONTAINER" 2>&1 || true
  if [[ -z "$previous" ]]; then
    log "no previous tag recorded; nothing to roll back to"
    return 2
  fi

  log "rolling back to ${previous}"
  run_container "$previous"
  if healthy; then
    log "rollback to ${previous} succeeded"
    return 1
  fi
  log "CRITICAL: rollback to ${previous} also failed"
  return 2
}

rollback() {
  [[ -r "$PREVIOUS_FILE" ]] || { log "no previous tag recorded"; return 2; }
  local previous
  previous="$(<"$PREVIOUS_FILE")"
  log "manual rollback to ${previous}"
  registry_login
  run_container "$previous"
  if healthy; then
    # Swap current/previous so a second rollback returns to where we were.
    [[ -r "$CURRENT_FILE" ]] && cp "$CURRENT_FILE" "$PREVIOUS_FILE"
    printf '%s\n' "$previous" >"$CURRENT_FILE"
    log "OK: rolled back to ${previous}"
    return 0
  fi
  log "CRITICAL: rollback to ${previous} failed its health check"
  return 2
}

case "${1:-}" in
  --rollback) rollback ;;
  --current) cat "$CURRENT_FILE" 2>/dev/null || echo "none" ;;
  "" | -h | --help) sed -n '3,13p' "$0"; [[ -n "${1:-}" ]] || exit 3 ;;
  -*) echo "unknown option: $1" >&2; exit 3 ;;
  *)
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "invalid image tag: $1" >&2; exit 3; }
    deploy "$1"
    ;;
esac
