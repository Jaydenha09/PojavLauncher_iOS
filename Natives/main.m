#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <spawn.h>
#import <sys/sysctl.h>
#import <UIKit/UIKit.h>

#import "AppDelegate.h"
#import "customcontrols/CustomControlsUtils.h"
#import "LauncherPreferences.h"
#import "SurfaceViewController.h"
#import "config.h"

#include <libgen.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <dirent.h>
#include "JavaLauncher.h"
#include "utils.h"
#include "codesign.h"
#include "deviceids.h"

#define CS_PLATFORM_BINARY 0x4000000
#define PT_TRACE_ME 0
#define PT_DETACH 11 
int ptrace(int, pid_t, caddr_t, int);
#define fm NSFileManager.defaultManager
extern char** environ;

void printEntitlementAvailability(NSString *key) {
    NSLog(@"* %@: %@", key, getEntitlementValue(key) ? @"YES" : @"NO");
}

bool init_checkForsubstrated() {
    // Please kindly tell pwn20wnd that he sucks
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t miblen = 4;
    size_t size;
    int st = sysctl(mib, miblen, NULL, &size, NULL, 0);
    struct kinfo_proc * process = NULL;
    struct kinfo_proc * newprocess = NULL;
    do {
        size += size / 10;
        newprocess = realloc(process, size);
        if (!newprocess){
            if (process){
                free(process);
            }
            return nil;
        }
        process = newprocess;
        st = sysctl(mib, miblen, process, &size, NULL, 0);
    } while (st == -1 && errno == ENOMEM);
    if (st == 0){
        if (size % sizeof(struct kinfo_proc) == 0){
            int nprocess = size / sizeof(struct kinfo_proc);
            if (nprocess){
                for (int i = nprocess - 1; i >= 0; i--){
                    if(strcmp(process[i].kp_proc.p_comm,"substrated") == 0) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

void init_checkForJailbreak() {
    bool jbDyld = false;
    bool jbFlag = false;
    bool jbProc = init_checkForsubstrated();
    bool jbFile = false;
    
    int imageCount = _dyld_image_count();
    uint32_t flags = CS_PLATFORM_BINARY;
    
    for (int i=0; i < imageCount; i++) {
        if (strcmp(_dyld_get_image_name(i),"/usr/lib/pspawn_payload-stg2.dylib") == 0) {
            jbDyld = true;
        }
    }

    if (csops(0, CS_OPS_STATUS, &flags, sizeof(flags)) != -1) {
        if ((flags & CS_PLATFORM_BINARY) != 0) {
            jbFlag = true;
        }
    }

    DIR *apps = opendir("/Applications");
    if(apps != NULL) {
        jbFile = true;
    }
    
    if (jbDyld || jbFlag || jbProc || jbFile) {
        setenv("POJAV_DETECTEDJB", "1", 1);
    }
}

void init_logDeviceAndVer(char *argument) {
    // PojavLauncher version
    NSLog(@"[Pre-Init] PojavLauncher version: %s-%s, branch: %s, commit: %s",
        [NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] UTF8String],
        CONFIG_TYPE, CONFIG_BRANCH, CONFIG_COMMIT);

    // Hardware + Software
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *deviceHardware = @(systemInfo.machine);
    const char *deviceSoftware = [[UIDevice currentDevice] systemVersion].UTF8String;
    
    NSString *friendlyName = deviceid_dict [deviceHardware];
    if(friendlyName != nil) {
        setenv("POJAV_DETECTEDHW", friendlyName.UTF8String, 1);
    } else {
        setenv("POJAV_DETECTEDHW", deviceHardware.UTF8String, 1);
        NSLog(@"[Pre-Init] Device model not recognized. Use appledb.dev to identify it!");
    }

    setenv("POJAV_DETECTEDSW", deviceSoftware, 1);
    
    NSString *tsPath = [NSString stringWithFormat:@"%s/../_TrollStore", getenv("BUNDLE_PATH")];
    const char *type = "Unjailbroken";
    if ([fm fileExistsAtPath:tsPath]) {
        type = "TrollStore";
    } else if (getenv("POJAV_DETECTEDJB")) {
        type = "Jailbroken";
    }
    
    setenv("POJAV_DETECTEDINST", type, 1);
    
    NSLog(@"[Pre-Init] %s with iOS %s (%s)", getenv("POJAV_DETECTEDHW"), getenv("POJAV_DETECTEDSW"), getenv("POJAV_DETECTEDINST"));
    
    NSString *jvmPath = [NSString stringWithFormat:@"%s/jvm", getenv("BUNDLE_PATH")];
    if (![fm fileExistsAtPath:jvmPath]) {
        setenv("POJAV_PREFER_EXTERNAL_JRE", "1", 1);
    }
    
    NSLog(@"[Pre-init] Entitlements availability:");
    printEntitlementAvailability(@"com.apple.developer.kernel.extended-virtual-addressing");
    printEntitlementAvailability(@"com.apple.developer.kernel.increased-memory-limit");
    printEntitlementAvailability(@"com.apple.private.security.no-sandbox");
    printEntitlementAvailability(@"dynamic-codesigning");
}

void init_migrateDirIfNecessary() {
    NSString *oldDir = @"/usr/share/pojavlauncher";
    if ([fm fileExistsAtPath:oldDir]) {
        NSString *newDir = @"";
        if ([@(getenv("HOME")) isEqualToString:@"/var/mobile"]) {
            newDir = [NSString stringWithFormat:@"%s/Documents/PojavLauncher", getenv("HOME")];
        } else {
            newDir = [NSString stringWithFormat:@"%s/Documents", getenv("HOME")];
        }
        [fm moveItemAtPath:oldDir toPath:newDir error:nil];
        [fm removeItemAtPath:oldDir error:nil];
    }
}

void init_migrateToPlist(char* prefKey, char* filename) {
    // NSString *readmeStr = @"#README - this file has been merged into launcher_preferences.plist";
    NSError *error;
    NSString *str, *path_str;

    // overrideargs.txt
    path_str = [NSString stringWithFormat:@"%s/%s", getenv("POJAV_HOME"), filename];
    str = [NSString stringWithContentsOfFile:path_str encoding:NSUTF8StringEncoding error:&error];
    if (error == nil && ![str hasPrefix:@"#README"]) {
        setPreference(@(prefKey), str);
        [@"#README - this file has been merged into launcher_preferences.plist" writeToFile:path_str atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void init_redirectStdio() {
    NSLog(@"[Pre-init] Starting logging STDIO to latestlog.txt\n");

    NSString *currName = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"latestlog.txt"];
    NSString *oldName = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"latestlog.old.txt"];
    [fm removeItemAtPath:oldName error:nil];
    [fm moveItemAtPath:currName toPath:oldName error:nil];

    [fm createFileAtPath:currName contents:nil attributes:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:currName];

    if (!file) {
        NSLog(@"[Pre-init] Error: failed to open %@", currName);
        assert(0 && "Failed to open latestlog.txt. Check oslog for more details.");
    }

    setvbuf(stdout, 0, _IOLBF, 0); // make stdout line-buffered
    setvbuf(stderr, 0, _IONBF, 0); // make stderr unbuffered

    /* create the pipe and redirect stdout and stderr */
    static int pfd[2];
    pipe(pfd);
    dup2(pfd[1], 1);
    dup2(pfd[1], 2);

    /* create the logging thread */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        static BOOL filteredSessionID;
        ssize_t rsize;
        char buf[2048];
        while((rsize = read(pfd[0], buf, sizeof(buf)-1)) > 0) {
            if (rsize < 2048) {
                buf[rsize] = '\0';
            }
            // Filter out Session ID here
            int index;
            if (!filteredSessionID) {
                char *sessionStr = strstr(buf, "(Session ID is ");
                if (sessionStr) {
                    char *censorStr = "(Session ID is <censored>)\n\0";
                    strcpy(sessionStr, censorStr);
                    rsize = strlen(buf);
                    filteredSessionID = true;
                }
            }
            if (canAppendToLog) {
                [SurfaceViewController appendToLog:@(buf)];
            }
            [file writeData:[NSData dataWithBytes:buf length:rsize]];
            [file synchronizeFile];
        }
        [file closeFile];
    });
}

void init_setupAccounts() {
    NSString *controlPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"accounts"];
    [fm createDirectoryAtPath:controlPath withIntermediateDirectories:NO attributes:nil error:nil];
}

void init_setupCustomControls() {
    NSString *controlPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"controlmap"];
    [fm createDirectoryAtPath:controlPath withIntermediateDirectories:NO attributes:nil error:nil];
    generateAndSaveDefaultControl();
}

void init_setupLauncherProfiles() {
    NSString *file = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    if (![fm fileExistsAtPath:file]) {
        NSDictionary *dict = @{
            @"profiles": @{
                @"(Default)": @{
                    @"name": @"(Default)",
                    @"lastVersionId": @"Unknown"
                }
            },
            @"selectedProfile": @"(Default)"
        };
        saveJSONToFile(dict, file);
    }
}

void init_setupMultiDir() {
    NSString *multidir = getPreference(@"game_directory");
    if (multidir.length == 0) {
        multidir = @"default";
        setPreference(@"game_directory", multidir);
        NSLog(@"[Pre-init] MULTI_DIR environment variable was not set. Defaulting to %@ for future use.\n", multidir);
    } else {
        NSLog(@"[Pre-init] Restored preference: MULTI_DIR is set to %@\n", multidir);
    }

    NSString *lasmPath = [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", getenv("POJAV_HOME")]; //libr
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), multidir];
    NSString *demoPath = [NSString stringWithFormat:@"%s/.demo", getenv("POJAV_HOME")];

    [fm createDirectoryAtPath:demoPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:multidirPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:lasmPath error:nil];
    [fm createDirectoryAtPath:lasmPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createSymbolicLinkAtPath:lasmPath withDestinationPath:multidirPath error:nil];
    setenv("POJAV_GAME_DIR", lasmPath.UTF8String, 1);

    if (0 == access("/var/mobile/Documents/minecraft", F_OK)) {
        [fm moveItemAtPath:@"/var/mobile/Documents/minecraft" toPath:multidir error:nil];
        NSLog(@"[Pre-init] Migrated old minecraft folder to new location.");
    }

    if (0 == access("/var/mobile/Documents/Library", F_OK)) {
        remove("/var/mobile/Documents/Library");
    }

    [fm changeCurrentDirectoryPath:lasmPath];
}

void init_setupResolvConf() {
    // Write known DNS servers to the config
    NSString *path = [NSString stringWithFormat:@"%s/resolv.conf", getenv("POJAV_HOME")];
    if (![fm fileExistsAtPath:path]) {
        [@"nameserver 8.8.8.8\n"
         @"nameserver 8.8.4.4"
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void init_setupSlimmed() {
    NSString *ipajre = [NSString stringWithFormat:@"%s/jvm/java-17-openjdk", getenv("BUNDLE_PATH")];
    NSString *sysjre = @"/usr/lib/jvm/java-17-openjdk";
    if ((![fm fileExistsAtPath:ipajre]) && (![fm fileExistsAtPath:sysjre])) {
        setenv("SLIMMED", "1", 1);
    }
}

int main(int argc, char *argv[]) {
    if (pJLI_Launch) {
        return pJLI_Launch(argc, (const char **)argv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   // PojavLancher: fixme: are these wrong?
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
    }

    if (!isJITEnabled(true) && argc == 2) {
        NSLog(@"calling ptrace(PT_TRACE_ME)");
        // Child process can call to PT_TRACE_ME
        // then both parent and child processes get CS_DEBUGGED
        int ret = ptrace(PT_TRACE_ME, 0, 0, 0);
        return ret;
    }

    init_checkForJailbreak();
    init_setupSlimmed();
    
    init_migrateDirIfNecessary();

    setenv("BUNDLE_PATH", dirname(argv[0]), 1);
    setenv("HOME", [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject.path.stringByDeletingLastPathComponent.UTF8String, 1);
    // WARNING: THIS DIRECTS TO /var/mobile/Documents IF INSTALLED WITH APPSYNC UNIFIED
    if ([@(getenv("HOME")) isEqualToString:@"/var/mobile"]) {
        setenv("POJAV_HOME", "/var/mobile/Documents/PojavLauncher", 1);
    } else {
        setenv("POJAV_HOME", [NSString stringWithFormat:@"%s/Documents", getenv("HOME")].UTF8String, 1);
    }

    [fm createDirectoryAtPath:@(getenv("POJAV_HOME")) withIntermediateDirectories:NO attributes:nil error:nil];

    init_redirectStdio();
    init_logDeviceAndVer(argv[0]);

    init_hookFunctions();
    init_hookUIKitConstructor();

    loadPreferences(NO);
    debugBoundsEnabled = [getPreference(@"debug_show_layout_bounds") boolValue];
    debugLogEnabled = [getPreference(@"debug_logging") boolValue];
    NSLog(@"Debug log enabled: %@", debugLogEnabled ? @"YES" : @"NO");

    init_setupResolvConf();
    init_setupMultiDir();
    init_setupLauncherProfiles();
    init_setupAccounts();
    init_setupCustomControls();

    init_migrateToPlist("selected_version", "config_ver.txt");
    init_migrateToPlist("java_args", "overrideargs.txt");

    // If sandbox is disabled, W^X JIT can be enabled by PojavLauncher itself
    if (!isJITEnabled(true) && getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        NSLog(@"[Pre-init] no-sandbox: YES, trying to enable JIT");
        int pid;
        int ret = posix_spawnp(&pid, argv[0], NULL, NULL, (char *[]){argv[0], "", NULL}, environ);
        if (ret == 0) {
            // Cleanup child process
            waitpid(pid, NULL, WUNTRACED);
            ptrace(PT_DETACH, pid, NULL, 0);
            kill(pid, SIGTERM);
            wait(NULL);

            if (isJITEnabled(true)) {
                NSLog(@"[Pre-init] JIT has been enabled with PT_TRACE_ME");
            } else {
                NSLog(@"[Pre-init] Failed to enable JIT: unknown reason");
            }
        } else {
            NSLog(@"[Pre-init] Failed to enable JIT: posix_spawn() failed errno %d", errno);
        }
    }

    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
