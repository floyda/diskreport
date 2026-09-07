#!/bin/sh
# Fails if any write-capable filesystem call appears in any DiskReport target outside the modules
# explicitly allowed to write (Store/, Logging/) and the lint-exempt self-test file.
# The app targets are covered too: layer 3 of the guardrails is that the app never writes anywhere,
# so a write call appearing there is as much a regression as one in the scanner.
set -eu
cd "$(dirname "$0")/.."

PATTERN='unlink\(|rmdir\(|rename\(|truncate\(|utimes\(|chmod\(|chown\(|O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND|removeItem|moveItem\(|copyItem\(|createFile\(|createDirectory\(|\.write\(to|FileHandle\(forWritingTo|FileHandle\(forUpdating|fopen\(|mkdir\(|unlinkat\(|renameat\(|mkdirat\(|openat\(|fchmodat\(|utimensat\(|linkat\(|symlinkat\(|setxattr\(|removexattr\(|trashItem|replaceItem|createSymbolicLink|linkItem\('

FILES=$(find Sources/DiskReportCore Sources/diskreport-scan Sources/DiskReport Sources/DiskReportUI -name '*.swift' \
  | grep -v '/Store/' \
  | grep -v '/Logging/' \
  | grep -v 'SelfTestWrite.swift' || true)

if [ -z "$FILES" ]; then
  echo "lint-readonly: no files to check"
  exit 0
fi

if grep -nE "$PATTERN" $FILES; then
  echo "lint-readonly: FAIL — write-capable call found outside Store/ or Logging/"
  exit 1
fi
echo "lint-readonly: ok"
