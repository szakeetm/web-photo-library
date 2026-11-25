#!/bin/bash
# Runs the server test suite. With Command Line Tools (no Xcode) the Swift Testing
# macro plugin intermittently fails to load ("plugin for module 'TestingMacros' not
# found"); retry the build when that is the only problem.
cd "$(dirname "$0")/../server" || exit 1
for attempt in 1 2 3 4 5; do
  swift test "$@" > .build/test-output.log 2>&1
  rc=$?
  if [ $rc -ne 0 ] && grep -q "plugin for module 'TestingMacros' not found" .build/test-output.log; then
    continue
  fi
  break
done
sed 's/\x1b\[[0-9;]*m//g' .build/test-output.log | grep -E "error:|✘|Test run with|Expectation failed|recorded an issue" | grep -v -E "SwiftCompile|swift-frontend" | head -60
exit $rc
