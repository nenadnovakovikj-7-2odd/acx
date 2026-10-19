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
