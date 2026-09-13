# Adding Share Extension Target to Xcode

Since `xcodeproj` Ruby gem is not installed, follow these steps to add the Share Extension target to your Xcode project.

## Method 1: Manual Addition via Xcode

### Step 1: Open Your Project
```bash
open AirBridge.xcodeproj
```

### Step 2: Create New Target
1. Select the project in the Project Navigator
2. Click the **+** button at the bottom of the target list
3. Select **App Extension** under iOS
4. Choose **Share Extension**
5. Click **Next**

### Step 3: Configure Target
- **Product Name**: `ShareExtension`
- **Team**: Select your development team
- **Bundle Identifier**: `com.airbridge.ShareExtension`
- **Deployment Target**: iOS 17.0 (or your minimum target)

### Step 4: Replace Default Files
Replace the default files with our implementation:

1. Delete `ShareViewController.swift` created by Xcode
2. Copy our files into the ShareExtension folder:
   - `ShareExtension/ShareViewController.swift`
   - `ShareExtension/Info.plist`
   - `ShareExtension/MainInterface.storyboard`
   - `ShareExtension/ShareExtension.entitlements`

3. In Xcode, right-click on ShareExtension group → **Add Files to "ShareExtension"**
4. Select all four files from the ShareExtension folder

### Step 5: Configure Build Settings
For the ShareExtension target, set these build settings:

```
ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES
CODE_SIGN_ENTITLEMENTS = ShareExtension/ShareExtension.entitlements
INFOPLIST_FILE = ShareExtension/Info.plist
SKIP_INSTALL = YES
TARGETED_DEVICE_FAMILY = 1,2
LD_RUNPATH_SEARCH_PATHS = (
    "$(inherited)",
    "@executable_path/Frameworks",
    "@executable_path/../../Frameworks"
)
```

### Step 6: Add App Group Entitlement
1. Select the ShareExtension target
2. Go to **Signing & Capabilities**
3. Click **+ Capability**
4. Select **App Groups**
5. Add: `group.com.airbridge.shared`

### Step 7: Add App Group to Main App
1. Select the main AirBridge target
2. Go to **Signing & Capabilities**
3. Add the same **App Groups** capability with `group.com.airbridge.shared`

### Step 8: Build
```bash
xcodebuild -project AirBridge.xcodeproj -scheme ShareExtension \
    -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 15' build
```

## Method 2: Using Python Script

If you have Python installed, you can use the `add_target.py` script:

```bash
python3 ShareExtension/add_target.py
```

This will attempt to add the target to `project.pbxproj`. Note that Xcode may require regeneration of the project after modification.

## Required Capabilities

Both the main app and the Share Extension need these capabilities:

### Main App (AirBridge)
- App Groups: `group.com.airbridge.shared`
- URL Scheme: `airbridge://` (already configured)

### Share Extension
- App Groups: `group.com.airbridge.shared`

## Testing the Share Extension

1. Run the main app on a device or simulator
2. Open the Photos app
3. Select a photo and tap Share
4. Find and tap "AirBridge" in the share sheet
5. The extension should open briefly and then launch the main app
6. The main app should show the file ready to send

## Troubleshooting

### Extension Not Appearing in Share Sheet
- Verify the extension target is built
- Check Info.plist NSExtensionActivationRule
- Ensure the extension is embedded in the app

### Files Not Reaching Main App
- Verify App Groups configuration matches
- Check the URL scheme is correctly registered in main app's Info.plist
- Look for errors in the device console

### Build Errors
- Ensure all files are added to the correct target
- Check for missing imports (ShareHelper is in a separate file)
- Verify deployment target compatibility
