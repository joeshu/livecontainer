//
//  Localization.m
//  LiveContainer
//
//  Created by s s on 2024/9/21.
//
#import "Localization.h"

@implementation NSString (Localization)

// Class method for the English language bundle
+ (NSBundle *)enBundle {
    static NSBundle *enBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *language = @"en";
        NSString *path = [[NSUserDefaults lcMainBundle] pathForResource:language ofType:@"lproj"];
        enBundle = path ? [NSBundle bundleWithPath:path] : nil;
    });
    return enBundle;
}

// Instance method to return a localized string
- (NSString *)localized {
    NSString *message = [[NSUserDefaults lcMainBundle] localizedStringForKey:self value:@"" table:nil];
    
    if (![message isEqualToString:self]) {
        return message;
    }

    NSString *forcedString = [[NSString enBundle] localizedStringForKey:self value:nil table:nil];
    
    if (forcedString) {
        return forcedString;
    } else {
        return self;
    }
}

// The format is a fixed parameter; va_list therefore contains every value.
// Swift callers use String.localizeWithFormat(_:), which expands its array via
// Foundation's arguments initializer rather than passing an array as one value.
+ (NSString *)lcLocalizedStringWithFormat:(NSString *)format, ... {
    va_list arguments;
    va_start(arguments, format);
    NSString *result = [[NSString alloc] initWithFormat:format.localized
                                                locale:NSLocale.currentLocale
                                             arguments:arguments];
    va_end(arguments);
    return result;
}

@end
