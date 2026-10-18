#!/usr/bin/env python3
"""Source inventory gates for private-profile resource origins; not runtime acceptance."""
from pathlib import Path
import re, json
root=Path(__file__).resolve().parents[1]/'Straight Up Browser'
files={p.name:p.read_text() for p in root.glob('*.swift')}
errors=[]
def require(condition, message):
    if not condition: errors.append(message)
count=0
for name,text in files.items():
    # Match actual declarations, excluding comment-only mentions. Capture balanced
    # attribute parentheses, including dynamic keys and existing explicit stores.
    for match in re.finditer(r'^\s*@AppStorage\(',text,re.M):
        start=match.end();i=start;depth=1;quoted=False;escape=False
        while i<len(text) and depth:
            c=text[i]
            if quoted:
                if escape: escape=False
                elif c=='\\': escape=True
                elif c=='"': quoted=False
            elif c=='"': quoted=True
            elif c=='(': depth+=1
            elif c==')': depth-=1
            i+=1
        attribute=text[start:i-1]
        require('store: BrowserProfile.defaults' in attribute,f'{name}: unscoped @AppStorage')
        count+=1
    if name!='BrowserTestProfile.swift':
        require('UserDefaults.standard' not in text, f'{name}: direct standard defaults origin')
        require(not re.search(r'\bUserDefaults\s*=\s*\.standard\b',text),f'{name}: implicit standard default')
    if name!='BrowserProfileSystem.swift':
        require('NSPasteboard.general' not in text,f'{name}: system clipboard origin')
        require(not re.search(r'NSWorkspace.shared\.(open|activateFileViewerSelecting)\(',text),f'{name}: external app effect')
    if name!='BrowserProfileNetwork.swift':
        require('URLSession.shared' not in text,f'{name}: unscoped native session')
require(count==286, f'AppStorage declaration inventory changed: {count}; review the new boundary')
# Every low-level Keychain function must be behind a profile-aware entry check.
keychain_calls=0
for name in ['SavedCredentialStore.swift','BrowserAgent.swift','BrowserWeatherService.swift','BrowserAgentMCPIntegration.swift']:
    text=files[name]
    funcs=list(re.finditer(r'\bfunc\s+\w+\s*\(',text))
    for call in re.finditer(r'\bSecItem(?:CopyMatching|Add|Update|Delete)\(',text):
        keychain_calls+=1
        owner=max((f.start() for f in funcs if f.start()<call.start()),default=0)
        prefix=text[owner:call.start()]
        require('BrowserProfile.isIsolated' in prefix or 'guard permitsAccess(' in prefix,
                f'{name}: Keychain call without early profile boundary')
# Resource constructors which otherwise access fixed production namespaces.
for name, needles in {
 'Straight_Up_BrowserApp.swift':['updaterController = BrowserProfile.isIsolated ? nil :','if !BrowserProfile.isIsolated { _ = BrowserCLI.shared }','if !BrowserProfile.isIsolated { installURLHandler() }'],
 'DocumentStore.swift':['BrowserProfile.paths?.documents ?? containerOverride'],
 'TabSync.swift':['BrowserProfile.isIsolated ? .none','guard !BrowserProfile.isIsolated else { return false }'],
 'ShareIngest.swift':['container: URL? = BrowserProfile.isIsolated ? nil : ShareQueue.containerURL()'],
 'BrowserProfileWebKit.swift':['WKWebsiteDataStore.nonPersistent()','configuration.defaultWebpagePreferences.allowsContentJavaScript = false','try BrowserProfile.writeReadyManifest()'],
 'ToneSchedule.swift':['static func focusIsOn() -> Bool {\n        guard !BrowserProfile.isIsolated', 'static var focusAuthorization: INFocusStatusAuthorizationStatus {\n        guard !BrowserProfile.isIsolated'],
 'GlobalOmnibar.swift':['guard !BrowserProfile.isIsolated else { return false }'],
 'Prefetcher.swift':['if BrowserProfile.isIsolated { webView = nil; super.init(); return }'],
 'BrowserAgent.swift':['errorMessage = initialError\n        guard !BrowserProfile.isIsolated else { return }'],
}.items():
    for needle in needles: require(needle in files[name],f'{name}: missing resource constructor guard: {needle}')
for name,text in files.items():
    if name.startswith('BrowserProfile') or name=='BrowserTestProfile.swift': continue
    for call in re.finditer(r'let panel = NS(?:Open|Save)Panel\(\)',text):
        require('guard !BrowserProfile.isIsolated' in text[max(0,call.start()-700):call.start()], f'{name}: unguarded system file panel')
require(not errors,'Boundary audit failed')
if errors: raise SystemExit('\n'.join(errors))
print(json.dumps({'status':'passed','appStorageDeclarations':count,'keychainCalls':keychain_calls,'swiftFiles':len(files),'scope':'source guards only; native profile runtime acceptance remains separate'},indent=2))
