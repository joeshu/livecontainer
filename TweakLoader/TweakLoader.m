#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#import "../LiveContainer/utils.h"

static BOOL LCIsSafeLeafName(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0 || name.length > 255 ||
        [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
        [name containsString:@"/"] || [name containsString:@"\\"] ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        return NO;
    }
    return YES;
}

static NSString *LCRealPath(NSURL *url) {
    char resolved[PATH_MAX];
    if (url == nil || realpath(url.fileSystemRepresentation, resolved) == NULL) {
        return nil;
    }
    return [NSString stringWithUTF8String:resolved];
}

static BOOL LCPathIsUnderRoot(NSURL *candidateURL, NSURL *rootURL) {
    NSString *root = LCRealPath(rootURL);
    NSString *candidate = LCRealPath(candidateURL);
    if (root.length == 0 || candidate.length == 0) {
        return NO;
    }
    return [candidate isEqualToString:root] ||
        [candidate hasPrefix:[root stringByAppendingString:@"/"]];
}

static BOOL LCPathHasSymlinkComponent(NSURL *candidateURL, NSURL *rootURL) {
    NSString *root = [rootURL URLByResolvingSymlinksInPath].standardizedFileURL.path;
    NSString *path = candidateURL.standardizedFileURL.path;
    if (root.length == 0 || path.length == 0 ||
        !([path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]])) {
        return YES;
    }

    NSString *relative = path.length == root.length ? @"" :
        [path substringFromIndex:root.length + 1];
    NSString *current = root;
    for (NSString *component in relative.pathComponents) {
        current = [current stringByAppendingPathComponent:component];
        struct stat st = {0};
        if (lstat(current.fileSystemRepresentation, &st) != 0) {
            return YES;
        }
        if (S_ISLNK(st.st_mode)) {
            return YES;
        }
    }
    return NO;
}

static BOOL LCIsRegularFile(NSURL *url) {
    struct stat st = {0};
    return url != nil && lstat(url.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode);
}

static NSString *loadTweakAtURL(NSURL *url, NSURL *rootURL) {
    NSString *tweakPath = url.path;
    NSString *tweak = tweakPath.lastPathComponent;
    if (![tweakPath hasSuffix:@".dylib"] && ![tweakPath hasSuffix:@".framework"]) {
        return nil;
    }
    if (!LCPathIsUnderRoot(url, rootURL) || LCPathHasSymlinkComponent(url, rootURL)) {
        return [NSString stringWithFormat:@"Unable to load %@: path is outside the trusted tweak root or contains a symlink", tweak];
    }

    NSURL *binaryURL = url;
    if ([tweakPath hasSuffix:@".framework"]) {
        NSURL *infoPlistURL = [url URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
        NSString *binary = infoDict[@"CFBundleExecutable"];
        if (!LCIsSafeLeafName(binary)) {
            return [NSString stringWithFormat:@"Unable to load %@: invalid CFBundleExecutable", tweak];
        }
        binaryURL = [url URLByAppendingPathComponent:binary isDirectory:NO];
        if (!LCPathIsUnderRoot(binaryURL, rootURL) || LCPathHasSymlinkComponent(binaryURL, rootURL)) {
            return [NSString stringWithFormat:@"Unable to load %@: framework binary escapes the trusted tweak root", tweak];
        }
    }
    if (!LCIsRegularFile(binaryURL)) {
        return [NSString stringWithFormat:@"Unable to load %@: module binary is not a regular file", tweak];
    }

    void *handle = dlopen(binaryURL.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    const char *error = dlerror();
    if (handle) {
        NSLog(@"Loaded tweak %@", tweak);
        return nil;
    } else if (error) {
        NSLog(@"Error: %s", error);
        return @(error);
    } else {
        NSLog(@"Error: dlopen(%@): Unknown error because dlerror() returns NULL", tweak);
        return [NSString stringWithFormat:@"dlopen(%@): unknown error, handle is NULL", binaryURL.path];
    }
}

static void loadTweaksRecursively(NSURL *folderURL, NSURL *rootURL, NSMutableArray *errors) {
    if (!LCPathIsUnderRoot(folderURL, rootURL) || LCPathHasSymlinkComponent(folderURL, rootURL)) {
        [errors addObject:[NSString stringWithFormat:@"Rejected tweak folder %@", folderURL.path]];
        return;
    }
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folderURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil];
    if (items == nil) {
        [errors addObject:[NSString stringWithFormat:@"Unable to enumerate tweak folder %@", folderURL.path]];
        return;
    }
    for (NSURL *fileURL in items) {
        NSString *name = fileURL.lastPathComponent;
        if ([name hasSuffix:@".disabled"]) {
            NSLog(@"Skipping disabled tweak %@", name);
            continue;
        }
        NSNumber *isDirectory = nil;
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        // a .framework is a directory but loads as a single tweak
        if (isDirectory.boolValue && ![name hasSuffix:@".framework"]) {
            loadTweaksRecursively(fileURL, rootURL, errors);
        } else {
            NSString *error = loadTweakAtURL(fileURL, rootURL);
            if (error) {
                [errors addObject:error];
            }
        }
    }
}

static void showDlerrAlert(NSString *error) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed to load tweaks" message:error preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        UIPasteboard.generalPasteboard.string = error;
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = 1000;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

 __attribute__((constructor))
static void TweakLoaderConstructor() {
    const char *tweakFolderC = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    if (tweakFolderC == NULL || tweakFolderC[0] == '\0') {
        NSLog(@"[TweakLoader] no global tweak root configured");
        return;
    }
    NSURL *globalTweakRootURL = [NSURL fileURLWithPath:@(tweakFolderC) isDirectory:YES];
    unsetenv("LC_GLOBAL_TWEAKS_FOLDER");

    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        // don't load any tweak since tweakloader is loaded after all initializers
        NSLog(@"Skip loading tweaks");
        return;
    }
    
    NSMutableArray *errors = [NSMutableArray new];
    
    NSArray<NSURL *> *globalTweaks = [NSFileManager.defaultManager contentsOfDirectoryAtURL:globalTweakRootURL
    includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil];
    if (globalTweaks == nil) {
        [errors addObject:[NSString stringWithFormat:@"Unable to enumerate global tweak root %@", globalTweakRootURL.path]];
        globalTweaks = @[];
    }
    NSString *tweakFolderName = NSUserDefaults.guestAppInfo[@"LCTweakFolder"];
    if (tweakFolderName.length > 0 && !LCIsSafeLeafName(tweakFolderName)) {
        [errors addObject:@"Rejected invalid selected tweak folder name"];
        tweakFolderName = nil;
    }
    
    if([globalTweaks count] <= 1 && tweakFolderName.length == 0) {
        // nothing to load
        return;
    }

    // Load CydiaSubstrate
    const char *lcMainBundlePath;
    if(NSUserDefaults.isLiveProcess) {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation;
    } else {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation;
    }
    char substratePath[PATH_MAX];
    snprintf(substratePath, sizeof(substratePath), "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", lcMainBundlePath);
    dlopen(substratePath, RTLD_LAZY | RTLD_GLOBAL);
    const char *substrateError = dlerror();
    if (substrateError) {
        [errors addObject:@(substrateError)];
    }

    // Load global tweaks
    NSLog(@"Loading tweaks from the global folder");

    for (NSURL *fileURL in globalTweaks) {
        NSString *name = fileURL.lastPathComponent;
        if ([name isEqualToString:@"TweakLoader.dylib"]) {
            // skip loading myself
            continue;
        }
        if ([name hasSuffix:@".disabled"]) {
            NSLog(@"Skipping disabled global tweak %@", name);
            continue;
        }
        NSString *error = loadTweakAtURL(fileURL, globalTweakRootURL);
        if (error) {
            [errors addObject:error];
        }
    }

    // Load selected tweak folder, recursively
    if (tweakFolderName.length > 0) {
        NSLog(@"Loading tweaks from the selected folder");
        NSURL *tweakFolderURL = [globalTweakRootURL URLByAppendingPathComponent:tweakFolderName isDirectory:YES];
        loadTweaksRecursively(tweakFolderURL, globalTweakRootURL, errors);
    }

    if (errors.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = [errors componentsJoinedByString:@"\n"];
            showDlerrAlert(error);
        });
    }
}
