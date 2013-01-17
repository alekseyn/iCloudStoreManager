//
//  UbiquityStoreManager.m
//  UbiquityStoreManager
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//

#import "UbiquityStoreManager.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else

#import <Cocoa/Cocoa.h>

#endif

NSString *const UbiquityManagedStoreDidChangeNotification = @"UbiquityManagedStoreDidChangeNotification";
NSString *const UbiquityManagedStoreDidImportChangesNotification = @"UbiquityManagedStoreDidImportChangesNotification";
NSString *const StoreUUIDKey                         = @"StoreUUIDKey";
NSString *const CloudEnabledKey                      = @"CloudEnabledKey";
NSString *const CloudIdentityKey                     = @"CloudIdentityKey";
NSString *const CloudStoreDirectory                  = @"CloudStore.nosync";
NSString *const CloudLogsDirectory                   = @"CloudLogs";

@interface UbiquityStoreManager ()<NSFilePresenter>

@property (nonatomic, copy) NSString               *contentName;
@property (nonatomic, strong) NSManagedObjectModel *model;
@property (nonatomic, copy) NSURL                  *localStoreURL;
@property (nonatomic, copy) NSString               *containerIdentifier;
@property (nonatomic, copy) NSDictionary           *additionalStoreOptions;

@property (nonatomic) NSString         *storeUUID;
@property (nonatomic) NSOperationQueue *persistentStorageQueue;
@property (nonatomic) BOOL loadingStore;

@end


@implementation UbiquityStoreManager
@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

- (id)init {

    return self = [self initStoreNamed:nil withManagedObjectModel:nil localStoreURL:nil containerIdentifier:nil additionalStoreOptions:nil];
}

- (id)initStoreNamed:(NSString *)contentName withManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL
 containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions {

    if (!(self = [super init]))
        return nil;

    if (!localStoreURL)
        localStoreURL = [[[self URLForApplicationContainer] URLByAppendingPathComponent:contentName] URLByAppendingPathExtension:@".sqlite"];

    // Parameters
    _contentName            = contentName == nil? @"UbiquityStore": contentName;
    _model                  = model == nil? [NSManagedObjectModel mergedModelFromBundles:nil]: model;
    _localStoreURL          = localStoreURL;
    _containerIdentifier    = containerIdentifier;
    _additionalStoreOptions = additionalStoreOptions == nil? [NSDictionary dictionary]: additionalStoreOptions;

    // Private vars
    _persistentStorageQueue = [NSOperationQueue new];
    [_persistentStorageQueue setName:[self className]];

    return self;
}

- (void)dealloc {

    [self clearStore];
}

#pragma mark - File Handling

- (NSURL *)URLForApplicationContainer {

    NSURL *applicationSupportURL = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                           inDomains:NSUserDomainMask] lastObject];

#if TARGET_OS_IPHONE
    // On iOS, each app is in a sandbox so we don't need to app-scope this directory.
    return applicationSupportURL;
#else
    // The directory is shared between all apps on the system so we need to scope it for the running app.
    applicationSupportURL = [applicationSupportURL URLByAppendingPathComponent:[NSRunningApplication currentApplication].bundleIdentifier];

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:applicationSupportURL
                                  withIntermediateDirectories:YES attributes:nil error:&error])
        [self error:error cause:UbiquityStoreManagerErrorCauseCreateStorePath context:applicationSupportURL.path];

    return applicationSupportURL;
#endif
}

- (NSURL *)URLForCloudContainer {

    return [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:self.containerIdentifier];
}

- (NSURL *)URLForCloudStoreDirectory {

    // We put the database in the ubiquity container with a .nosync extension (must not be synced by iCloud),
    // so that its presence is tied closely to whether iCloud is enabled or not on the device
    // and the user can delete the store by deleting his iCloud data for the app from Settings.
    return [[self URLForCloudContainer] URLByAppendingPathComponent:CloudStoreDirectory];
}

- (NSURL *)URLForCloudStore {

    // Our cloud store is in the cloud store databases directory and is identified by the active storeUUID.
    return [[[self URLForCloudStoreDirectory] URLByAppendingPathComponent:self.storeUUID] URLByAppendingPathExtension:@"sqlite"];
}

- (NSURL *)URLForCloudContentDirectory {

    // The transaction logs are in the ubiquity container and are synced by iCloud.
    return [[self URLForCloudContainer] URLByAppendingPathComponent:CloudLogsDirectory];
}

- (NSURL *)URLForCloudContent {

    // Our cloud store's logs are in the cloud store transaction logs directory and is identified by the active storeUUID.
    return [[self URLForCloudContentDirectory] URLByAppendingPathComponent:self.storeUUID];
}

- (NSURL *)URLForLocalStore {

    return self.localStoreURL;
}


#pragma mark - Utilities

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {

    va_list argList;
    va_start(argList, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);

    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:log:)])
        [self.delegate ubiquityStoreManager:self log:message];
    else
        NSLog(@"UbiquityStoreManager: %@", message);
}

- (void)error:(NSError *)error cause:(UbiquityStoreManagerErrorCause)cause context:(id)context {

    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didEncounterError:cause:context:)])
        [self.delegate ubiquityStoreManager:self didEncounterError:error cause:cause context:context];
    else
        [self log:@"error: %@, cause: %u, context: %@", error, cause, context];
}

#pragma mark - Store Management

- (void)clearStore {

    // Remove store observers.
    [NSFileCoordinator removeFilePresenter:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // Remove the store from the coordinator.
    NSPersistentStoreCoordinator *psc = self.persistentStoreCoordinator;
    BOOL pscLockedByUs = [psc tryLock];
    NSError *error = nil;
    BOOL failed = NO;

    for (NSPersistentStore *store in psc.persistentStores)
        if (![psc removePersistentStore:store error:&error]) {
            failed = YES;
            [self error:error cause:UbiquityStoreManagerErrorCauseClearStore context:store];
        }

    if (pscLockedByUs)
        [psc unlock];
    if (failed)
     // Try to recover by throwing out the PSC.
        _persistentStoreCoordinator = nil;
}

- (void)loadStore {

    @synchronized (self) {
        if (self.loadingStore)
            return;
        self.loadingStore = YES;
    }

    if (!self.cloudEnabled) {
        @try {
            // Load local store if iCloud is disabled.
            NSError             *error             = nil;
            NSMutableDictionary *localStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                                                           @YES, NSMigratePersistentStoresAutomaticallyOption,
                                                                           @YES, NSInferMappingModelAutomaticallyOption,
                                                                           nil];
            [localStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];

            // Add local store to PSC.
            [self.persistentStoreCoordinator lock];
            [self clearStore];
            if (![self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                               configuration:nil URL:[self URLForLocalStore]
                                                                     options:localStoreOptions
                                                                       error:&error])
                [self error:error cause:UbiquityStoreManagerErrorCauseOpenLocalStore context:[self URLForLocalStore]];
            [self observeStore];
        }
        @finally {
            [self.persistentStoreCoordinator unlock];
            self.loadingStore = NO;
        }

        [self log:@"iCloud disabled.  Loaded local store."];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification object:self userInfo:nil];
            if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didSwitchToiCloud:)])
                [self.delegate ubiquityStoreManager:self didSwitchToiCloud:NO];
        });

        return;
    }

    // Otherwise, load iCloud store asynchronously (init of iCloud may take some time).
    [self.persistentStorageQueue addOperationWithBlock:^{
        @try {
            if (![self URLForCloudContainer]) {
                // iCloud is not enabled on this device.  Disable iCloud in the app (will cause a re-load using the local store).
                // TODO: Notify user?
                self.loadingStore = NO;
                self.cloudEnabled = NO;
                return;
            }

            // Migrate the local store to a new cloud store when there is no cloud store yet.
            BOOL migrateLocalToCloud = NO;
            if (!self.storeUUID) {
                self.storeUUID = [[NSUUID UUID] UUIDString];

                if ([[NSFileManager defaultManager] fileExistsAtPath:[self URLForLocalStore].path])
                    migrateLocalToCloud = YES;
            }

            // Create the path to the cloud store.
            NSError *error = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:[self URLForCloudStoreDirectory].path
                                           withIntermediateDirectories:YES attributes:nil error:&error])
                [self error:error cause:UbiquityStoreManagerErrorCauseCreateStorePath context:[self URLForCloudStoreDirectory].path];

            // Add cloud store to PSC.
            NSURL               *cloudStoreURL         = [self URLForCloudStore];
            NSMutableDictionary *cloudStoreOptions     = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                                                               self.contentName, NSPersistentStoreUbiquitousContentNameKey,
                                                                               [self URLForCloudContent], NSPersistentStoreUbiquitousContentURLKey,
                                                                               @YES, NSMigratePersistentStoresAutomaticallyOption,
                                                                               @YES, NSInferMappingModelAutomaticallyOption,
                                                                               nil];
            NSMutableDictionary *migratingStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                                                               @YES, NSReadOnlyPersistentStoreOption,
                                                                               nil];
            [cloudStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
            [migratingStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];

            [self.persistentStoreCoordinator lock];
            [self clearStore];

            if (migrateLocalToCloud) {
                // First add the local store, then migrate it to the cloud store.
                [self log:@"Migrating local store to new cloud store."];

                // Add the store to migrate
                NSPersistentStore *migratingStore = [self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                                                  configuration:nil URL:[self URLForLocalStore]
                                                                                                        options:migratingStoreOptions
                                                                                                          error:&error];

                if (!migratingStore)
                    [self error:error cause:UbiquityStoreManagerErrorCauseOpenLocalStore context:[self URLForLocalStore]];

                else if (![self.persistentStoreCoordinator migratePersistentStore:migratingStore
                                                                            toURL:cloudStoreURL
                                                                          options:cloudStoreOptions
                                                                         withType:NSSQLiteStoreType
                                                                            error:&error])
                    [self error:error cause:UbiquityStoreManagerErrorCauseMigrateLocalToCloudStore context:cloudStoreURL.path];
            }
             // Not migrating, just add the existing cloud store.
            else if (![self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                    configuration:nil URL:cloudStoreURL
                                                                          options:cloudStoreOptions
                                                                            error:&error])
                [self error:error cause:UbiquityStoreManagerErrorCauseOpenCloudStore context:cloudStoreURL.path];
            [self observeStore];
        }
        @finally {
            [self.persistentStoreCoordinator unlock];
            self.loadingStore = NO;
        }

        [self log:@"iCloud enabled. Loaded cloud store."];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification object:self userInfo:nil];
            if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didSwitchToiCloud:)])
                [self.delegate ubiquityStoreManager:self didSwitchToiCloud:YES];
        });
    }];
}

- (void)observeStore {

    if (self.cloudEnabled) {
        [NSFileCoordinator addFilePresenter:self];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mergeChanges:)
                                                     name:NSPersistentStoreDidImportUbiquitousContentChangesNotification
                                                   object:self.persistentStoreCoordinator];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyValueStoreChanged:)
                                                 name:NSUbiquitousKeyValueStoreDidChangeExternallyNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cloudStoreChanged:)
                                                 name:NSUbiquityIdentityDidChangeNotification
                                               object:nil];
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
#else
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];
#endif
}

- (void)nukeCloudContainer {

    self.storeUUID = nil;

    NSURL *cloudContainerURL = [self URLForCloudContainer];
    if (cloudContainerURL && [[NSFileManager defaultManager] fileExistsAtPath:cloudContainerURL.path]) {
        [self.persistentStoreCoordinator lock];
        [self clearStore];

        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        for (NSString     *subPath in [[NSFileManager defaultManager] subpathsAtPath:cloudContainerURL.path]) {
            NSError *error = nil;
            [coordinator coordinateWritingItemAtURL:[NSURL fileURLWithPath:subPath] options:NSFileCoordinatorWritingForDeleting
                                              error:&error byAccessor:
             ^(NSURL *newURL) {
                 NSError *error_ = nil;
                 if (![[NSFileManager defaultManager] removeItemAtURL:newURL error:&error_])
                     [self error:error_ cause:UbiquityStoreManagerErrorCauseDeleteStore context:newURL.path];
             }];

            if (error)
                [self error:error cause:UbiquityStoreManagerErrorCauseDeleteStore context:subPath];
        }

        [self.persistentStoreCoordinator unlock];
        [self loadStore];
    }
}

- (void)deleteLocalStore {

    [self clearStore];
    NSError *error = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    
    [coordinator coordinateWritingItemAtURL:[self URLForLocalStore] options:NSFileCoordinatorWritingForDeleting
                                      error:&error byAccessor:^(NSURL *newURL) {
        NSError *error_ = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:newURL error:&error_])
            [self error:error_ cause:UbiquityStoreManagerErrorCauseDeleteStore context:newURL.path];
    }];
    
    if (error)
        [self error:error cause:UbiquityStoreManagerErrorCauseDeleteStore context:[self URLForLocalStore].path];

    [self loadStore];
}

- (void)deleteCloudStore {

    [self clearStore];
    NSError *error = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

    NSURL *cloudStoreURL = [self URLForCloudStore];
    [coordinator coordinateWritingItemAtURL:cloudStoreURL options:NSFileCoordinatorWritingForDeleting
                                      error:&error byAccessor:^(NSURL *newURL) {
        NSError *error_ = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:newURL error:&error_])
            [self error:error_ cause:UbiquityStoreManagerErrorCauseDeleteStore context:cloudStoreURL.path];
    }];
    
    if (error)
        [self error:error cause:UbiquityStoreManagerErrorCauseDeleteStore context:cloudStoreURL.path];

    [self loadStore];
}

#pragma mark - Properties

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator {

    if (!_persistentStoreCoordinator) {
        _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mergeChanges:)
                                                     name:NSPersistentStoreDidImportUbiquitousContentChangesNotification
                                                   object:_persistentStoreCoordinator];
    }

    if (![_persistentStoreCoordinator.persistentStores count])
        [self loadStore];

    return _persistentStoreCoordinator;
}

- (BOOL)cloudEnabled {

    NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
    return [local boolForKey:CloudEnabledKey];
}

- (void)setCloudEnabled:(BOOL)enabled {

    if (self.cloudEnabled == enabled)
     // No change, do nothing to avoid a needless store reload.
        return;

    NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
    [local setBool:enabled forKey:CloudEnabledKey];
    [self loadStore];
}

- (NSString *)storeUUID {

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    return [cloud objectForKey:StoreUUIDKey];
}

- (void)setStoreUUID:(NSString *)storeUUID {

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    [cloud setObject:storeUUID forKey:StoreUUIDKey];
    [cloud synchronize];
}

#pragma mark - NSFilePresenter

- (NSURL *)presentedItemURL {

    if (self.cloudEnabled)
        return [self URLForCloudStore];

    return [self URLForLocalStore];
}

- (NSOperationQueue *)presentedItemOperationQueue {

    return self.persistentStorageQueue;
}

- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler {

    // Active store file was deleted.
    [self cloudStoreChanged:nil];
    completionHandler(nil);
}


#pragma mark - Notifications

- (void)applicationDidBecomeActive:(NSNotification *)note {

    // Check for account changes.
    NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
    id lastIdentityToken    = [local objectForKey:CloudIdentityKey];
    id currentIdentityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];
    if (![lastIdentityToken isEqual:currentIdentityToken]) {
        [self cloudStoreChanged:nil];
        return;
    }
}

- (void)keyValueStoreChanged:(NSNotification *)note {

    if ([(NSArray *)[note.userInfo objectForKey:NSUbiquitousKeyValueStoreChangedKeysKey] containsObject:StoreUUIDKey])
        [self cloudStoreChanged:nil];
}

- (void)cloudStoreChanged:(NSNotification *)note {

    // Update the identity token in case it changed.
    NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
    id identityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];
    [local setObject:identityToken forKey:CloudIdentityKey];
    [local synchronize];

    // Reload the store.
    [self log:@"Cloud store changed.  StoreUUID: %@, Identity: %@", self.storeUUID, identityToken];
    [self loadStore];
}

- (void)mergeChanges:(NSNotification *)note {

    [self log:@"Cloud store updates:\n%@", note.userInfo];
    [self.persistentStorageQueue addOperationWithBlock:^{
        NSManagedObjectContext *moc = [self.delegate managedObjectContextForUbiquityStoreManager:self];
        [moc performBlockAndWait:^{
            [moc mergeChangesFromContextDidSaveNotification:note];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidImportChangesNotification object:self
                                                              userInfo:[note userInfo]];
        });
    }];
}

@end
