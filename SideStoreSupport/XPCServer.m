//
//  XPCServer.m
//  LiveContainer
//
//  Created by s s on 2025/7/20.
//

#import <Foundation/Foundation.h>
#import "XPCServer.h"
#import <objc/runtime.h>

@interface ServerDelegate : NSObject <NSXPCListenerDelegate>
@property NSObject<RefreshServer>* reporter;
@end

@implementation ServerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RefreshServer)];
    newConnection.exportedObject = self.reporter;
    [self.reporter onConnection:newConnection];
    [newConnection resume];
    return YES;
}

@end

static char listenerDelegateKey;

NSXPCListener* startAnonymousListener(NSObject<RefreshServer>* reporter) {
    ServerDelegate *delegate = [ServerDelegate new];
    delegate.reporter = reporter;
    NSXPCListener *listener = [NSXPCListener anonymousListener];
    listener.delegate = delegate;
    // NSXPCListener does not retain its delegate. Keep each delegate alive with
    // its own listener instead of a global that can be overwritten by a retry.
    objc_setAssociatedObject(listener, &listenerDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [listener resume];
    return listener;
}

NSData* bookmarkForURL(NSURL* url) {
    return [url bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
}
