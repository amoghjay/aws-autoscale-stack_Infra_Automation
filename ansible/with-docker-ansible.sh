#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAG="${IMAGE_TAG:-capstone-ansible:ssm}"

docker run --rm -it \
  -e AWS_PROFILE="${AWS_PROFILE:-default}" \
  -e AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}" \
  -e AWS_METADATA_SERVICE_TIMEOUT="${AWS_METADATA_SERVICE_TIMEOUT:-1}" \
  -e AWS_METADATA_SERVICE_NUM_ATTEMPTS="${AWS_METADATA_SERVICE_NUM_ATTEMPTS:-1}" \
  -e AWS_SESSION_MANAGER_PLUGIN="${AWS_SESSION_MANAGER_PLUGIN:-/usr/local/sessionmanagerplugin/bin/session-manager-plugin}" \
  -v "$DIR:/work" \
  -v "$HOME/.aws:/root/.aws:ro" \
  "$IMAGE_TAG" \
  "$@"
