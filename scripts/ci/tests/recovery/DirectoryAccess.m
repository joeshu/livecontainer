#import <Foundation/Foundation.h>
#import "RefreshDirectoryAccess.h"

int main(void) {
    @autoreleasepool {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSURL *container = [root URLByAppendingPathComponent:@"data" isDirectory:YES];
        NSURL *journal = [root URLByAppendingPathComponent:@"journal" isDirectory:YES];
        [manager createDirectoryAtURL:container withIntermediateDirectories:YES attributes:nil error:nil];
        [manager createDirectoryAtURL:journal withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *request = @{@"sideStoreContainerPath": container.path, @"refreshJournalPath": journal.path};
        NSDictionary *result = LCScopedRefreshDirectories(request, @[journal, container]);
        if (![result[@"container"] isEqual:container] || ![result[@"journal"] isEqual:journal]) return 1;
        if (LCScopedRefreshDirectories(request, @[journal])) return 2;
        if (LCScopedRefreshDirectories(request, @[container])) return 3;
        if (LCScopedRefreshDirectories(@{@"sideStoreContainerPath": @42, @"refreshJournalPath": journal.path}, @[journal, container])) return 4;
        if (LCScopedRefreshDirectories(@{@"sideStoreContainerPath": journal.path, @"refreshJournalPath": journal.path}, @[journal])) return 5;
        NSURL *alias = [root URLByAppendingPathComponent:@"alias" isDirectory:YES];
        [manager createSymbolicLinkAtURL:alias withDestinationURL:journal error:nil];
        NSDictionary *aliasRequest = @{@"sideStoreContainerPath": container.path, @"refreshJournalPath": alias.path};
        if (!LCScopedRefreshDirectories(aliasRequest, @[journal, container])) return 6;
        NSURL *file = [root URLByAppendingPathComponent:@"file"];
        [@"not a directory" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (LCScopedRefreshDirectories(@{@"sideStoreContainerPath": file.path, @"refreshJournalPath": journal.path}, @[file, journal])) return 7;
        [manager removeItemAtURL:root error:nil];
        NSLog(@"PASS: directory identity, reversed grants, missing grants, invalid paths, symlink aliases and file rejection");
    }
    return 0;
}
