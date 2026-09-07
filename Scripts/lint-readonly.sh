#!/bin/sh
# Fails if any write-capable filesystem call appears in DiskReportCore or diskreport-scan
# outside the modules explicitly allowed to write (Store/, Logging/) and the lint-exempt self-test file.
set -eu
cd "$(dirname "$0")/.."

PATTERN='unlink\(|rmdir\(|rename\(|truncate\(|utimes\(|chmod\(|chown\(|O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND|removeItem|moveItem\(|copyItem\(|createFile\(|createDirectory\(|\.write\(to|FileHandle\(forWritingTo|FileHandle\(forUpdating|fopen\(|mkdir\('

FILES=$(find Sources/DiskReportCore Sources/diskreport-scan -name '*.swift' \
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
