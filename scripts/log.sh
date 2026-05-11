#!/usr/bin/env bash

set -euo pipefail

# ---
# Internal logging helper
# ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $1 == "info" ]]; then
  shift
  echo -e "${GREEN}[INFO]${NC} $*"
elif [[ $1 == "warn" ]]; then
  shift
  echo -e "${YELLOW}[WARN]${NC} $*"
elif [[ $1 == "error" ]]; then
  shift
  echo -e "${RED}[ERROR]${NC} $*"
  exit 1
else
  echo -e "${RED}[ERROR]${NC} Invalid log level: $1"
  exit 1
fi
