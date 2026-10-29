#!/usr/bin/env python3
"""Generate the small Xcode project without requiring a third-party generator."""
import hashlib
from pathlib import Path
root = Path(__file__).resolve().parents[1]
# The app and every embedded extension must share these.
MARKETING_VERSION, BUILD = '0.5.1', '14'
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
sharedRefs, sharedBuilds, extensionRefs, extensionBuilds = [], [], [], []
for source in sorted((ios/'ShareSupport').glob('*.swift')):
    ref = obj('shared-ref:'+source.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q("ShareSupport/"+source.name)}; sourceTree = "<group>";')
    sharedRefs.append(ref)
    sharedBuilds.append(obj('shared-build:'+source.name,f'isa = PBXBuildFile; fileRef = {ref};'))
    extensionBuilds.append(obj('extension-shared-build:'+source.name,f'isa = PBXBuildFile; fileRef = {ref};'))
for source in sorted((ios/'ReaderShare').glob('*.swift')):
    ref = obj('extension-ref:'+source.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q("ReaderShare/"+source.name)}; sourceTree = "<group>";')
    extensionRefs.append(ref); extensionBuilds.append(obj('extension-build:'+source.name,f'isa = PBXBuildFile; fileRef = {ref};'))
widgetRefs, widgetBuilds = [], []
for source in sorted((ios/'WidgetSupport').glob('*.swift')):
    ref = obj('widget-support-ref:'+source.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q("WidgetSupport/"+source.name)}; sourceTree = "<group>";')
    widgetRefs.append(ref)
    sharedBuilds.append(obj('app-widget-support-build:'+source.name,f'isa = PBXBuildFile; fileRef = {ref};'))
    widgetBuilds.append(obj('widget-support-build:'+source.name,f'isa = PBXBuildFile; fileRef = {ref};'))
for source in sorted((ios/'ReaderWidget').glob('*.swift')):
    ref = obj('widget-ref:'+source.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q("ReaderWidget/"+source.name)}; sourceTree = "<group>";')
    widgetRefs.append(ref); widgetBuilds.append(obj('widget-build:'+source.name,f'isa = PBXBuildFile; fileRef = {ref};'))
widgetProduct = obj('widget-product','isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = ReaderWidget.appex; sourceTree = BUILT_PRODUCTS_DIR;')
# The HTTP/session model is extension-safe and uses the same save contract.
extensionBuilds.append(obj('extension-api',f'isa = PBXBuildFile; fileRef = {uid("ref:API.swift")};'))
extensionProduct = obj('extension-product','isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = ReaderShare.appex; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; children = ({product},{testProduct},{extensionProduct},{widgetProduct}); name = Products; sourceTree = "<group>";')
group = obj('group', f'isa = PBXGroup; children = ({",".join(refs+testRefs+sharedRefs+extensionRefs+widgetRefs+[asset,privacy,products])}); sourceTree = "<group>";')
package = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = ReaderCore;')
dependency = obj('package-product', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = ReaderCore;')
link = obj('link', f'isa = PBXBuildFile; productRef = {dependency};')
sourcePhase = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds+sharedBuilds)}); runOnlyForDeploymentPostprocessing = 0;')
frameworkPhase = obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({link}); runOnlyForDeploymentPostprocessing = 0;')
resourcePhase = obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({assetBuild},{privacyBuild}); runOnlyForDeploymentPostprocessing = 0;')
extensionConfigs=[]
for name in ['Debug','Release']:
    settings={'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES',
      'PRODUCT_BUNDLE_IDENTIFIER':'$(READER_BUNDLE_IDENTIFIER).share','PRODUCT_NAME':'$(TARGET_NAME)',
      'INFOPLIST_FILE':'ReaderShare/Info.plist','GENERATE_INFOPLIST_FILE':'NO','CURRENT_PROJECT_VERSION':BUILD,'MARKETING_VERSION':MARKETING_VERSION,
      'TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'U44PG44XMJ','CODE_SIGN_ENTITLEMENTS':'ReaderShare/ReaderShare.entitlements',
      'APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if name=='Debug' else '',
      'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'}
    extensionConfigs.append(obj('extension-config:'+name,'isa = XCBuildConfiguration; buildSettings = {'+''.join(f'{k} = {q(v)};' for k,v in settings.items())+f'}}; name = {name};'))
extensionList=obj('extension-list',f'isa = XCConfigurationList; buildConfigurations = ({",".join(extensionConfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
extensionSource=obj('extension-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(extensionBuilds)}); runOnlyForDeploymentPostprocessing = 0;')
extensionLink=obj('extension-link',f'isa = PBXBuildFile; productRef = {dependency};')
extensionFramework=obj('extension-frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({extensionLink}); runOnlyForDeploymentPostprocessing = 0;')
extensionPrivacy=obj('extension-privacy-build',f'isa = PBXBuildFile; fileRef = {privacy};')
extensionResources=obj('extension-resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({extensionPrivacy}); runOnlyForDeploymentPostprocessing = 0;')
extensionTarget=obj('extension-target',f'isa = PBXNativeTarget; buildConfigurationList = {extensionList}; buildPhases = ({extensionSource},{extensionFramework},{extensionResources}); buildRules = (); dependencies = (); name = ReaderShare; packageProductDependencies = ({dependency}); productName = ReaderShare; productReference = {extensionProduct}; productType = "com.apple.product-type.app-extension";')
widgetConfigs=[]
for name in ['Debug','Release']:
    settings={'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES',
      'PRODUCT_BUNDLE_IDENTIFIER':'$(READER_BUNDLE_IDENTIFIER).widget','PRODUCT_NAME':'$(TARGET_NAME)',
      'INFOPLIST_FILE':'ReaderWidget/Info.plist','GENERATE_INFOPLIST_FILE':'NO','CURRENT_PROJECT_VERSION':BUILD,'MARKETING_VERSION':MARKETING_VERSION,
      'TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'U44PG44XMJ','CODE_SIGN_ENTITLEMENTS':'ReaderWidget/ReaderWidget.entitlements',
      'APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if name=='Debug' else '',
      'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'}
    widgetConfigs.append(obj('widget-config:'+name,'isa = XCBuildConfiguration; buildSettings = {'+''.join(f'{k} = {q(v)};' for k,v in settings.items())+f'}}; name = {name};'))
widgetList=obj('widget-list',f'isa = XCConfigurationList; buildConfigurations = ({",".join(widgetConfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
widgetSource=obj('widget-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(widgetBuilds)}); runOnlyForDeploymentPostprocessing = 0;')
widgetFramework=obj('widget-frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
widgetPrivacy=obj('widget-privacy-build',f'isa = PBXBuildFile; fileRef = {privacy};')
widgetResources=obj('widget-resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({widgetPrivacy}); runOnlyForDeploymentPostprocessing = 0;')
widgetTarget=obj('widget-target',f'isa = PBXNativeTarget; buildConfigurationList = {widgetList}; buildPhases = ({widgetSource},{widgetFramework},{widgetResources}); buildRules = (); dependencies = (); name = ReaderWidget; productName = ReaderWidget; productReference = {widgetProduct}; productType = "com.apple.product-type.app-extension";')
widgetEmbed=obj('widget-embed',f'isa = PBXBuildFile; fileRef = {widgetProduct}; settings = {{ATTRIBUTES = (CodeSignOnCopy,RemoveHeadersOnCopy);}};')
widgetProxy=obj('widget-proxy',f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {widgetTarget}; remoteInfo = ReaderWidget;')
widgetTargetDependency=obj('widget-target-dependency',f'isa = PBXTargetDependency; target = {widgetTarget}; targetProxy = {widgetProxy};')
extensionEmbed=obj('extension-embed',f'isa = PBXBuildFile; fileRef = {extensionProduct}; settings = {{ATTRIBUTES = (CodeSignOnCopy,RemoveHeadersOnCopy);}};')
embedPhase=obj('embed-extensions',f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({extensionEmbed},{widgetEmbed}); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
extensionProxy=obj('extension-proxy',f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {extensionTarget}; remoteInfo = ReaderShare;')
extensionTargetDependency=obj('extension-target-dependency',f'isa = PBXTargetDependency; target = {extensionTarget}; targetProxy = {extensionProxy};')
def config(name, app):
    debug = name == 'Debug'
    settings = {'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if debug else '-O', 'ONLY_ACTIVE_ARCH':'YES' if debug else 'NO','READER_BUNDLE_IDENTIFIER':'com.akhilvuputuri.offlinereader','READER_APP_GROUP':'group.$(READER_BUNDLE_IDENTIFIER)'}
    if app:
        settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'$(READER_BUNDLE_IDENTIFIER)','CODE_SIGN_ENTITLEMENTS':'OfflineReader/OfflineReader.entitlements','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'OfflineReader/Info-Debug.plist' if debug else 'OfflineReader/Info.plist','GENERATE_INFOPLIST_FILE':'NO','CURRENT_PROJECT_VERSION':BUILD,'MARKETING_VERSION':MARKETING_VERSION,'TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'U44PG44XMJ','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if debug else '', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES','ENABLE_TESTABILITY':'YES' if debug else 'NO'})
    return obj(('app' if app else 'project')+name, f'isa = XCBuildConfiguration; buildSettings = {{'+''.join(f'{key} = {q(value)};' for key,value in settings.items())+f'}}; name = {name};')
appConfigs = [config(name,True) for name in ['Debug','Release']]
projConfigs = [config(name,False) for name in ['Debug','Release']]
appList = obj('app-list', f'isa = XCConfigurationList; buildConfigurations = ({",".join(appConfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
projList = obj('project-list', f'isa = XCConfigurationList; buildConfigurations = ({",".join(projConfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {appList}; buildPhases = ({sourcePhase},{frameworkPhase},{resourcePhase},{embedPhase}); buildRules = (); dependencies = ({extensionTargetDependency},{widgetTargetDependency}); name = OfflineReader; packageProductDependencies = ({dependency}); productName = OfflineReader; productReference = {product}; productType = "com.apple.product-type.application";')
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
projectID = obj('project', f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2630; TargetAttributes = {{{target} = {{CreatedOnToolsVersion = 26.3;}};}};}}; buildConfigurationList = {projList}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {group}; packageReferences = ({package}); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},{testTarget},{extensionTarget},{widgetTarget});')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {projectID};}}\n')
schemeDir=project/'xcshareddata/xcschemes'
schemeDir.mkdir(parents=True,exist_ok=True)
# Preserve Xcode's native scheme layout so opening the project creates no format-only diff.
template = Path(__file__).with_name('OfflineReader.xcscheme.template').read_text()
(schemeDir/'OfflineReader.xcscheme').write_text(template.format(target=target,tests=testTarget))
print(project)
