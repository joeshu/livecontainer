#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline NSURL * _Nullable LCGrantedRefreshDirectory(id path, NSArray *accessibleURLs) {
    if (![path isKindOfClass:NSString.class] || [path length] == 0) return nil;
    NSURL *expected = [NSURL fileURLWithPath:path isDirectory:YES].URLByResolvingSymlinksInPath;
    for (id candidate in accessibleURLs) {
        if (![candidate isKindOfClass:NSURL.class]) continue;
        NSURL *url = candidate;
        BOOL isDirectory = NO;
        if (url.isFileURL &&
            [url.URLByResolvingSymlinksInPath.path isEqualToString:expected.path] &&
            [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDirectory] && isDirectory) {
            return url;
        }
    }
    return nil;
}

/// Input URLs must already have granted security-scoped access. Matching by
/// identity avoids treating the journal as guest data when another grant fails.
static inline NSDictionary<NSString *, NSURL *> * _Nullable
LCScopedRefreshDirectories(NSDictionary *request, NSArray *accessibleURLs) {
    NSURL *container = LCGrantedRefreshDirectory(request[@"sideStoreContainerPath"], accessibleURLs);
    NSURL *journal = LCGrantedRefreshDirectory(request[@"refreshJournalPath"], accessibleURLs);
    if (!container || !journal ||
        [container.URLByResolvingSymlinksInPath.path isEqualToString:journal.URLByResolvingSymlinksInPath.path]) return nil;
    return @{@"container": container, @"journal": journal};
}

NS_ASSUME_NONNULL_END
