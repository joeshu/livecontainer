//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "PiPManager.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"

@interface AppSceneViewController()
@property int resizeDebounceToken;
@property CFTimeInterval lastResizeRequestTime;
@property CGPoint normalizedOrigin;
@property bool isNativeWindow;
@property NSUUID* identifier;
@end

@interface AppSceneViewController()
@property(nonatomic) UIWindowScene *hostScene;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic) bool isAppTerminationCleanUpCalled;
@end

static BOOL LCIsSafeMultitaskPathComponent(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0 || value.length > 255) {
        return NO;
    }
    if ([value isEqualToString:@"."] || [value isEqualToString:@".."] ||
        [value containsString:@"/"] || [value containsString:@"\\"] ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        return NO;
    }
    return YES;
}

static BOOL LCAppendSecurityScopedBookmark(NSMutableArray *bookmarks, NSURL *url, NSError **error) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL || url.path.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"LiveContainer" code:40 userInfo:@{
            NSLocalizedDescriptionKey: @"Cannot create a bookmark for an invalid file URL"
        }];
        return NO;
    }
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDirectory] || !isDirectory) {
        if (error) *error = [NSError errorWithDomain:@"LiveContainer" code:41 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Bookmark target is not an existing directory: %@", url.path]
        }];
        return NO;
    }
    NSError *bookmarkError = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:(1UL << 11)
                         includingResourceValuesForKeys:nil
                                          relativeToURL:nil
                                                  error:&bookmarkError];
    if (!bookmark) {
        if (error) *error = bookmarkError ?: [NSError errorWithDomain:@"LiveContainer" code:42 userInfo:@{
            NSLocalizedDescriptionKey: @"Unable to create security-scoped bookmark"
        }];
        return NO;
    }
    [bookmarks addObject:bookmark];
    return YES;
}

@implementation AppSceneViewController


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIKitFixesInit();
    });
    
    // init extension
    NSError* error = nil;
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if(error) {
        [delegate appSceneVC:self didInitializeWithError:error];
        return nil;
    }
    _extension.preferredLanguages = @[];
    
    NSString *hostUrlScheme = NSUserDefaults.lcAppUrlScheme;
    NSString *homePath = NSHomeDirectory();
    if (_bundleId.length == 0 || _dataUUID.length == 0 ||
        hostUrlScheme.length == 0 || homePath.length == 0) {
        NSError *inputError = [NSError errorWithDomain:@"LiveContainer" code:29 userInfo:@{
            NSLocalizedDescriptionKey: @"Multitask launch request is missing required identity or home path"
        }];
        [delegate appSceneVC:self didInitializeWithError:inputError];
        return nil;
    }

    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableArray *bookmarks = [NSMutableArray array];
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:hostUrlScheme forKey:@"hostUrlScheme"];
    [userInfo setObject:_bundleId forKey:@"selected"];
    [userInfo setObject:_dataUUID forKey:@"selectedContainer"];
    [userInfo setObject:bookmarks forKey:@"bookmarks"];
    [userInfo setObject:homePath forKey:@"lcHomePath"];
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSError *bookmarkError = nil;
    if (!docURL) {
        bookmarkError = [NSError errorWithDomain:@"LiveContainer" code:30 userInfo:@{
            NSLocalizedDescriptionKey: @"Unable to resolve LiveContainer Documents directory"
        }];
    } else if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"]) {
        if (!LCAppendSecurityScopedBookmark(bookmarks, docURL, &bookmarkError)) {
            [delegate appSceneVC:self didInitializeWithError:bookmarkError];
            return nil;
        }
    } else {
        bool isSharedApp = false;
        NSBundle* bundle = [LCSharedUtils findBundleWithBundleId:bundleId isSharedAppOut:&isSharedApp];
        // For a private app, restrict LiveProcess to the bundle, the selected
        // container, and Tweaks. Never reconstruct an external container from
        // Data/Application/<folder>; the registered bookmark is authoritative.
        if (!isSharedApp) {
            if (!bundle) {
                bookmarkError = [NSError errorWithDomain:@"LiveContainer" code:31 userInfo:@{
                    NSLocalizedDescriptionKey: @"Unable to locate selected guest bundle"
                }];
            } else if (!LCAppendSecurityScopedBookmark(bookmarks, bundle.bundleURL, &bookmarkError)) {
                // bookmarkError is populated by the helper.
            } else {
                NSDictionary *guestInfo = [NSDictionary dictionaryWithContentsOfFile:
                    [bundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
                NSArray *containerRecords = guestInfo[@"LCContainers"];
                NSData *registeredBookmark = nil;
                BOOL hasContainerRegistry = [containerRecords isKindOfClass:NSArray.class];
                if (hasContainerRegistry) {
                    for (id rawRecord in containerRecords) {
                        if (![rawRecord isKindOfClass:NSDictionary.class]) continue;
                        NSDictionary *record = (NSDictionary *)rawRecord;
                        if ([record[@"folderName"] isKindOfClass:NSString.class] &&
                            [record[@"folderName"] isEqualToString:dataUUID]) {
                            if (record[@"bookmarkData"] &&
                                ![record[@"bookmarkData"] isKindOfClass:NSData.class]) {
                                bookmarkError = [NSError errorWithDomain:@"LiveContainer" code:32 userInfo:@{
                                    NSLocalizedDescriptionKey: @"Selected container bookmark has an invalid type"
                                }];
                            } else {
                                registeredBookmark = record[@"bookmarkData"];
                            }
                            break;
                        }
                    }
                    if (!bookmarkError && !registeredBookmark) {
                        bookmarkError = [NSError errorWithDomain:@"LiveContainer" code:33 userInfo:@{
                            NSLocalizedDescriptionKey: @"Selected container is not registered for this guest"
                        }];
                    }
                } else {
                    NSString *legacyUUID = guestInfo[@"LCDataUUID"];
                    if (![legacyUUID isKindOfClass:NSString.class] ||
                        ![legacyUUID isEqualToString:dataUUID] ||
                        !LCIsSafeMultitaskPathComponent(dataUUID)) {
                        bookmarkError = [NSError errorWithDomain:@"LiveContainer" code:34 userInfo:@{
                            NSLocalizedDescriptionKey: @"Selected container cannot be verified against guest metadata"
                        }];
                    }
                }

                if (!bookmarkError) {
                    if (registeredBookmark) {
                        BOOL stale = NO;
                        NSError *resolveError = nil;
                        NSURL *resolved = [NSURL URLByResolvingBookmarkData:registeredBookmark
                                                                      options:(1UL << 10)
                                                                relativeToURL:nil
                                                          bookmarkDataIsStale:&stale
                                                                        error:&resolveError];
                        BOOL isDirectory = NO;
                        if (!resolved || !resolved.isFileURL ||
                            ![NSFileManager.defaultManager fileExistsAtPath:resolved.path
                                                                 isDirectory:&isDirectory] ||
                            !isDirectory || ![resolved startAccessingSecurityScopedResource]) {
                            bookmarkError = resolveError ?: [NSError errorWithDomain:@"LiveContainer" code:35 userInfo:@{
                                NSLocalizedDescriptionKey: @"Unable to access selected external container bookmark"
                            }];
                        } else {
                            NSData *bookmarkForRequest = registeredBookmark;
                            if (stale) {
                                NSError *renewError = nil;
                                NSData *renewed = [resolved bookmarkDataWithOptions:(1UL << 11)
                                             includingResourceValuesForKeys:nil relativeToURL:nil error:&renewError];
                                if (renewed) {
                                    bookmarkForRequest = renewed;
                                } else {
                                    bookmarkError = renewError ?: [NSError errorWithDomain:@"LiveContainer" code:37 userInfo:@{
                                        NSLocalizedDescriptionKey: @"Unable to renew stale external container bookmark"
                                    }];
                                }
                            }
                            if (!bookmarkError) {
                                [bookmarks addObject:bookmarkForRequest];
                            }
                            [resolved stopAccessingSecurityScopedResource];
                        }
                    } else {
                        if (!LCIsSafeMultitaskPathComponent(dataUUID)) {
                            bookmarkError = [NSError errorWithDomain:@"LiveContainer" code:36 userInfo:@{
                                NSLocalizedDescriptionKey: @"Selected container name is unsafe"
                            }];
                        } else {
                            NSURL *dataURL = [docURL URLByAppendingPathComponent:
                                [NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
                            if (!LCAppendSecurityScopedBookmark(bookmarks, dataURL, &bookmarkError)) {
                                // bookmarkError is populated by the helper.
                            }
                        }
                    }
                }
                NSURL *tweaksURL = [docURL URLByAppendingPathComponent:@"Tweaks"];
                if (!bookmarkError && !LCAppendSecurityScopedBookmark(bookmarks, tweaksURL, &bookmarkError)) {
                    // bookmarkError is populated by the helper.
                }
            }
        }
    }
    if (bookmarkError) {
        [delegate appSceneVC:self didInitializeWithError:bookmarkError];
        return nil;
    }
    item.userInfo = userInfo;
    
    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        [weakSelf appTerminationCleanUp];
        [weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        if(identifier) {
            [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
            self.identifier = identifier;
            self.pid = [self.extension pidForRequestIdentifier:self.identifier];
            [delegate appSceneVC:self didInitializeWithError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setUpAppPresenter];
            });
        } else {
            NSError* error = [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start app. Child process has unexpectedly crashed"}];
            [delegate appSceneVC:self didInitializeWithError:error];
        }
    }];
    
    return self;
}

- (void)setUpAppPresenter {
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    [manager registerProcessForAuditToken:processHandle.auditToken];
    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];
    
    void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
        settings.canShowAlerts = YES;
        settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:self.view.layer.cornerRadius bottomLeft:self.view.layer.cornerRadius bottomRight:self.view.layer.cornerRadius topRight:self.view.layer.cornerRadius];
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
        settings.foreground = YES;
        //settings.interruptionPolicy = 2; // reconnect
        settings.level = 1;
        settings.persistenceIdentifier = self.dataUUID;
        settings.statusBarDisabled = !self.isNativeWindow;
        //settings.previewMaximumSize =
        //settings.deviceOrientationEventsEnabled = YES;
        if(!self.usesHostingControllerAPI) {
            settings.safeAreaInsetsPortrait = self.view.safeAreaInsets;
        }
    };
    void (^updateSceneClientSettings)(id) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
    };

    if (@available(iOS 18.0, *)) {
        // Use new API for iOS 18+. While some of these APIs are available since 17.0, we're only interested in fixing event deferring issue
        _UISceneHostingControllerAdvancedConfiguration *config = [[_UISceneHostingControllerAdvancedConfiguration alloc] initWithProcessIdentity:processHandle.identity];
        config.sceneSpecification = specification;
        if (@available(iOS 27.0, *)) {} else {
            // on 27 manually adding this is not need, also setAdditionalExtensions: doesn't exist for some reason
            config.additionalExtensions = [NSOrderedSet orderedSetWithArray:@[
                PrivClass(_UISceneHostingEventDeferringExtension),
            ]];
        }
        self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
        /// !! do NOT use self.hostingController.sceneView here as it breaks keyboard focus on iOS 26 below. I have no idea why this happens even though both return the same object. Maybe sceneView didn't initialize its ViewController properly?
        self.contentView = self.hostingController.sceneViewController.view;
        self.contentView.clipsToBounds = NO;
        // _scenePresenter was a property in 26, but made only ivar in 27
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
        self.sceneID = self.presenter.identifier;
        FBScene *scene = self.presenter.scene;
        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
            [parameters updateSettingsWithBlock:updateSceneSettings];
            [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        }];
        
        /// Fix keyboard focus by setting up event deferring extension. Previously we worked around it by changing identifier, but that broke other things
        _UISceneEventDeferringHostComponent *deferringComponent = self.hostingController._eventDeferringComponent;
        NSAssert(deferringComponent, @"Unexpectedly nil _UISceneEventDeferringHostComponent");
        if (@available(iOS 27.0, *)) { // _UIKeyboardArbiterUsesDeferringGraph()
            /// UIKitCore`__85-[_UIRemoteViewControllerSceneHostingImpl _viewServiceHostSessionDidConnectToClient:]_block_invoke
            /// iOS 27 requires setting up _UISceneEventDeferringHostComponent for keyboard focus to work
            
            /// Replicate these methods since they are made private
            /// -[_UISceneEventDeferringHostComponent setFirstResponderTrackingSelectionPath:]:
            [deferringComponent setValue:self forKey:@"_firstResponderTrackingSelectionPath"];
            // if (!deferringComponent->_flags.clientIsInChain) return;
            /// -[_UISceneEventDeferringHostComponent becomeFirstResponderIfNecessary]:
            // if (deferringComponent->_flags.maintainHostFirstResponderWhenClientWantsKeyboard)
            
            deferringComponent.grantBehavior = 2;
            deferringComponent.selectionRequestBehavior = 2;
        }
        /// UIKitCore`-[_UISceneHostingController createSceneWithConfiguration:]
        /// Lower iOS uses _UISceneHostingEventDeferringExtension, no further setup needed
        
        // Now it's time to get the initial settings from decorated VC
        [self.delegate appSceneVCWillActivateScene:self];
        [self addChildViewController:self.hostingController.sceneViewController];
        
        // For new API, let FBSSceneObserver send host scene events instead of NSExtensionContext
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center removeObserver:self.extension name:UIApplicationDidBecomeActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillEnterForegroundNotification object:UIApp];
    } else {
        self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
        FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
        definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
        definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
        definition.specification = specification;
        
        FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:specification];
        [parameters updateSettingsWithBlock:updateSceneSettings];
        [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
        self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
        [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
            context.appearanceStyle = 2;
        }];
        [self.presenter activate];
        
        self.contentView = [[UIView alloc] init];
        [self.contentView addSubview:self.presenter.presentationView];
    }
    [self.view addSubview:_contentView];
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    self.contentView.layer.anchorPoint = CGPointMake(0, 0);
    self.contentView.layer.position = CGPointMake(0, 0);
    
    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
}

- (void)terminate {
    if(self.isAppRunning) {
        [self.extension _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.extension _kill:SIGKILL];
        });
    }
}

- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if(!self.isAppRunning) {
        [self appTerminationCleanUp];
    }
    if(!diff) return;
    
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext lifecycleActionType:actionType];
}

- (void)viewWillLayoutSubviews {
    /// For native window we let iPadOS handle it however it wants, which is usually live resize (autoresizingMask set in appSceneVCWillActivateScene)
    if(_contentView.autoresizingMask != (UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight)) {
        [self updateFrameWithSettingsBlock:nil];
    }
}
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    __block int currentDebounceToken = ++_resizeDebounceToken;
    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken) {
            return;
        }
        [self updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            CGRect frame = self.view.frame;
            if(!self.usesHostingControllerAPI) {
                frame.size.width /= self.scaleRatio;
                frame.size.height /= self.scaleRatio;
            }
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGSize size = frame.size;
                frame.size.width = size.height;
                frame.size.height = size.width;
            }
            settings.frame = frame;
            if(block) {
                block(settings);
            }
        }];
    };
    if(_shouldSkipDebounceOnce) {
        _shouldSkipDebounceOnce = NO;
        queueBlock();
    } else {
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), queueBlock);
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if(_shouldIgnoreSceneUpdates) {
        // Ignore all updates when in PiP mode
        return;
    }
    
    if(!_hostingController && self.contentView) {
        // Legacy path
        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];
        return;
    }
    
    /// iOS 18.0 path, most are automatically handled by setting values to _UISceneHostingViewController
    /// This is also reachable on legacy path when contentView is nil during early setup
    UIMutableApplicationSceneSettings *tempSettings = [self.presenter.scene.settings mutableCopy];
    if(!tempSettings) {
        tempSettings = [UIMutableApplicationSceneSettings new];
    }
    updateSettingsBlock(tempSettings);
    CGRect frame = tempSettings.frame;
    if(UIInterfaceOrientationIsLandscape(tempSettings.interfaceOrientation)) {
        frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
    }
    
    if (self.contentView) {
        BOOL isiOS26 = NO;
        if(@available(iOS 19.0, *)) { if(@available(iOS 27.0, *)) {} else isiOS26 = YES; }
        // Discard position
        frame.origin = CGPointZero;
        self.contentView.frame = frame;
    } else {
        // This method can be called while contentView is nil to set up initial frame
        self.view.frame = frame;
    }
}

- (BOOL)isAppRunning {
    return _pid > 0 && getpgid(_pid) > 0;
}

- (void)appTerminationCleanUp {
    if(_isAppTerminationCleanUpCalled) {
        return;
    }
    _isAppTerminationCleanUpCalled = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(self.sceneID) {
            [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
        }
        if(self.usesHostingControllerAPI) {
            if(@available(iOS 17.0, *)) {
                [self.hostingController invalidate];
                [self.hostingController.sceneViewController removeFromParentViewController];
                self.hostingController = nil;
            }
        } else if(self.presenter){
            [self.presenter deactivate];
            [self.presenter invalidate];
        }
        self.presenter = nil;
        
        [self.delegate appSceneVCAppDidExit:self];
        [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
    });
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(self.usesHostingControllerAPI) {
        /// Issue with new API: FBSSceneObserver takes priority over to send UIApplicationWillResignActiveNotification regressed #942,
        /// so here we make it foreground (UIApplicationDidBecomeActiveNotification) again.
        [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.foreground = YES;
            settings.deactivationReasons = 0;
        }];
        return;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [center addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApp];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
    }
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if(!newWindow) {
        if(self.sceneID) {
            [self.view.window.windowScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
        }
        self.delegate = nil;
    }
}

- (void)openURLScheme:(NSString *)urlString {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        NSURL *url = [NSURL URLWithString:urlString];
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

- (BOOL)usesHostingControllerAPI {
    return _hostingController != nil;
}

@end
 
