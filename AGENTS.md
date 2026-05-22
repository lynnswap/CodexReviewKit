# AGENTS

## Tests

- Package tests:

  ```bash
  swift test --build-system swiftbuild --no-parallel
  ```

- ReviewMonitor app tests:

  ```bash
  xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj -scheme CodexReviewMonitor -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  ```
