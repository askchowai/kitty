#!/usr/bin/env bash
# server/hermes-push is the source of truth; the app bundles a copy (a unit test checks parity).
set -e; cd "$(dirname "$0")/.."
cp server/hermes-push/hermes_push.py server/hermes-push/plugin/kitty-push/hermes_push.py
cp server/hermes-push/hermes_push.py server/hermes-push/install.sh Kitty/Resources/hermes-push/
mkdir -p Kitty/Resources/hermes-push/plugin
cp server/hermes-push/plugin/kitty-push/plugin.yaml server/hermes-push/plugin/kitty-push/__init__.py Kitty/Resources/hermes-push/plugin/
echo synced
