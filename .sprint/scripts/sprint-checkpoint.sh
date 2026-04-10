#!/usr/bin/env bash
set -euo pipefail
git status
npm test
git diff --stat origin/main...HEAD
