#!/usr/bin/env bash
#
# ssm-run.sh - run a shell command on an EC2 instance through AWS SSM, wait for
# it, print its output, and exit with the remote command's exit code.
#
# Usage: ssm-run.sh <instance-id> <command...>
# Needs AWS credentials (in CI: GitHub OIDC) and AWS_REGION.

set -euo pipefail

instance_id="${1:?usage: ssm-run.sh <instance-id> <command...>}"
shift
(($# > 0)) || { echo "usage: ssm-run.sh <instance-id> <command...>" >&2; exit 64; }
command_text="$*"

params=$(jq -cn --arg c "$command_text" '{commands: [$c], executionTimeout: ["600"]}')
command_id=$(aws ssm send-command \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "github-actions: ${GITHUB_SHA:-manual}" \
  --parameters "$params" \
  --query 'Command.CommandId' --output text)
echo "SSM command ${command_id}: ${command_text}" >&2

# `aws ssm wait` exits non-zero on remote failure; we read the real status below.
aws ssm wait command-executed --command-id "$command_id" --instance-id "$instance_id" 2>/dev/null || true

read -r status code < <(aws ssm get-command-invocation \
  --command-id "$command_id" --instance-id "$instance_id" \
  --query '[Status, ResponseCode]' --output text)

aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
  --query 'StandardOutputContent' --output text
stderr=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
  --query 'StandardErrorContent' --output text)
[[ -z "$stderr" || "$stderr" == "None" ]] || printf '%s\n' "$stderr" >&2

echo "SSM status: ${status}, exit code: ${code}" >&2
if [[ "$code" =~ ^-?[0-9]+$ ]] && ((code >= 0)); then
  exit "$code"
fi
exit 1
