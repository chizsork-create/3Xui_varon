#!/usr/bin/env bash
set -Eeuo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 -m unittest discover -s "$TEST_DIR" -p 'test_cloudflare*.py' -v
