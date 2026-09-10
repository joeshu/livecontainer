//
//  main.m
//  LiveProcess
//
//  Created by Duy Tran on 3/5/25.
//

#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <limits.h>
#import <string.h>
#import "../LiveContainer/utils.h"
#import "../LiveContainer/Tweaks/Tweaks.h"
#import "../SideStoreSupport/XPCServer.h"

@interface LiveProcessHandler : NSObject<NSExtensionRequestHandling>
@end
@implementation LiveProcessHandler
static NSExtensionContext *extensionContext;
static NSDictionary *retrievedAppInfo;
+ (NSExtensionContext *)extensionContext {
    return extensionContext;
}

+ (NSDictionary *)retrievedAppInfo {
    return retrievedAppInfo;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    extensionContext = context;
    retrievedAppInfo = [context.inputItems.firstObject userInfo];
    // Return control to LiveContainerMain
    CFRunLoopStop(CFRunLoopGetMain());
}
@end

extern int LiveContainerMain(int argc, char *argv[]);
static char **_envp, **_apple = NULL;
int LiveProcessMain(int argc, char *argv[]) {
    // Let NSExtensionContext initialize, once it's done it will call CFRunLoopStop
    CFRunLoopRun();
    // Ensure app info is delivered
    NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;
    NSCAssert(appInfo, @"Failed to retrieve app info");
    
    // Check if we received a request to execute a custom payload. Payloads are
    // trusted internal modules only; never accept an arbitrary path from IPC.
    NSString *customPayloadDylib = [appInfo[@"customPayloadDylib"] isKindOfClass:NSString.class]
        ? appInfo[@"customPayloadDylib"] : nil;
    if(customPayloadDylib.length > 0) {
        char resolvedPath[PATH_MAX];
        const char *path = customPayloadDylib.fileSystemRepresentation;
        struct stat st = {0};
        if (path == NULL || realpath(path, resolvedPath) == NULL ||
            lstat(path, &st) != 0 || !S_ISREG(st.st_mode) ||
            strstr(resolvedPath, "/Tweaks/") == NULL) {
            NSLog(@"[LiveProcess] rejected custom payload path: %@", customPayloadDylib);
            return 1;
        }
        void *handle = dlopen(resolvedPath, RTLD_LAZY | RTLD_LOCAL);
        if (handle == NULL) {
            NSLog(@"[LiveProcess] failed to load custom payload %@: %s",
                  customPayloadDylib, dlerror() ?: "unknown error");
            return 1;
        }
        NSString *customPayloadEntry = [appInfo[@"customPayloadEntry"] isKindOfClass:NSString.class]
            ? appInfo[@"customPayloadEntry"] : nil;
        if (customPayloadEntry.length == 0 ||
            [customPayloadEntry rangeOfCharacterFromSet:
                [NSCharacterSet characterSetWithCharactersInString:@"/\\\\"]].location != NSNotFound) {
            NSLog(@"[LiveProcess] rejected custom payload entry");
            dlclose(handle);
            return 1;
        }
        dlerror();
        int (*payloadEntry)(int, char **, char **, char **) = dlsym(handle, customPayloadEntry.UTF8String);
        const char *symbolError = dlerror();
        if (payloadEntry == NULL || symbolError != NULL) {
            NSLog(@"[LiveProcess] custom payload entry not found: %s",
                  symbolError ?: "unknown error");
            dlclose(handle);
            return 1;
        }
        return payloadEntry(argc, argv, _envp, _apple);
    }
    
    NSLog(@"Retrieved app info: %@", appInfo);
    // Set LiveContainer's home path
    setenv("LP_HOME_PATH", getenv("HOME"), 1);
    const char *overrideHomePath = [appInfo[@"lcHomePath"] fileSystemRepresentation];
    if(overrideHomePath) setenv("LC_HOME_PATH", overrideHomePath, 1);
    // Pass selected app info to user defaults
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    [lcUserDefaults setObject:appInfo[@"hostUrlScheme"] forKey:@"hostUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"launchAppUrlScheme"] forKey:@"launchAppUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"selected"] forKey:@"selected"];
    [lcUserDefaults setObject:appInfo[@"selectedContainer"] forKey:@"selectedContainer"];
    
    // Resolve every security-scoped bookmark defensively. Do not assign into an
    // empty NSMutableArray by indexed subscript: that raises NSRangeException
    // before the embedded SideStore XPC bridge can be established.
    NSArray *bookmarks = [appInfo[@"bookmarks"] isKindOfClass:NSArray.class]
        ? appInfo[@"bookmarks"]
        : @[];
    NSMutableArray<NSURL *> *accessibleBookmarkedUrls =
        [NSMutableArray arrayWithCapacity:bookmarks.count];
    for (id bookmark in bookmarks) {
        if (![bookmark isKindOfClass:NSData.class]) {
            NSLog(@"[LiveProcess] Ignoring invalid security-scoped bookmark: %@", bookmark);
            continue;
        }

        BOOL isStale = NO;
        NSError *error = nil;
        NSURL *resolvedURL = [NSURL URLByResolvingBookmarkData:(NSData *)bookmark
                                                         options:NSURLBookmarkResolutionWithSecurityScope
                                                   relativeToURL:nil
                                             bookmarkDataIsStale:&isStale
                                                           error:&error];
        if (!resolvedURL) {
            NSLog(@"[LiveProcess] Failed to resolve security-scoped bookmark: %@",
                  error.localizedDescription ?: @"unknown error");
            continue;
        }

        if ([resolvedURL startAccessingSecurityScopedResource]) {
            [accessibleBookmarkedUrls addObject:resolvedURL];
        } else {
            NSLog(@"[LiveProcess] Failed to access security-scoped bookmark: %@",
                  resolvedURL.path);
        }

        if (isStale) {
            NSLog(@"[LiveProcess] Resolved a stale security-scoped bookmark: %@",
                  resolvedURL.path);
        }
    }
    BOOL access = accessibleBookmarkedUrls.count > 0;
    
    if ([appInfo[@"selected"] isEqualToString:@"builtinSideStore"]) {
        if (accessibleBookmarkedUrls.count != 1) {
            NSLog(@"[LiveProcess] SideStore requires exactly one accessible container bookmark");
            return 1;
        }
        NSURL *sideStoreURL = accessibleBookmarkedUrls.firstObject;
        BOOL isDirectory = NO;
        if (!sideStoreURL.isFileURL ||
            ![NSFileManager.defaultManager fileExistsAtPath:sideStoreURL.path isDirectory:&isDirectory] ||
            !isDirectory) {
            NSLog(@"[LiveProcess] SideStore bookmark is not an accessible directory: %@", sideStoreURL.path);
            return 1;
        }
        [lcUserDefaults setObject:sideStoreURL.path forKey:@"specifiedSideStoreContainerPath"];
        NSXPCListenerEndpoint* endpoint = appInfo[@"endpoint"];
        if (![endpoint isKindOfClass:NSXPCListenerEndpoint.class]) {
            NSLog(@"[LiveProcess] SideStore refresh endpoint is missing");
            return 1;
        }

        NSXPCConnection* connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RefreshServer)];
        connection.interruptionHandler = ^{
            NSLog(@"interrupted!!!");
        };
        
        [connection activate];
        
        NSObject<RefreshServer>* proxy = [connection remoteObjectProxy];
        LiveProcessSideStoreHandler.shared.server = proxy;
        LiveProcessSideStoreHandler.shared.connection = connection;
        
    }

    
    return LiveContainerMain(argc, argv);
}

// this is our fake UIApplicationMain called from _xpc_objc_uimain (xpc_main)
__attribute__((visibility("default")))
int UIApplicationMain(int argc, char * argv[], NSString * principalClassName, NSString * delegateClassName) {
    return LiveProcessMain(argc, argv);
}

// NSExtensionMain will load UIKit and call UIApplicationMain, so we need to redirect it to our fake one
static void* (*orig_dlopen)(void* dyldApiInstancePtr, const char* path, int mode);
static void* hook_dlopen(void* dyldApiInstancePtr, const char* path, int mode) {
    const char *UIKitFrameworkPath = "/System/Library/Frameworks/UIKit.framework/UIKit";
    if(path && !strncmp(path, UIKitFrameworkPath, strlen(UIKitFrameworkPath))) {
        // switch back to original dlopen
        performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, orig_dlopen);
        // FIXME: may be incompatible with jailbreak tweaks?
        return RTLD_MAIN_ONLY;
    } else {
        __attribute__((musttail)) return orig_dlopen(dyldApiInstancePtr, path, mode);
    }
}

// Extension entry point
int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), @selector(_validateAllowedClass:forKey:allowingInvocations:)), (IMP)hook_do_nothing);
#pragma clang diagnostic pop
    // hook dlopen UIKit
    performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, hook_dlopen);
    // call the real one
    _envp = envp;
    _apple = apple;
    int (*orig_NSExtensionMain)(int argc, char * argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    return orig_NSExtensionMain(argc, argv);
}
