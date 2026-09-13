# Swift / Xcode Project Configuration

Generated automatically by Agent Code.

## Project metadata

Workspace:
None

Project:
AirBridge.xcodeproj

Primary target:
AirBridge

Primary scheme:
AirBridge

Supported platforms:
iphoneos iphonesimulator macosx xros xrsimulator

## Platform interpretation

Interpret SUPPORTED_PLATFORMS dynamically.

Examples:
- macosx → macOS
- iphoneos → iOS device
- iphonesimulator → iOS Simulator
- xros → visionOS device
- xrsimulator → visionOS Simulator
- appletvos → tvOS
- watchos → watchOS

Do not assume that the project is iOS-only or macOS-only.

A project may support multiple Apple platforms.

## Destination discovery

Before selecting a destination, inspect actual Xcode destinations with:

```bash
xcodebuild -showdestinations
```

using the detected project/workspace and scheme.

Never invent:
- simulator models
- OS versions
- destination IDs

Use only destinations reported by Xcode.

## Build verification rule

Never conclude that a project is:

- compilable
- non-compilable
- probably compilable
- probably non-compilable

when an actual build can verify the result.

Run the appropriate xcodebuild command and report the real outcome.

## Build strategy

Choose a build strategy based on supported platforms and available destinations.

For macOS:
- use a real macOS destination reported by Xcode

For iOS Simulator:
- choose an actually available simulator destination

For iOS device validation without signing:
- generic/platform=iOS may be used when appropriate
- do not change signing settings in the project

For visionOS Simulator:
- choose an actually available visionOS simulator

## Safety

Do not modify without explicit user request:

- Apple Developer Team
- signing
- certificates
- provisioning profiles
- bundle identifiers
- deployment targets
- entitlements
- capabilities
- project.pbxproj
- Info.plist privacy declarations
- scheme definitions

Do not downgrade deployment targets merely because they appear unfamiliar.

Treat the installed Xcode SDK and project configuration as the source of truth.

## Debug loop

When compilation fails:

1. read complete compiler output
2. identify the first root-cause error
3. inspect the relevant source
4. make the smallest correction
5. rebuild
6. repeat until success or a genuine blocker is identified

## Available destinations

The bootstrap detected the following Xcode destination information:

```text
Command line invocation:
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project AirBridge.xcodeproj -scheme AirBridge -showdestinations



	Available destinations for the "AirBridge" scheme:
		{ platform:macOS, arch:x86_64, id:49F45763-8748-5796-B6A3-6442683D449D, name:My Mac }
		{ platform:iOS, arch:arm64, id:00008140-00143D0E36A2801C, name:iPhone }
		{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
		{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
		{ platform:macOS, name:Any Mac }
		{ platform:iOS Simulator, arch:x86_64, id:33F16B0C-60D5-4D50-97B5-B7CEE8B7ECE3, OS:26.5, name:iPad mini (6th generation) }
		{ platform:iOS Simulator, arch:x86_64, id:308F214D-439C-4CE5-B3F8-AD1566CFE1DB, OS:26.5, name:iPhone 13 mini }
		{ platform:iOS Simulator, arch:x86_64, id:21A78551-E7A1-4231-B5EE-91EA1747CF9D, OS:26.5, name:iPhone 15 }
```

## Agent responsibilities

developer:
- implement Swift/SwiftUI changes
- preserve project architecture
- build after meaningful changes

tester-debugger:
- reproduce failures
- compile/test with Xcode
- diagnose root causes
- retest after correction

reviewer:
- verify correctness
- concurrency
- state management
- platform compatibility
- security/privacy
- regression risk
- unnecessary Xcode configuration changes

## Model routing

Use model: inherit.

Do not override coding-free-v2 / OmniRoute routing.
