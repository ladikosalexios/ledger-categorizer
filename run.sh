#!/usr/bin/env bash
# Usage: ./run.sh [input.csv] [output.csv]
set -euo pipefail
cd "$(dirname "$0")"

INPUT="${1:-sample/transactions.csv}"
OUTPUT="${2:-ledger_lines.csv}"

ruby processor.rb "$INPUT" "$OUTPUT"
