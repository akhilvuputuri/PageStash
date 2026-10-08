#!/usr/bin/env python3
"""Generate the small Xcode project without requiring a third-party generator."""
import hashlib
from pathlib import Path
root = Path(__file__).resolve().parents[1]
ios = root / 'ios'
project = ios / 'OfflineReader.xcodeproj'
project.mkdir(exist_ok=True)
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def q(value): return '"' + str(value).replace('\\','\\\\').replace('"','\\"') + '"'
objects = []
def obj(name, body):
    identifier = uid(name)
    objects.append(f'{identifier} = {{ {body} }};')
    return identifier
sources = sorted((ios / 'OfflineReader').glob('*.swift'))
refs, builds = [], []
for source in sources:
    ref = obj('ref:'+source.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q("OfflineReader/"+source.name)}; sourceTree = "<group>";')
    refs.append(ref)
    builds.append(obj('build:'+source.name, f'isa = PBXBuildFile; fileRef = {ref};'))
asset = obj('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = OfflineReader/Assets.xcassets; sourceTree = "<group>";')
assetBuild = obj('asset-build', f'isa = PBXBuildFile; fileRef = {asset};')
privacy = obj('privacy', 'isa = PBXFileReference; lastKnownFileType = text.xml; path = OfflineReader/PrivacyInfo.xcprivacy; sourceTree = "<group>";')
privacyBuild = obj('privacy-build', f'isa = PBXBuildFile; fileRef = {privacy};')
product = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OfflineReader.app; sourceTree = BUILT_PRODUCTS_DIR;')
testProduct = obj('test-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = OfflineReaderTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
testRefs, testBuilds = [], []
for source in sorted((ios/'OfflineReaderTests').glob('*.swift')):
    ref = obj('test-ref:'+source.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q('OfflineReaderTests/'+source.name)}; sourceTree = "<group>";')
    testRefs.append(ref);testBuilds.append(obj('test-build:'+source.name,f'isa = PBXBuildFile; fileRef = {ref};'))
products = obj('products', f'isa = PBXGroup; children = ({product},{testProduct}); name = Products; sourceTree = "<group>";')
group = obj('group', f'isa = PBXGroup; children = ({",".join(refs+testRefs+[asset,privacy,products])}); sourceTree = "<group>";')
package = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = ReaderCore;')
dependency = obj('package-product', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = ReaderCore;')
link = obj('link', f'isa = PBXBuildFile; productRef = {dependency};')
sourcePhase = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)}); runOnlyForDeploymentPostprocessing = 0;')
frameworkPhase = obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({link}); runOnlyForDeploymentPostprocessing = 0;')
resourcePhase = obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({assetBuild},{privacyBuild}); runOnlyForDeploymentPostprocessing = 0;')
def config(name, app):
    debug = name == 'Debug'
    settings = {'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if debug else '-O', 'ONLY_ACTIVE_ARCH':'YES' if debug else 'NO'}
    if app:
        settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'com.akhilvuputuri.offlinereader','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'OfflineReader/Info-Debug.plist' if debug else 'OfflineReader/Info.plist','GENERATE_INFOPLIST_FILE':'NO','CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'0.1.0','TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'U44PG44XMJ','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if debug else '', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES','ENABLE_TESTABILITY':'YES' if debug else 'NO'})
    return obj(('app' if app else 'project')+name, f'isa = XCBuildConfiguration; buildSettings = {{'+''.join(f'{key} = {q(value)};' for key,value in settings.items())+f'}}; name = {name};')
appConfigs = [config(name,True) for name in ['Debug','Release']]
projConfigs = [config(name,False) for name in ['Debug','Release']]
appList = obj('app-list', f'isa = XCConfigurationList; buildConfigurations = ({",".join(appConfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
projList = obj('project-list', f'isa = XCConfigurationList; buildConfigurations = ({",".join(projConfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {appList}; buildPhases = ({sourcePhase},{frameworkPhase},{resourcePhase}); buildRules = (); dependencies = (); name = OfflineReader; packageProductDependencies = ({dependency}); productName = OfflineReader; productReference = {product}; productType = "com.apple.product-type.application";')
testConfigs=[]
for name in ['Debug','Release']:
    settings={'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','PRODUCT_BUNDLE_IDENTIFIER':'com.akhilvuputuri.offlinereader.tests','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/OfflineReader.app/OfflineReader','BUNDLE_LOADER':'$(TEST_HOST)','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if name=='Debug' else '', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O'}
    testConfigs.append(obj('test-config:'+name,'isa = XCBuildConfiguration; buildSettings = {'+''.join(f'{k} = {q(v)};' for k,v in settings.items())+f'}}; name = {name};'))
testList=obj('test-list',f'isa = XCConfigurationList; buildConfigurations = ({','.join(testConfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
testSource=obj('test-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(testBuilds)}); runOnlyForDeploymentPostprocessing = 0;')
testLink=obj('test-link',f'isa = PBXBuildFile; productRef = {dependency};')
testFramework=obj('test-frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({testLink}); runOnlyForDeploymentPostprocessing = 0;')
proxy=obj('test-proxy',f'isa = PBXContainerItemProxy; containerPortal = {uid('project')}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = OfflineReader;')
targetDependency=obj('test-dependency',f'isa = PBXTargetDependency; target = {target}; targetProxy = {proxy};')
testTarget=obj('test-target',f'isa = PBXNativeTarget; buildConfigurationList = {testList}; buildPhases = ({testSource},{testFramework}); buildRules = (); dependencies = ({targetDependency}); name = OfflineReaderTests; packageProductDependencies = ({dependency}); productName = OfflineReaderTests; productReference = {testProduct}; productType = "com.apple.product-type.bundle.unit-test";')
projectID = obj('project', f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2630; TargetAttributes = {{{target} = {{CreatedOnToolsVersion = 26.3;}};}};}}; buildConfigurationList = {projList}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {group}; packageReferences = ({package}); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},{testTarget});')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {projectID};}}\n')
schemeDir=project/'xcshareddata/xcschemes'
schemeDir.mkdir(parents=True,exist_ok=True)
# Preserve Xcode's native scheme layout so opening the project creates no format-only diff.
template = Path(__file__).with_name('OfflineReader.xcscheme.template').read_text()
(schemeDir/'OfflineReader.xcscheme').write_text(template.format(target=target,tests=testTarget))
print(project)
