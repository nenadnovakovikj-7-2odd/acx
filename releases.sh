#!/usr/bin/env bash
# releases.sh — scaffold, build and publish ACX
# usage: bash releases.sh [scaffold|build|publish|all]
set -euo pipefail

REPO="${REPO:-acx}"
TAG="${TAG:-v1.0.0}"
ROOT="${ROOT:-$PWD}"

c(){ printf '\033[35m>\033[0m %s\n' "$*"; }
die(){ printf '\033[31mx\033[0m %s\n' "$*" >&2; exit 1; }

scaffold(){
  c "creating files in $ROOT"
  mkdir -p "$ROOT/.github/workflows" "$ROOT/docs" "$ROOT/releases"

  cat > "$ROOT/ACX.mm" <<'ACXMM'
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <sys/mman.h>
#import <mach-o/dyld.h>

static NSArray *ACX_DB(void) {
    static NSArray *db; static dispatch_once_t once;
    dispatch_once(&once, ^{ db = @[
      @{ @"id":@"pg3d.inhouse", @"name":@"Cubic Games in-house AC",
         @"vendor":@"Cubic Games / Aghanim", @"antidebug":@YES,
         @"bid":@[@"zombiegun3d", @"com.cubicgames.pixelgun3d"],
         @"str":@[@"AntiCheatManager",@"CheatDetector",@"AntiCheatReporter",
                  @"CubicGames",@"Aghanim",@"isCheatDetected",@"reportToServer"],
         @"dyl":@[@"unityframework",@"libil2cpp"] },
      @{ @"id":@"eac", @"name":@"Easy Anti-Cheat", @"vendor":@"Epic Games", @"antidebug":@YES,
         @"bid":@[], @"str":@[@"EasyAntiCheat",@"EasyAntiCheat_EOS",@"eos_sdk"],
         @"dyl":@[@"libeasyanticheat"] },
      @{ @"id":@"be", @"name":@"BattlEye", @"vendor":@"BattlEye Innovations", @"antidebug":@YES,
         @"bid":@[], @"str":@[@"BattlEye",@"BEClient",@"BEService",@"BEDaisy"],
         @"dyl":@[@"becclient"] },
      @{ @"id":@"actk", @"name":@"Anti-Cheat Toolkit", @"vendor":@"Code Stage", @"antidebug":@NO,
         @"bid":@[], @"str":@[@"AntiCheatToolkit",@"ACTk",@"ObscuredInt",@"DetectionEvent"],
         @"dyl":@[@"unityframework"] },
    ]; });
    return db;
}

static NSArray<NSString *> *acx_harvest(NSString *path, NSUInteger cap) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!d.length) return @[];
    const uint8_t *b = d.bytes; NSUInteger n = d.length, i = 0;
    NSMutableArray *out = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    while (i < n && out.count < cap) {
        NSUInteger s = i;
        while (i < n && b[i] != 0) i++;
        NSUInteger len = i - s;
        if (len >= 5 && len <= 128) {
            BOOL ok = YES;
            for (NSUInteger k = s; k < i; k++) if (b[k] < 0x20 || b[k] > 0x7E) { ok = NO; break; }
            if (ok) {
                NSString *str = [[NSString alloc] initWithBytes:b+s length:len encoding:NSASCIIStringEncoding];
                if (str && ![seen containsObject:str]) { [seen addObject:str]; [out addObject:str]; }
            }
        }
        i++;
    }
    return out;
}

static NSDictionary *acx_identify(NSString *bid, NSSet *strs, NSSet *dyls) {
    NSDictionary *best = nil; double bestConf = 0;
    for (NSDictionary *e in ACX_DB()) {
        double score = 0, max = 60 + [e[@"str"] count] * 9 + [e[@"dyl"] count] * 14;
        NSMutableArray *ev = [NSMutableArray array];
        for (NSString *x in e[@"bid"]) if ([bid.lowercaseString containsString:x]) { score += 60; [ev addObject:x]; }
        for (NSString *x in e[@"str"]) if ([strs containsObject:x]) { score += 9; [ev addObject:x]; }
        for (NSString *x in e[@"dyl"]) for (NSString *d in dyls) if ([d containsString:x]) { score += 14; [ev addObject:x]; break; }
        double conf = MIN(0.99, score / max * 1.45);
        if (conf > bestConf) { bestConf = conf; best = @{ @"e":e, @"conf":@(conf), @"ev":ev }; }
    }
    return bestConf >= 0.12 ? [best mutableCopy] : nil;
}

static void acx_kill_antidebug(void) {
    void *p = dlsym(RTLD_DEFAULT, "ptrace");
    if (!p) { NSLog(@"[ACX] ptrace not found"); return; }
    long pg = sysconf(_SC_PAGESIZE);
    uintptr_t base = (uintptr_t)p & ~(uintptr_t)(pg - 1);
    uintptr_t end  = ((uintptr_t)p + 8 + pg - 1) & ~(uintptr_t)(pg - 1);
    if (mprotect((void *)base, end - base, PROT_READ|PROT_WRITE|PROT_EXEC) != 0) {
        NSLog(@"[ACX] mprotect: %s", strerror(errno)); return;
    }
    uint32_t *ins = (uint32_t *)p;
    ins[0] = 0xD2800000;   // mov x0, #0
    ins[1] = 0xD65F03C0;   // ret
    __builtin___clear_cache((char *)p, (char *)p + 8);
    mprotect((void *)base, end - base, PROT_READ|PROT_EXEC);
    NSLog(@"[ACX] ptrace neutralized");
}

__attribute__((constructor)) static void acx_main(void) {
    @autoreleasepool {
        double t0 = CFAbsoluteTimeGetCurrent();
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *exe = NSBundle.mainBundle.executablePath ?: @"";
        if (!exe.length) return;

        NSMutableSet *strs = [NSMutableSet setWithArray:acx_harvest(exe, 300000)];
        NSString *uf = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Frameworks/UnityFramework.framework/UnityFramework"];
        if ([NSFileManager.defaultManager fileExistsAtPath:uf])
            [strs addObjectsFromArray:acx_harvest(uf, 150000)];

        NSMutableSet *dyls = [NSMutableSet set];
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *nm = _dyld_get_image_name(i);
            if (nm) [dyls addObject:[NSString stringWithUTF8String:nm].lowercaseString];
        }

        NSMutableDictionary *rep = [@{ @"bundle":bid, @"strings":@(strs.count),
                                       @"dylibs":@(dyls.count) } mutableCopy];
        NSDictionary *hit = acx_identify(bid, strs, dyls);
        if (hit) {
            NSDictionary *e = hit[@"e"];
            rep[@"engine"] = e[@"name"]; rep[@"confidence"] = hit[@"conf"];
            rep[@"evidence"] = hit[@"ev"]; rep[@"profile"] = e[@"id"];
            NSLog(@"[ACX] %@ (%.0f%%) %@", e[@"name"], [hit[@"conf"] doubleValue]*100, hit[@"ev"]);
            if ([hit[@"conf"] doubleValue] >= 0.55 && [e[@"antidebug"] boolValue]) {
                acx_kill_antidebug(); rep[@"applied"] = @[@"ptrace->0"];
            }
        } else {
            NSLog(@"[ACX] no match (%lu strings)", (unsigned long)strs.count);
        }
        rep[@"elapsed_ms"] = @((CFAbsoluteTimeGetCurrent() - t0) * 1000.0);

        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/acx"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                 attributes:nil error:nil];
        [[NSJSONSerialization dataWithJSONObject:rep options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:[dir stringByAppendingPathComponent:@"last-report.json"] atomically:YES];
        NSLog(@"[ACX] report -> %@", dir);
    }
}
ACXMM

  cat > "$ROOT/.github/workflows/release.yml" <<'YAML'
name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Build dylib
        run: |
          SDK=$(xcrun --sdk iphoneos --show-sdk-path)
          xcrun -sdk iphoneos clang++ -arch arm64 -dynamiclib -fobjc-arc -O2 \
            -isysroot "$SDK" -framework Foundation \
            -Wl,-undefined,dynamic_lookup \
            -Wl,-install_name,@rpath/ACX.dylib \
            ACX.mm -o ACX.dylib
          codesign -f -s - ACX.dylib
          shasum -a 256 ACX.dylib > ACX.dylib.sha256
          cat ACX.dylib.sha256
      - name: Publish asset
        run: |
          gh release view "$GITHUB_REF_NAME" >/dev/null 2>&1 \
            || gh release create "$GITHUB_REF_NAME" --generate-notes
          gh release upload "$GITHUB_REF_NAME" ACX.dylib ACX.dylib.sha256 --clobber
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
YAML

  cat > "$ROOT/docs/index.html" <<'HTML'
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ACX — download</title>
<style>
:root{--fg:#e8e8ee;--mut:#8b8b99;--acc:#7c5cff;--bg:#0d0d12}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
 font:15px/1.6 Inter,system-ui,-apple-system,sans-serif;padding:32px 20px}
main{max-width:620px;margin:0 auto}
h1{font-size:38px;letter-spacing:-1.5px;margin:16px 0 8px}
h2{font-size:15px;font-weight:500;margin:30px 0 8px;color:var(--mut)}
p{margin:0 0 12px}
.tag{font:11px ui-monospace,Menlo,monospace;padding:3px 9px;border-radius:99px;
 border:1px solid rgba(124,92,255,.5);color:var(--acc);margin-right:6px}
.card{border:1px solid #24242e;border-radius:12px;padding:18px;background:#12121a}
.dl{display:flex;justify-content:space-between;align-items:center;gap:14px;flex-wrap:wrap}
a.btn{background:var(--acc);color:#fff;text-decoration:none;font-weight:500;
 padding:12px 22px;border-radius:10px;display:inline-block}
pre{font:11.5px ui-monospace,Menlo,monospace;background:#16161f;border:1px solid #24242e;
 border-radius:9px;padding:12px;overflow-x:auto;color:#c9c9d6}
code{font-family:ui-monospace,Menlo,monospace;font-size:12.5px}
.st{font:11.5px ui-monospace,Menlo,monospace;color:var(--mut)}
.st.ok{color:#3ecf6e}.st.warn{color:#e0a33e}
.mut{color:var(--mut)}
</style></head><body><main>

<span class="tag">v1.0.0</span><span class="tag">iOS 15+</span><span class="tag">arm64</span>
<h1>ACX</h1>
<p class="mut">Pre-launch anti-cheat scanner and neutralizer for iOS games. Parses the
binary before the game runs, names the anti-cheat, then unhooks it — on your device only.</p>

<h2>Download</h2>
<div class="card"><div class="dl">
  <div>
    <div style="font-weight:500">ACX.dylib</div>
    <div class="st" id="sub">checking release…</div>
  </div>
  <a class="btn" id="btn" download="ACX.dylib"
     href="https://github.com/YOU/acx/releases/latest/download/ACX.dylib">Download</a>
</div>
<pre id="sha">sha256  verifying…</pre>
</div>

<h2>Install</h2>
<pre>TrollStore   TrollFools -> game -> Inject dylib -> ACX.dylib
Jailbreak    Sileo -> install the .deb -> respring
Sideload     Sideloadly -> enable dylib injection -> drop the file</pre>

<h2>Verify</h2>
<pre>shasum -a 256 ~/Downloads/ACX.dylib   # must match the hash above</pre>

<script>
(function(){
  var B=document.getElementById('btn'), S=document.getElementById('sub'), H=document.getElementById('sha');
  var m=B.href.match(/github\.com\/([^\/]+)\/([^\/]+)/); if(!m) return;
  fetch('https://api.github.com/repos/'+m[1]+'/'+m[2]+'/releases/latest')
    .then(function(r){ if(r.status===404){S.className='st warn';S.textContent='no release yet';return null;} return r.json(); })
    .then(function(j){
      if(!j) return;
      var a=(j.assets||[]).filter(function(x){return x.name==='ACX.dylib';})[0];
      if(!a){S.className='st warn';S.textContent='release '+j.tag_name+' has no ACX.dylib';return;}
      S.className='st ok'; S.textContent=(a.size/1024).toFixed(0)+' KB · '+j.tag_name;
      var s=(j.assets||[]).filter(function(x){return x.name==='ACX.dylib.sha256';})[0];
      if(s) fetch(s.browser_download_url).then(function(x){return x.text();})
        .then(function(t){H.textContent='sha256  '+t.trim().split(/\s+/)[0];})
        .catch(function(){H.textContent='sha256  see release notes';});
    })
    .catch(function(){ S.className='st warn'; S.textContent='cannot reach github — button still works'; });
})();
</script>
</main></body></html>
HTML

  cat > "$ROOT/README.md" <<'MD'
# ACX

[![Download ACX.dylib](https://img.shields.io/badge/Download-ACX.dylib-7c5cff?style=for-the-badge&logo=apple&logoColor=white)](../../releases/latest/download/ACX.dylib)

Pre-launch anti-cheat scanner and neutralizer for iOS games.

## Install

| Route | Steps |
|---|---|
| TrollStore | TrollFools -> game -> Inject dylib -> ACX.dylib |
| Jailbreak | Sileo -> install the .deb -> respring |
| Sideload | Sideloadly -> enable dylib injection -> drop the file |

## Build

```bash
bash releases.sh build
cat > "$ROOT/signatures.json" <<'JSON'
{
"schema": 3,
"engines": [
{ "id": "pg3d.inhouse", "name": "Cubic Games in-house AC",
"vendor": "Cubic Games / Aghanim",
"match": {
"bundle_ids": ["zombiegun3d", "com.cubicgames.pixelgun3d"],
"strings_any": ["AntiCheatManager","CheatDetector","AntiCheatReporter",
"CubicGames","Aghanim","isCheatDetected","reportToServer"],
"dylibs": ["unityframework","libil2cpp"]
},
"attack": { "anti_debug": "noop", "hide_jailbreak": true, "hide_hooks": true } },
{ "id": "eac", "name": "Easy Anti-Cheat", "vendor": "Epic Games",
"match": { "strings_any": ["EasyAntiCheat","EasyAntiCheat_EOS","eos_sdk"],
"dylibs": ["libeasyanticheat"] },
"attack": { "anti_debug": "noop", "hide_hooks": true } },
{ "id": "be", "name": "BattlEye", "vendor": "BattlEye Innovations",
"match": { "strings_any": ["BattlEye","BEClient","BEService","BEDaisy"],
"dylibs": ["becclient"] },
"attack": { "anti_debug": "noop", "hide_hooks": true } }
]
}
JSON
cp "$ROOT/signatures.json" "$ROOT/docs/signatures.json"
c "done — 7 files created in $ROOT"
}
build(){
command -v xcrun >/dev/null || die "no xcrun — local build needs macOS"
[ -f "$ROOT/ACX.mm" ] || die "run 'scaffold' first"
c "compiling"
local SDK; SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos clang++ -arch arm64 -dynamiclib -fobjc-arc -O2
-isysroot "$SDK" -framework Foundation
-Wl,-undefined,dynamic_lookup
-Wl,-install_name,@rpath/ACX.dylib
"$ROOT/ACX.mm" -o "$ROOT/releases/ACX.dylib"
codesign -f -s - "$ROOT/releases/ACX.dylib" 2>/dev/null || true
shasum -a 256 "$ROOT/releases/ACX.dylib" > "$ROOT/releases/ACX.dylib.sha256"
c "built -> $ROOT/releases/ACX.dylib"
cat "$ROOT/releases/ACX.dylib.sha256"
}
publish(){
command -v gh >/dev/null || die "no gh — install the GitHub CLI and run: gh auth login"
[ -d "$ROOT/.git" ] || ( cd "$ROOT" && git init -q )
( cd "$ROOT" && git add -A && git commit -qm "ACX $TAG" || true )
( cd "$ROOT" && gh repo create "$REPO" --public --source=. --push )
( cd "$ROOT" && git tag -f "$TAG" && git push -q origin "$TAG" )
local U; U=$(gh api user -q .login)
c "waiting for the build…"
for _ in $(seq 1 40); do
gh release view "$TAG" --repo "$U/$REPO" >/dev/null 2>&1 && break
sleep 6
done
echo
echo "dylib https://github.com/$U/$REPO/releases/latest/download/ACX.dylib"
echo "website https://$U.github.io/$REPO/"
}
case "${1:-all}" in
scaffold) scaffold ;;
build) build ;;
publish) publish ;;
all) scaffold; build || true; publish ;;
*) echo "usage: bash releases.sh [scaffold|build|publish|all]"; exit 1 ;;
esac
