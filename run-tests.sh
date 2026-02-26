#!/bin/bash
cd /Users/stephenfeather/Development/binbrain-ios
echo "Started: $(date)" > /tmp/binbrain-test-1.log
xcodebuild \
  -project "Bin Brain/Bin Brain.xcodeproj" \
  -scheme "Bin Brain" \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -skip-testing:"Bin BrainUITests" \
  -parallel-testing-worker-count 1 \
  test \
  >> /tmp/binbrain-test-1.log 2>&1
echo "Exit: $?" >> /tmp/binbrain-test-1.log
echo "Finished: $(date)" >> /tmp/binbrain-test-1.log
