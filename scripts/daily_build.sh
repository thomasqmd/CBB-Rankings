#!/bin/sh
# Daily in-season build: sync, refit what changed (tar_make), checks, and the dashboard and
# reports (rendered inside tar_make). Logs to logs/daily_<date>.log with the run time and the
# number of CBBD calls the build made (target: < 10 min, <= 2 calls). Scheduled by
# scripts/com.cbb-rankings.daily.plist (launchd).
cd "$(dirname "$0")/.." || exit 1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/quarto/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p logs
log="logs/daily_$(date +%Y%m%d).log"
calls_before=$(wc -l < logs/cbbd_calls.log 2>/dev/null || echo 0)
start=$(date +%s)
{
  echo "== $(date '+%F %T') daily build"
  Rscript -e 'targets::tar_make(reporter = "summary")'
  status=$?
  echo "== tar_make exit $status"
  Rscript check_build.R
  check=$?
  echo "== check_build exit $check"
  if [ "$status" -eq 0 ] && [ "$check" -eq 0 ]; then
    sh scripts/publish_pages.sh
    echo "== publish exit $?"
  else
    echo "== publish skipped (build or checks failed)"
  fi
  calls_after=$(wc -l < logs/cbbd_calls.log 2>/dev/null || echo 0)
  mins=$(( ($(date +%s) - start) / 60 ))
  echo "== $(date '+%F %T') done in ${mins} min, $((calls_after - calls_before)) CBBD calls"
  [ "$status" -eq 0 ] && [ "$check" -eq 0 ]
} >> "$log" 2>&1
