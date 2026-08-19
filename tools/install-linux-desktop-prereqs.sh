#!/usr/bin/env bash
# Install Linux GTK/desktop packages with bounded apt calls.
# Hosted Ubuntu runners can stall on azure.archive.ubuntu.com; a hang must fail
# this step instead of cancelling the whole CI or release job.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 package [package...]" >&2
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
attempt=1
while [ "$attempt" -le 3 ]; do
  if timeout 90s sudo apt-get -o Acquire::Retries=2 update; then
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    echo 'apt-get update failed after three bounded attempts.' >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 5
done

timeout 180s sudo apt-get install -y "$@"
