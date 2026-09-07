#!/bin/bash
set -eu
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reader.py" "$@"
