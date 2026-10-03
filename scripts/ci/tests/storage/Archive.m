#import <Foundation/Foundation.h>
#import "unarchive.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *fixtures = [NSString stringWithUTF8String:argv[1]];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *name in @[@"valid", @"traversal", @"absolute", @"safe-link", @"unsafe-link", @"broken"]) {
            NSString *output = [root stringByAppendingPathComponent:name];
            [fm createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
            int status = extract([fixtures stringByAppendingPathComponent:[name stringByAppendingString:@".zip"]], output, [NSProgress progressWithTotalUnitCount:0]);
            BOOL expected = [@[@"valid", @"safe-link"] containsObject:name];
            if ((status == 0) != expected) return 1;
            if (expected && ![fm fileExistsAtPath:[output stringByAppendingPathComponent:@"Payload/Test.app/data"]]) return 2;
        }
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"outside"]]) return 3;
        NSString *blocked = [root stringByAppendingPathComponent:@"blocked"];
        [@"file" writeToFile:blocked atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (extract([fixtures stringByAppendingPathComponent:@"valid.zip"], blocked, [NSProgress progressWithTotalUnitCount:0]) == 0) return 4;
        [fm removeItemAtPath:root error:nil];
        NSLog(@"PASS: actual ZIP extraction, safe links, traversal/absolute/unsafe-link rejection, corrupt input and disk write failure");
    }
    return 0;
}
