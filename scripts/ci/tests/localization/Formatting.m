#import <Foundation/Foundation.h>
#import "Localization.h"

@implementation NSUserDefaults (LocalizationTestHost)
+ (NSBundle *)lcMainBundle { return NSBundle.mainBundle; }
@end

int main(void) {
    @autoreleasepool {
        NSString *mixed = [NSString lcLocalizedStringWithFormat:@"%@ / %lld / 100%%", @"签名", 42LL];
        if (![mixed isEqualToString:@"签名 / 42 / 100%"] ) return 1;
        NSString *reordered = [NSString lcLocalizedStringWithFormat:@"%2$lld items for %1$@", @"SideStore", 7LL];
        if (![reordered isEqualToString:@"7 items for SideStore"] ) return 2;
        NSLog(@"PASS: production Objective-C formatter preserves mixed and positional arguments");
    }
    return 0;
}
