#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
failed=0
for t in "$SCRIPT_DIR"/test_*.sh; do
	[ -f "$t" ] || continue
	echo "=== $(basename "$t") ==="
	bash "$t" || failed=1
	echo ""
done
exit "$failed"
