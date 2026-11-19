#!/usr/bin/env bash
#
# demo-rollout.sh - demonstrate a zero-downtime rolling update and a rollback.
#
# Prerequisites: a cluster with the manifests applied (kubectl apply -k k8s).
# The script:
#   1. builds image tags 1.0.0 and 1.1.0 (and imports them when the cluster is k3d;
#      OrbStack / Docker Desktop Kubernetes use the local Docker images directly)
#   2. starts a probe pod that calls the Service every 50 ms from inside the cluster
#      (the same endpoint switching an Ingress relies on, without needing a controller)
#   3. rolls out 1.1.0, then runs `kubectl rollout undo`
#   4. reports how many requests failed during each step (expected: 0)
#
# Usage: k8s/demo-rollout.sh [kube-context]   (default: k3d-devops-task)

set -euo pipefail

readonly CONTEXT="${1:-k3d-devops-task}"
readonly NS=devops-task
readonly PROBE_NS=default
readonly PROBE=rollout-probe
readonly SVC_URL="http://app.${NS}.svc.cluster.local/"

kc() { kubectl --context "$CONTEXT" "$@"; }
step() { printf '\n==> %s\n' "$*"; }

step "Build image versions 1.0.0 and 1.1.0"
for v in 1.0.0 1.1.0; do
  docker build -q --target runtime --build-arg VERSION="$v" -t "devops-task:$v" . >/dev/null
  if [[ "$CONTEXT" == k3d-* ]]; then
    k3d image import "devops-task:$v" -c "${CONTEXT#k3d-}" >/dev/null
    echo "devops-task:$v built and imported into k3d"
  else
    echo "devops-task:$v built (cluster uses the local Docker image store)"
  fi
done

step "Current state"
kc -n "$NS" rollout status deployment/app --timeout=120s
kc -n "$NS" get deployment app -o wide

step "Start an in-cluster probe: GET ${SVC_URL} every 50 ms"
kc -n "$PROBE_NS" delete pod "$PROBE" --ignore-not-found --wait=true >/dev/null
kc -n "$PROBE_NS" run "$PROBE" --image=curlimages/curl:8.11.1 --restart=Never --command -- \
  sh -c "while true; do curl -s -o /dev/null -m 2 -w '%{http_code}\n' ${SVC_URL} || echo 000; sleep 0.05; done" >/dev/null
trap 'kc -n "$PROBE_NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
kc -n "$PROBE_NS" wait --for=condition=Ready "pod/$PROBE" --timeout=60s >/dev/null
sleep 3

seen=0
report() {
  local lines total failed
  lines="$(kc -n "$PROBE_NS" logs "$PROBE")"
  total=$(printf '%s\n' "$lines" | wc -l | tr -d ' ')
  local new=$((total - seen))
  failed=$(printf '%s\n' "$lines" | tail -n "$new" | grep -vc '^200$' || true)
  echo "requests during $1: total=${new} non-200=${failed}"
  seen=$total
}
report "baseline"
kc -n "$NS" exec deploy/app -- wget -qO- http://127.0.0.1:3000/; echo

step "Rolling update to 1.1.0"
kc -n "$NS" set image deployment/app app=devops-task:1.1.0
kc -n "$NS" annotate deployment/app kubernetes.io/change-cause="update to 1.1.0" --overwrite >/dev/null
kc -n "$NS" rollout status deployment/app --timeout=180s
sleep 2
report "rolling update"
kc -n "$NS" exec deploy/app -- wget -qO- http://127.0.0.1:3000/; echo
kc -n "$NS" rollout history deployment/app

step "Rollback with kubectl rollout undo"
kc -n "$NS" rollout undo deployment/app
kc -n "$NS" rollout status deployment/app --timeout=180s
sleep 2
report "rollback"
kc -n "$NS" exec deploy/app -- wget -qO- http://127.0.0.1:3000/; echo
kc -n "$NS" get pods -o wide
