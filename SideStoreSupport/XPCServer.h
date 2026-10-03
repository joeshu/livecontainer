//
//  XPCServer.h
//  LiveContainer
//
//  Created by s s on 2025/7/20.
//

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

__attribute__((swift_attr("@Sendable")))
@protocol RefreshServer
- (void)updateProgress:(double)value taskID:(NSString*)taskID;
- (void)finish:(NSString* _Nullable)error taskID:(NSString*)taskID;
- (void)onConnection:(NSXPCConnection*)connection;
- (void)finishedLaunching;
- (void)addNotificationRequest:(UNNotificationRequest*)request reply:(void (^)(NSString* _Nullable error))reply;
- (void)notificationAuthorizationStatusWithReply:(void (^)(NSInteger status))reply NS_SWIFT_NAME(notificationAuthorizationStatus(_:));
- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString*>*)identifiers;
@end

@protocol RefreshClient
- (void)refreshAllAppsWithIdentifier:(NSString*)identifier mangledTypeName:(NSString *)mangledTypeName taskID:(NSString*)taskID;
@end

@interface LiveProcessSideStoreHandler : NSObject
@property (class, readonly, strong) LiveProcessSideStoreHandler* shared;
@property NSXPCConnection* connection;
@property NSObject<RefreshServer>* server;

@end

NSXPCListener* startAnonymousListener(NSObject<RefreshServer>* reporter);
NSData* bookmarkForURL(NSURL* url);

void installSideStoreHooks(void);
void installSideStoreNotificationHooks(void);

@interface SideStoreClient : NSObject<RefreshClient>
@property (class, readonly) SideStoreClient* shared;
- (void) relaunchLC;
@end
