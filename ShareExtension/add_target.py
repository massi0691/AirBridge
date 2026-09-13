#!/usr/bin/env python3
"""
Robust script to add Share Extension target to AirBridge Xcode project.
Uses careful regex-based insertion to avoid corrupting the project.
"""

import os
import re
import shutil
from datetime import datetime

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_PBX = os.path.join(PROJECT_DIR, '..', 'AirBridge.xcodeproj', 'project.pbxproj')
SCHEME_DIR = os.path.join(PROJECT_DIR, '..', 'AirBridge.xcodeproj', 'xcshareddata', 'xcschemes')

def read_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()

def write_file(path, content):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

def get_max_uuid(content):
    """Find the maximum UUID value in the project."""
    uuids = re.findall(r'(FC[A-F0-9]+)', content)
    if not uuids:
        return 'FC00000000000000000000000'
    max_uuid = max(uuids, key=lambda x: int(x, 16))
    return max_uuid

def next_uuid(current):
    """Get next UUID."""
    return format(current + 1, '024X')

def main():
    print("=" * 60)
    print("AirBridge Share Extension Target Adder (Robust Version)")
    print("=" * 60)

    # Read project
    print("\n[1] Reading project.pbxproj...")
    content = read_file(PROJECT_PBX)

    # Check if already added
    if 'ShareExtension.appex' in content:
        print("    ShareExtension already exists!")
        return False

    # Generate UUIDs
    print("\n[2] Generating UUIDs...")
    base = get_max_uuid(content)
    u = int(base, 16)

    # Core target UUIDs
    target = next_uuid(u); u = int(target, 16)
    appex_ref = next_uuid(u); u = int(appex_ref, 16)
    proxy = next_uuid(u); u = int(proxy, 16)
    config_list = next_uuid(u); u = int(config_list, 16)
    debug_cfg = next_uuid(u); u = int(debug_cfg, 16)
    release_cfg = next_uuid(u); u = int(release_cfg, 16)
    src_phase = next_uuid(u); u = int(src_phase, 16)
    res_phase = next_uuid(u); u = int(res_phase, 16)
    embed_phase = next_uuid(u); u = int(embed_phase, 16)
    target_dep = next_uuid(u); u = int(target_dep, 16)

    # Source file UUIDs
    sv_ref = next_uuid(u); u = int(sv_ref, 16)
    sh_ref = next_uuid(u); u = int(sh_ref, 16)
    pl_ref = next_uuid(u); u = int(pl_ref, 16)
    sb_ref = next_uuid(u); u = int(sb_ref, 16)
    en_ref = next_uuid(u); u = int(en_ref, 16)

    # Build file UUIDs
    sv_build = next_uuid(u); u = int(sv_build, 16)
    sh_build = next_uuid(u); u = int(sh_build, 16)
    appex_build = next_uuid(u)

    print(f"    Target: {target}")
    print(f"    Appex: {appex_ref}")

    # Build all the sections
    print("\n[3] Building sections...")

    # 1. PBXContainerItemProxy
    proxy_sec = f"""
		{proxy} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = FC629FEF3008FAC600087936 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {target};
			remoteInfo = ShareExtension;
		}};
"""

    # 2. PBXFileReference entries
    file_refs = f"""
		{appex_ref} /* ShareExtension.appex */ = {{isa = PBXFileReference; explicitFileType = wrapper.app-extension; includeInIndex = 0; path = ShareExtension.appex; sourceTree = BUILT_PRODUCTS_DIR;}};
		{sv_ref} /* ShareViewController.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = ShareViewController.swift; path = ShareExtension/ShareViewController.swift; sourceTree = "<group>";}};
		{sh_ref} /* ShareHelper.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = ShareHelper.swift; path = ShareExtension/ShareHelper.swift; sourceTree = "<group>";}};
		{pl_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = Info.plist; path = ShareExtension/Info.plist; sourceTree = "<group>";}};
		{sb_ref} /* MainInterface.storyboard */ = {{isa = PBXFileReference; lastKnownFileType = file.storyboard; name = MainInterface.storyboard; path = ShareExtension/MainInterface.storyboard; sourceTree = "<group>";}};
		{en_ref} /* ShareExtension.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; name = ShareExtension.entitlements; path = ShareExtension/ShareExtension.entitlements; sourceTree = "<group>";}};
"""

    # 3. PBXBuildFile entries
    build_files = f"""
		{sv_build} /* ShareViewController.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {sv_ref} /* ShareViewController.swift */;}};
		{sh_build} /* ShareHelper.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {sh_ref} /* ShareHelper.swift */;}};
		{appex_build} /* ShareExtension.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {appex_ref} /* ShareExtension.appex */;}};
"""

    # 4. XCConfigurationList
    config_list_sec = f"""
		{config_list} /* Build configuration list for PBXNativeTarget "ShareExtension" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{debug_cfg} /* Debug */,
				{release_cfg} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{debug_cfg} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_ENTITLEMENTS = ShareExtension/ShareExtension.entitlements;
				INFOPLIST_FILE = ShareExtension/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@executable_path/../../Frameworks",
				);
				SKIP_INSTALL = YES;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{release_cfg} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_ENTITLEMENTS = ShareExtension/ShareExtension.entitlements;
				INFOPLIST_FILE = ShareExtension/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@executable_path/../../Frameworks",
				);
				SKIP_INSTALL = YES;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
"""

    # 5. PBXSourcesBuildPhase
    src_phase_sec = f"""
		{src_phase} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{sv_build} /* ShareViewController.swift in Sources */,
				{sh_build} /* ShareHelper.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
"""

    # 6. PBXResourcesBuildPhase
    res_phase_sec = f"""
		{res_phase} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
"""

    # 7. PBXCopyFilesBuildPhase
    embed_sec = f"""
		{embed_phase} /* Embed App Extensions */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			destinationPath = "";
			destinationSubfolderSpec = appex;
			files = (
				{appex_build} /* ShareExtension.appex in Embed App Extensions */,
			);
			name = "Embed App Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		}};
"""

    # 8. PBXTargetDependency
    target_dep_sec = f"""
		{target_dep} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			name = ShareExtension;
			target = {target} /* ShareExtension */;
			targetProxy = {proxy} /* PBXContainerItemProxy */;
		}};
"""

    # 9. PBXNativeTarget
    native_target_sec = f"""
		{target} /* ShareExtension */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {config_list} /* Build configuration list for PBXNativeTarget "ShareExtension" */;
			buildPhases = (
				{src_phase} /* Sources */,
				{res_phase} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				{target_dep} /* PBXTargetDependency */,
			);
			name = ShareExtension;
			productName = ShareExtension;
			productReference = {appex_ref} /* ShareExtension.appex */;
			productType = "com.apple.product-type.app-extension";
		}};
"""

    # Modify content - insert at section endings
    print("\n[4] Inserting sections...")
    modified = content

    # Insert in order of appearance in the file
    insertions = [
        ('/* End PBXContainerItemProxy section */', proxy_sec),
        ('/* End PBXFileReference section */', file_refs),
        ('/* End PBXBuildFile section */', build_files),
        ('/* End XCConfigurationList section */', config_list_sec),
        ('/* End PBXSourcesBuildPhase section */', src_phase_sec),
        ('/* End PBXResourcesBuildPhase section */', res_phase_sec),
        ('/* End PBXCopyFilesBuildPhase section */', embed_sec),
        ('/* End PBXTargetDependency section */', target_dep_sec),
        ('/* End PBXNativeTarget section */', native_target_sec),
    ]

    for marker, insertion in insertions:
        if marker in modified:
            modified = modified.replace(marker, insertion + marker)
            print(f"    ✓ Inserted before {marker}")
        else:
            print(f"    ! Warning: {marker} not found")

    # Add to targets list
    print("\n[5] Updating targets list...")
    targets_pattern = r'(targets = \(\n\s+FC629FF63008FAC600087936 /\* AirBridge \*/,)'
    targets_replacement = r'\1\n\t\t\t' + target + ' /* ShareExtension */,'
    modified = re.sub(targets_pattern, targets_replacement, modified)
    print("    ✓ Added to targets list")

    # Add embed phase to AirBridge build phases
    print("\n[6] Adding embed phase to AirBridge...")
    bp_pattern = r'(FC629FF53008FAC600087936 /\* Resources \*/,)'
    bp_replacement = r'\1\n\t\t\t\t' + embed_phase + ' /* Embed App Extensions */,'
    modified = re.sub(bp_pattern, bp_replacement, modified)
    print("    ✓ Added embed phase")

    # Add dependency to AirBridge
    print("\n[7] Adding dependency to AirBridge...")
    dep_pattern = r'(dependencies = \(\n\s+)();'
    dep_replacement = r'\1' + target_dep + ' /* ShareExtension */,\n\t\t\t\2'
    modified = re.sub(dep_pattern, dep_replacement, modified)
    print("    ✓ Added dependency")

    # Backup and write
    print("\n[8] Writing project.pbxproj...")
    backup = f'{PROJECT_PBX}.backup.{datetime.now().strftime("%Y%m%d_%H%M%S")}'
    shutil.copy2(PROJECT_PBX, backup)
    print(f"    ✓ Backup: {os.path.basename(backup)}")

    write_file(PROJECT_PBX, modified)
    print("    ✓ project.pbxproj modified")

    # Create scheme
    print("\n[9] Creating scheme...")
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2650"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "ShareExtension.appex"
               BlueprintName = "ShareExtension"
               ReferencedContainer = "container:AirBridge.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "ShareExtension.appex"
            BlueprintName = "ShareExtension"
            ReferencedContainer = "container:AirBridge.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "ShareExtension.appex"
            BlueprintName = "ShareExtension"
            ReferencedContainer = "container:AirBridge.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    scheme_path = os.path.join(SCHEME_DIR, 'ShareExtension.xcscheme')
    write_file(scheme_path, scheme)
    print(f"    ✓ Scheme created")

    print("\n" + "=" * 60)
    print("SUCCESS!")
    print("=" * 60)
    print("""
Next steps:
1. Open in Xcode: open AirBridge.xcodeproj
2. Configure signing for ShareExtension target
3. Add App Groups: group.com.airbridge.shared
4. Build and test
""")
    return True

if __name__ == '__main__':
    success = main()
    exit(0 if success else 1)
