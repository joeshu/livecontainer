//
//  Localization.h
//  LiveContainer
//
//  Created by s s on 2024/9/21.
//
@import Foundation;

@interface NSUserDefaults(Localization)
+ (NSBundle*_Nonnull)lcMainBundle;
@end

@interface NSString (Localization)
@property(readonly, nonnull, getter=localized) NSString* loc;
- (instancetype _Nonnull)localized;
+ (NSString* _Nonnull)lcLocalizedStringWithFormat:(NSString* _Nonnull)format, ... NS_FORMAT_FUNCTION(1, 2);
@end
