#!/bin/sh
# launchd entry point: run the sandboxed scan, then bring the app forward regardless of outcome.
DATA_DIR="$HOME/Library/Application Support/DiskReport"
LOG_DIR="$HOME/Library/Logs/DiskReport"
mkdir -p "$LOG_DIR"

/usr/bin/sandbox-exec -D "DATA_DIR=$DATA_DIR" -D "LOG_DIR=$LOG_DIR" -f "$DATA_DIR/bin/scan.sb" \
  "$DATA_DIR/bin/diskreport-scan" --data-dir "$DATA_DIR" --log-dir "$LOG_DIR"
status=$?

/usr/bin/open -a "$HOME/Applications/DiskReport.app" --args --show-report
exit $status
