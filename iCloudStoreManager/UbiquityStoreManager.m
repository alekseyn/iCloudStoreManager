//
//  UbiquityStoreManager.m
//  UbiquityStoreManager
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//

#import "UbiquityStoreManager.h"
#import "JRSwizzle.h"
#import "NSManagedObject+UbiquityStoreManager.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else

#import <Cocoa/Cocoa.h>

#endif

NSString *const UbiquityManagedStoreDidChangeNotification = @"UbiquityManagedStoreDidChangeNotification";
NSString *const UbiquityManagedStoreDidImportChangesNotification = @"UbiquityManagedStoreDidImportChangesNotification";
NSString *const CloudEnabledKey                      = @"USMCloudEnabledKey"; // local: Whether the user wants the app on this device to use iCloud.
NSString *const StoreUUIDKey                         = @"USMStoreUUIDKey"; // cloud: The UUID of the active cloud store.
NSString *const CloudStoreDirectory                  = @"CloudStore.nosync";
NSString *const CloudStoreMigrationSource            = @"MigrationSource.sqlite";
NSString *const CloudContentDirectory                = @"CloudLogs";

@interface UbiquityStoreManager ()<NSFilePresenter>

@property (nonatomic, copy) NSString               *contentName;
@property (nonatomic, strong) NSManagedObjectModel *model;
@property (nonatomic, copy) NSURL                  *localStoreURL;
@property (nonatomic, copy) NSString               *containerIdentifier;
@property (nonatomic, copy) NSDictionary           *additionalStoreOptions;
@property (nonatomic, readonly) NSString           *storeUUID;
@property (nonatomic, strong) NSString             *tentativeStoreUUID;
@property (nonatomic, strong) NSOperationQueue     *persistentStorageQueue;
@property (nonatomic, readonly) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (nonatomic, strong) id <NSObject, NSCopying, NSCoding> currentIdentityToken;
@property (nonatomic, strong) NSURL                *migrationStoreURL;
@end


@implementation UbiquityStoreManager {
    NSPersistentStoreCoordinator *_persistentStoreCoordinator;
    NSOperationQueue *_presentedItemOperationQueue;
}

+ (void)initialize {

    if (![self respondsToSelector:@selector(jr_swizzleMethod:withMethod:error:)]) {
        NSLog(@"UbiquityStoreManager: Warning: JRSwizzle not present, won't be able to detect desync issues.");
        return;
    }

    NSError *error = nil;
    if (![NSError jr_swizzleMethod:@selector(initWithDomain:code:userInfo:)
                                withMethod:@selector(init_USM_WithDomain:code:userInfo:)
                                     error:&error])
        NSLog(@"UbiquityStoreManager: Warning: Failed to swizzle, won't be able to detect desync issues.  Cause: %@", error);
    else
        NSLog(@"UbiquityStoreManager: Swizzled (from %@).", self.class);
}

- (id)initStoreNamed:(NSString *)contentName withManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL
 containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions
            delegate:(id <UbiquityStoreManagerDelegate>)delegate {

    if (!(self = [super init]))
        return nil;

    // Parameters.
    _delegate               = delegate;
    _contentName            = contentName == nil? @"UbiquityStore": contentName;
    _model                  = model == nil? [NSManagedObjectModel mergedModelFromBundles:nil]: model;
    if (!localStoreURL)
        localStoreURL = [[[self URLForApplicationContainer]
                                URLByAppendingPathComponent:self.contentName isDirectory:NO]
                                URLByAppendingPathExtension:@"sqlite"];
    _localStoreURL          = localStoreURL;
    _containerIdentifier    = containerIdentifier;
    _additionalStoreOptions = additionalStoreOptions == nil? [NSDictionary dictionary]: additionalStoreOptions;

    // Private vars.
    _currentIdentityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];
    _migrationStrategy = UbiquityStoreMigrationStrategyCopyEntities;
    _persistentStorageQueue = [NSOperationQueue new];
    _persistentStorageQueue.name = [NSString stringWithFormat:@"%@PersistenceQueue", NSStringFromClass([self class])];
    _persistentStorageQueue.maxConcurrentOperationCount = 1;
    _presentedItemOperationQueue = [NSOperationQueue new];
    _presentedItemOperationQueue.name = [NSString stringWithFormat:@"%@PresenterQueue", NSStringFromClass([self class])];
    _presentedItemOperationQueue.maxConcurrentOperationCount = 1;

    // Observe application events.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyValueStoreChanged:)
                                                 name:NSUbiquitousKeyValueStoreDidChangeExternallyNotification
                                               object:[NSUbiquitousKeyValueStore defaultStore]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cloudStoreChanged:)
                                                 name:NSUbiquityIdentityDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkCloudContentCorruption:)
                                                 name:UbiquityManagedStoreDidDetectCorruptionNotification
                                               object:nil];
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
#else
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];
#endif
    [NSFileCoordinator addFilePresenter:self];

    [self loadStore];
    
    return self;
}

- (void)dealloc {

    [NSFileCoordinator removeFilePresenter:self];
    [self.persistentStoreCoordinator tryLock];
    [self clearStore];
    [self.persistentStoreCoordinator unlock];
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
    applicationSupportURL = [applicationSupportURL URLByAppendingPathComponent:[NSRunningApplication currentApplication].bundleIdentifier isDirectory:YES];

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:applicationSupportURL
                                  withIntermediateDirectories:YES attributes:nil error:&error])
        [self error:error cause:UbiquityStoreErrorCauseCreateStorePath context:applicationSupportURL.path];

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
    return [[self URLForCloudContainer] URLByAppendingPathComponent:CloudStoreDirectory isDirectory:YES];
}

- (NSURL *)URLForCloudStore {

    // Our cloud store is in the cloud store databases directory and is identified by the active storeUUID.
    return [[[self URLForCloudStoreDirectory] URLByAppendingPathComponent:self.storeUUID isDirectory:NO] URLByAppendingPathExtension:@"sqlite"];
}

- (NSURL *)URLForCloudContentDirectory {

    // The transaction logs are in the ubiquity container and are synced by iCloud.
    return [[self URLForCloudContainer] URLByAppendingPathComponent:CloudContentDirectory isDirectory:YES];
}

- (NSURL *)URLForCloudContent {

    // Our cloud store's logs are in the cloud store transaction logs directory and is identified by the active storeUUID.
    return [[self URLForCloudContentDirectory] URLByAppendingPathComponent:self.storeUUID isDirectory:YES];
}

- (NSURL *)URLForLocalStoreDirectory {
    
    return [self.localStoreURL URLByDeletingLastPathComponent];
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

- (void)error:(NSError *)error cause:(UbiquityStoreErrorCause)cause context:(id)context {

    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didEncounterError:cause:context:)])
        [self.delegate ubiquityStoreManager:self didEncounterError:error cause:cause context:context];
    else {
        [self log:@"Error (cause:%u): %@", cause, error];

        if (context)
            [self log:@"    - Context   : %@", context];
        NSError *underlyingError = [[error userInfo] objectForKey:NSUnderlyingErrorKey];
        if (underlyingError)
            [self log:@"    - Underlying: %@", underlyingError];
        NSArray *detailedErrors = [[error userInfo] objectForKey:NSDetailedErrorsKey];
        for (NSError *detailedError in detailedErrors)
            [self log:@"    - Detail    : %@", detailedError];
    }
}

#pragma mark - Store Management

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator {

    if (!_persistentStoreCoordinator) {
        _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mergeChanges:)
                                                     name:NSPersistentStoreDidImportUbiquitousContentChangesNotification
                                                   object:_persistentStoreCoordinator];
    }

    return _persistentStoreCoordinator;
}

- (void)resetPersistentStoreCoordinator {

    BOOL wasLocked = NO;
    if (_persistentStoreCoordinator) {
        wasLocked = ![_persistentStoreCoordinator tryLock];
        [_persistentStoreCoordinator unlock];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_persistentStoreCoordinator];
    }

    if (wasLocked)
        [self.persistentStoreCoordinator lock];
}

- (void)clearStore {

    [self log:@"Clearing stores..."];
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:willLoadStoreIsCloud:)])
        [self.delegate ubiquityStoreManager:self willLoadStoreIsCloud:self.cloudEnabled];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification
                                                            object:self userInfo:nil];
    });

    // Remove the store from the coordinator.
    NSError *error = nil;
    for (NSPersistentStore *store in self.persistentStoreCoordinator.persistentStores)
        if (![self.persistentStoreCoordinator removePersistentStore:store error:&error])
            [self error:error cause:UbiquityStoreErrorCauseClearStore context:store];

    if ([self.persistentStoreCoordinator.persistentStores count])
        // We couldn't remove all the stores, make a new PSC instead.
        [self resetPersistentStoreCoordinator];
}

- (void)loadStore {

    [self log:@"(Re)loading store..."];
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:willLoadStoreIsCloud:)])
        [self.delegate ubiquityStoreManager:self willLoadStoreIsCloud:self.cloudEnabled];

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self.persistentStoreCoordinator lock];
        @try {
            if (self.cloudEnabled)
                [self loadCloudStore];
            else
                [self loadLocalStore];
        } @finally {
            [self.persistentStoreCoordinator unlock];
        }
    }];
}

- (void)loadCloudStore {

    [self log:@"Will load cloud store: %@ (%@).", self.storeUUID, _tentativeStoreUUID? @"tentative": @"definite"];

    // Check if the cloud store has been locked down because of content corruption.
    if ([self checkCloudContentCorruption:nil])
        // We don't put this in the @try block because we don't want to handle this failure in the @finally block.
        // That's because the check method allows the application to take action which would confuse the @finally block.
        return;

    __block id context = nil;
    __block NSError *error = nil;
    __block UbiquityStoreErrorCause cause = UbiquityStoreErrorCauseNoError;
    @try {
        [self clearStore];

        // Check if the user is logged into iCloud on the device.
        if (![self URLForCloudContainer]) {
            cause = UbiquityStoreErrorCauseNoAccount;
            return;
        }

        // Create the path to the cloud store and content if it doesn't exist yet.
        NSURL *cloudStoreURL = [self URLForCloudStore];
        NSURL *cloudStoreContentURL = [self URLForCloudContent];
        NSURL *cloudStoreDirectoryURL = [self URLForCloudStoreDirectory];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:cloudStoreDirectoryURL.path
                                       withIntermediateDirectories:YES attributes:nil error:&error])
            [self error:error cause:cause = UbiquityStoreErrorCauseCreateStorePath context:context = cloudStoreDirectoryURL.path];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:cloudStoreContentURL.path
                                       withIntermediateDirectories:YES attributes:nil error:&error])
            [self error:error cause:cause = UbiquityStoreErrorCauseCreateStorePath context:context = cloudStoreContentURL.path];

        // Clean up the cloud store if the cloud content got deleted.
        BOOL storeExists = [[NSFileManager defaultManager] fileExistsAtPath:cloudStoreURL.path];
        BOOL storeContentExists = [[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:cloudStoreContentURL error:nil];
        if (storeExists && !storeContentExists) {
            // We have a cloud store but no cloud content.  The cloud content was deleted:
            // The existing store cannot sync anymore and needs to be recreated.
            [self log:@"Deleting cloud store: it has no cloud content."];

            if (![[NSFileManager defaultManager] removeItemAtURL:cloudStoreURL error:&error])
                [self error:error cause:cause = UbiquityStoreErrorCauseDeleteStore context:context = cloudStoreURL.path];
        }

        // Check if we need to seed the store by migrating another store into it.
        UbiquityStoreMigrationStrategy migrationStrategy = self.migrationStrategy;
        NSURL *migrationStoreURL = self.migrationStoreURL ? self.migrationStoreURL : [self localStoreURL];
        if (![self cloudSafeForSeeding] || ![[NSFileManager defaultManager] fileExistsAtPath:migrationStoreURL.path])
            migrationStrategy = UbiquityStoreMigrationStrategyNone;

        // Load the cloud store.
        NSMutableDictionary *cloudStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                self.contentName, NSPersistentStoreUbiquitousContentNameKey,
                cloudStoreContentURL, NSPersistentStoreUbiquitousContentURLKey,
                @YES, NSMigratePersistentStoresAutomaticallyOption,
                @YES, NSInferMappingModelAutomaticallyOption,
                nil];
        NSMutableDictionary *migrationStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                @YES, NSReadOnlyPersistentStoreOption,
                nil];
        [cloudStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
        [migrationStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
        [self loadStoreAtURL:cloudStoreURL withOptions:cloudStoreOptions
         migratingStoreAtURL:migrationStoreURL withOptions:migrationStoreOptions usingStrategy:migrationStrategy
                       error:&error cause:&cause context:&context];
    }
    @finally {
        self.migrationStoreURL = nil;

        if (cause == UbiquityStoreErrorCauseNoError) {
            // Store loaded successfully.
            [self confirmTentativeStoreUUID];
            [self log:@"Cloud enabled and successfully loaded cloud store."];
        }
        else {
            // An error occurred in the @try block.
            [self resetTentativeStoreUUID];
            [self clearStore];

            if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)]) {
                [self log:@"Cloud enabled but failed to load cloud store (cause:%u, %@). Application will handle.", cause, context];
            } else {
                [self log:@"Cloud enabled but failed to load cloud store (cause:%u, %@). Handling with default strategy: falling back to local store.", cause, context];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (cause == UbiquityStoreErrorCauseNoError) {
                // Store loaded successfully.
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:)])
                    [self.delegate ubiquityStoreManager:self didLoadStoreForCoordinator:self.persistentStoreCoordinator isCloud:YES];

                [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification
                                                                    object:self userInfo:nil];
            } else if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)])
                // Store failed to load, inform delegate.
                [self.delegate ubiquityStoreManager:self failedLoadingStoreWithCause:cause context:context wasCloud:YES];
            else
                // Store failed to load, delegate doesn't care. Default strategy for cloud load failure: switch to local.
                self.cloudEnabled = NO;
        });
    }
}

- (void)loadLocalStore {

    [self log:@"Will load local store."];

    __block id context = nil;
    __block UbiquityStoreErrorCause cause = UbiquityStoreErrorCauseNoError;
    @try {
        [self clearStore];

        // Load local store if iCloud is disabled.
        __block NSError *error = nil;

        // Make sure local store directory exists.
        NSURL *localStoreURL = [self URLForLocalStore];
        NSURL *localStoreDirectoryURL = [self URLForLocalStoreDirectory];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:localStoreDirectoryURL.path
                                       withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self error:error cause:cause = UbiquityStoreErrorCauseCreateStorePath context:context = localStoreDirectoryURL.path];
            return;
        }

        // If the local store doesn't exist yet and a migrationStore is set, copy it.
        // Check if we need to seed the store by migrating another store into it.
        UbiquityStoreMigrationStrategy migrationStrategy = self.migrationStrategy;
        NSURL *migrationStoreURL = self.migrationStoreURL;
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.migrationStoreURL.path] ||
                [[NSFileManager defaultManager] fileExistsAtPath:localStoreURL.path])
            migrationStrategy = UbiquityStoreMigrationStrategyNone;

        // Load the local store.
        NSMutableDictionary *localStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                @YES, NSMigratePersistentStoresAutomaticallyOption,
                @YES, NSInferMappingModelAutomaticallyOption,
                nil];
        NSMutableDictionary *migrationStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                @YES, NSReadOnlyPersistentStoreOption,
                nil];
        if ([[self.migrationStoreURL URLByDeletingLastPathComponent].path
                isEqualToString:[self URLForCloudStoreDirectory].path])
            // Migration store is a cloud store.
            [migrationStoreOptions addEntriesFromDictionary:@{
                    NSPersistentStoreUbiquitousContentNameKey : self.contentName,
                    NSPersistentStoreUbiquitousContentURLKey : [self URLForCloudContent],
            }];
        [localStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
        [migrationStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
        [self loadStoreAtURL:localStoreURL withOptions:localStoreOptions
         migratingStoreAtURL:migrationStoreURL withOptions:migrationStoreOptions usingStrategy:migrationStrategy
                       error:&error cause:&cause context:&context];
    }
    @finally {
        self.migrationStoreURL = nil;

        if (cause == UbiquityStoreErrorCauseNoError) {
            // Store loaded successfully.
            [self log:@"Cloud disabled and successfully loaded local store."];
        }
        else {
            // An error occurred in the @try block.
            [self clearStore];

            if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)]) {
                [self log:@"Cloud disabled but failed to load local store (cause:%u, %@). Application will handle.", cause, context];
            } else {
                [self log:@"Cloud disabled but failed to load local store (cause:%u, %@). Handling with default strategy: no store available.", cause, context];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (cause == UbiquityStoreErrorCauseNoError) {
                // Store loaded successfully.
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:)])
                    [self.delegate ubiquityStoreManager:self didLoadStoreForCoordinator:self.persistentStoreCoordinator isCloud:NO];

                [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification
                                                                    object:self userInfo:nil];
            } else if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)])
                // Store failed to load, inform delegate.
                [self.delegate ubiquityStoreManager:self failedLoadingStoreWithCause:cause context:context wasCloud:NO];
        });
    }
}

- (void)loadStoreAtURL:(NSURL *)targetStoreURL withOptions:(NSMutableDictionary *)targetStoreOptions
   migratingStoreAtURL:(NSURL *)migrationStoreURL withOptions:(NSMutableDictionary *)migrationStoreOptions
         usingStrategy:(UbiquityStoreMigrationStrategy)migrationStrategy
                 error:(NSError **)error cause:(UbiquityStoreErrorCause *)cause context:(id *)context {

    @try {
        switch (migrationStrategy) {
            case UbiquityStoreMigrationStrategyCopyEntities: {
                [self log:@"Seeding store using strategy: UbiquityStoreMigrationStrategyCopyEntities"];
                NSAssert(migrationStoreURL, @"Cannot migrate: No migration store specified.");

                // Open migration and target store.
                NSPersistentStoreCoordinator *migrationCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
                __block NSPersistentStore *migrationStore = nil;
                [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:migrationStoreURL
                                                                                          options:(NSFileCoordinatorReadingOptions) 0
                                                                                            error:error byAccessor:^(NSURL *newURL) {
                    NSLog(@"Adding store: %@\nOptions: %@", newURL.path, migrationStoreOptions);
                    migrationStore = [migrationCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                        configuration:nil URL:newURL
                                                                              options:migrationStoreOptions
                                                                                error:error];
                }];
                if (!migrationStore) {
                    [self error:*error cause:*cause = UbiquityStoreErrorCauseOpenSeedStore context:*context = migrationStoreURL.path];
                    break;
                }

                NSPersistentStoreCoordinator *targetCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
                __block NSPersistentStore *targetStore = nil;
                [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:targetStoreURL
                                                                                          options:(NSFileCoordinatorReadingOptions) 0
                                                                                            error:error byAccessor:^(NSURL *newURL) {
                    NSLog(@"Adding store: %@\nOptions: %@", newURL.path, targetStoreOptions);
                    targetStore = [targetCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                  configuration:nil URL:newURL
                                                                        options:targetStoreOptions
                                                                          error:error];
                }];
                if (!targetStore) {
                    [self error:*error cause:*cause = UbiquityStoreErrorCauseOpenActiveStore context:*context = targetStoreURL.path];
                    break;
                }

                // Set up contexts for them.
                NSManagedObjectContext *migrationContext = [NSManagedObjectContext new];
                NSManagedObjectContext *targetContext = [NSManagedObjectContext new];
                migrationContext.persistentStoreCoordinator = migrationCoordinator;
                targetContext.persistentStoreCoordinator = targetCoordinator;

                // Migrate metadata.
                NSMutableDictionary *metadata = [[migrationCoordinator metadataForPersistentStore:migrationStore] mutableCopy];
                for (NSString *key in [[metadata allKeys] copy])
                    if ([key hasPrefix:@"com.apple.coredata.ubiquity"])
                        // Don't migrate ubiquitous metadata.
                        [metadata removeObjectForKey:key];
                [metadata addEntriesFromDictionary:[targetCoordinator metadataForPersistentStore:targetStore]];
                [targetCoordinator setMetadata:metadata forPersistentStore:targetStore];

                // Migrate entities.
                BOOL migrationFailure = NO;
                NSMutableDictionary *migratedIDsBySourceID = [[NSMutableDictionary alloc] initWithCapacity:500];
                for (NSEntityDescription *entity in self.model.entities) {
                    NSFetchRequest *fetch = [NSFetchRequest new];
                    fetch.entity = entity;
                    fetch.fetchBatchSize = 500;
                    fetch.relationshipKeyPathsForPrefetching = entity.relationshipsByName.allKeys;

                    NSArray *localObjects = [migrationContext executeFetchRequest:fetch error:error];
                    if (!localObjects) {
                        migrationFailure = YES;
                        break;
                    }

                    for (NSManagedObject *localObject in localObjects)
                        [self copyMigrateObject:localObject toContext:targetContext usingMigrationCache:migratedIDsBySourceID];
                }

                // Save migrated entities and unload the stores.
                if (!migrationFailure && ![targetContext save:error])
                    migrationFailure = YES;
                if (![migrationCoordinator removePersistentStore:migrationStore error:error])
                    [self error:*error cause:*cause = UbiquityStoreErrorCauseClearStore context:*context = migrationStore];
                if (![targetCoordinator removePersistentStore:targetStore error:error])
                    [self error:*error cause:*cause = UbiquityStoreErrorCauseClearStore context:*context = targetStore];

                // Handle failure by cleaning up the target store.
                if (migrationFailure) {
                    [self error:*error cause:*cause = UbiquityStoreErrorCauseSeedStore context:*context = migrationStoreURL.path];
                    [self removeItemAtURL:targetStoreURL localOnly:NO];
                    break;
                }

                // Migration is finished: load the store.
                [self loadStoreAtURL:targetStoreURL withOptions:targetStoreOptions
                 migratingStoreAtURL:nil withOptions:nil usingStrategy:UbiquityStoreMigrationStrategyNone
                               error:error cause:cause context:context];
                break;
            }

            case UbiquityStoreMigrationStrategyIOS: {
                [self log:@"Seeding store using strategy: UbiquityStoreMigrationStrategyIOS"];
                NSAssert(migrationStoreURL, @"Cannot migrate: No migration store specified.");

                [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:migrationStoreURL options:(NSFileCoordinatorReadingOptions) 0
                                                                                 writingItemAtURL:targetStoreURL options:NSFileCoordinatorWritingForMerging
                                                                                            error:error byAccessor:
                        ^(NSURL *newReadingURL, NSURL *newWritingURL) {
                            // Add the store to migrate.
                            NSLog(@"Adding store: %@\nOptions: %@", newReadingURL.path, migrationStoreOptions);
                            NSPersistentStore *migrationStore = [self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                                                              configuration:nil URL:newReadingURL
                                                                                                                    options:migrationStoreOptions
                                                                                                                      error:error];
                            if (!migrationStore)
                                [self error:*error cause:*cause = UbiquityStoreErrorCauseOpenSeedStore context:*context = migrationStoreURL.path];

                            else {
                                NSLog(@"Adding store: %@\nOptions: %@", newWritingURL.path, targetStoreOptions);
                                if (![self.persistentStoreCoordinator migratePersistentStore:migrationStore
                                                                                        toURL:newWritingURL
                                                                                      options:targetStoreOptions
                                                                                     withType:NSSQLiteStoreType
                                                                                        error:error])
                                [self error:*error cause:*cause = UbiquityStoreErrorCauseSeedStore context:*context = migrationStoreURL.path];
                            }
                        }];
                break;
            }

            case UbiquityStoreMigrationStrategyManual: {
                [self log:@"Seeding store using strategy: UbiquityStoreMigrationStrategyManual"];
                NSAssert(migrationStoreURL, @"Cannot migrate: No migration store specified.");

                // Instruct the delegate to migrate the migration store to the target store.
                if (![self.delegate ubiquityStoreManager:self
                                    manuallyMigrateStore:migrationStoreURL withOptions:migrationStoreOptions
                                                 toStore:targetStoreURL withOptions:targetStoreOptions error:error]) {
                    // Handle failure by cleaning up the target store.
                    [self error:*error cause:*cause = UbiquityStoreErrorCauseSeedStore context:*context = migrationStoreURL.path];
                    [self removeItemAtURL:targetStoreURL localOnly:NO];
                    break;
                }

                // Migration is finished: load the target store.
                [self loadStoreAtURL:targetStoreURL withOptions:targetStoreOptions
                 migratingStoreAtURL:nil withOptions:nil usingStrategy:UbiquityStoreMigrationStrategyNone
                               error:error cause:cause context:context];
                break;
            }

            case UbiquityStoreMigrationStrategyNone: {
                [self log:@"Loading store without seeding."];
                NSAssert([self.persistentStoreCoordinator.persistentStores count] == 0, @"PSC should have no stores before trying to load one.");

                // Load the target store.
                [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:targetStoreURL
                                                                                          options:(NSFileCoordinatorReadingOptions) 0
                                                                                            error:error byAccessor:^(NSURL *newURL) {
                    NSLog(@"Adding store: %@\nOptions: %@", newURL.path, targetStoreOptions);
                    [self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                  configuration:nil URL:newURL
                                                                        options:targetStoreOptions
                                                                          error:error];
                }];
                if (![self.persistentStoreCoordinator.persistentStores count])
                    [self error:*error cause:*cause = UbiquityStoreErrorCauseOpenActiveStore context:*context = targetStoreURL.path];
                break;
            }
        }
    }
    @catch (id exception) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:2];
        if (exception)
            [userInfo setObject:[exception description] forKey:NSLocalizedFailureReasonErrorKey];
        if (*error)
            [userInfo setObject:*error forKey:NSUnderlyingErrorKey];
        [self error:*error = [NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:userInfo]
              cause:*cause = UbiquityStoreErrorCauseSeedStore context:*context = exception];
    }
}

- (id)copyMigrateObject:(NSManagedObject *)sourceObject toContext:(NSManagedObjectContext *)destinationContext usingMigrationCache:(NSMutableDictionary *)migratedIDsBySourceID {

    if (!sourceObject)
        return nil;

    NSManagedObjectID *destinationObjectID = [migratedIDsBySourceID objectForKey:sourceObject.objectID];
    if (destinationObjectID)
        return [destinationContext objectWithID:destinationObjectID];

    @autoreleasepool {
        // Create migrated object.
        NSEntityDescription *entity = sourceObject.entity;
        NSManagedObject *destinationObject = [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:destinationContext];
        [migratedIDsBySourceID setObject:destinationObject.objectID forKey:sourceObject.objectID];

        // Set attributes
        for (NSString *key in entity.attributesByName.allKeys)
            [destinationObject setPrimitiveValue:[sourceObject primitiveValueForKey:key] forKey:key];

        // Set relationships recursively
        for (NSRelationshipDescription *relationDescription in entity.relationshipsByName.allValues) {
            NSString *key = relationDescription.name;
            id value = nil;

            if (relationDescription.isToMany) {
                value = [[destinationObject primitiveValueForKey:key] mutableCopy];

                for (NSManagedObject *element in [sourceObject primitiveValueForKey:key])
                    [value addObject:[self copyMigrateObject:element toContext:destinationContext usingMigrationCache:migratedIDsBySourceID]];
            }
            else
                value = [self copyMigrateObject:[sourceObject primitiveValueForKey:key] toContext:destinationContext usingMigrationCache:migratedIDsBySourceID];

            [destinationObject setPrimitiveValue:value forKey:key];
        }

        return destinationObject;
    }
}


- (BOOL)cloudSafeForSeeding {

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    [cloud synchronize];
    
    if ([cloud objectForKey:StoreUUIDKey])
        // Migration is only safe when there is no storeUUID yet (the store is not in the cloud yet).
        return NO;

    if ([[NSFileManager defaultManager] fileExistsAtPath:[self URLForCloudStore].path])
        // Migration is only safe when the cloud store does not yet exist.
        return NO;

    return YES;
}

- (void)removeItemAtURL:(NSURL *)directoryURL localOnly:(BOOL)localOnly {

    NSError *error = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateWritingItemAtURL:directoryURL
                                                                              options:NSFileCoordinatorWritingForDeleting
                                                                                error:&error byAccessor:
     ^(NSURL *newURL) {
         NSError *error_ = nil;
         if (localOnly && [[NSFileManager defaultManager] isUbiquitousItemAtURL:newURL]) {
             if (![[NSFileManager defaultManager] evictUbiquitousItemAtURL:newURL error:&error_])
                 [self error:error_ cause:UbiquityStoreErrorCauseDeleteStore context:newURL.path];
         } else {
             if (![[NSFileManager defaultManager] removeItemAtURL:newURL error:&error_])
                 [self error:error_ cause:UbiquityStoreErrorCauseDeleteStore context:newURL.path];
         }
     }];
    if (error)
        [self error:error cause:UbiquityStoreErrorCauseDeleteStore context:directoryURL.path];
}

- (void)deleteCloudContainerLocalOnly:(BOOL)localOnly {
    
    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will delete the cloud container %@.", localOnly ? @"on this device" : @"on this device and in the cloud"];

        if (self.cloudEnabled)
            [self clearStore];

        // Delete the whole cloud container.
        [self removeItemAtURL:[self URLForCloudContainer] localOnly:localOnly];

        // Unset the storeUUID so a new one will be created.
        [self resetTentativeStoreUUID];
        if (!localOnly) {
            NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
            [cloud synchronize];
            for (id key in [[cloud dictionaryRepresentation] allKeys])
                [cloud removeObjectForKey:key];
            [cloud synchronize];
        }

        if (self.cloudEnabled)
            [self loadStore];
    }];
}

- (void)deleteCloudStoreLocalOnly:(BOOL)localOnly {

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will delete the cloud store (UUID:%@) %@.", self.storeUUID, localOnly ? @"on this device" : @"on this device and in the cloud"];

        if (self.cloudEnabled)
            [self clearStore];

        // Clean up any cloud stores and transaction logs.
        [self removeItemAtURL:[self URLForCloudStore] localOnly:localOnly];
        [self removeItemAtURL:[self URLForCloudContent] localOnly:localOnly];

        // Unset the storeUUID so a new one will be created.
        [self resetTentativeStoreUUID];
        if (!localOnly) {
            NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
            [cloud removeObjectForKey:StoreCorruptedKey];
            [cloud removeObjectForKey:StoreUUIDKey];
            [cloud synchronize];
        }

        if (self.cloudEnabled)
            [self loadStore];
    }];
}

- (void)deleteLocalStore {

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will delete the local store."];

        if (!self.cloudEnabled)
            [self clearStore];

        // Remove just the local store.
        [self removeItemAtURL:[self URLForLocalStore] localOnly:YES];

        if (!self.cloudEnabled)
            [self loadStore];
    }];
}

- (void)migrateCloudToLocalAndDeleteCloudStoreLocalOnly:(BOOL)localOnly {

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will overwrite the local store with the cloud store."];

        [self clearStore];

        self.migrationStoreURL = [self URLForCloudStore];
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.migrationStoreURL.path]) {
            [self log:@"Cannot migrate cloud to local: Cloud store doesn't exist."];
            self.migrationStoreURL = nil;
        }

        [self deleteLocalStore];
        self.cloudEnabled = NO;
        [self deleteCloudStoreLocalOnly:localOnly];
    }];
}

- (void)rebuildCloudContentFromCloudStore {

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will rebuild cloud content from the cloud store."];

        [self clearStore];

        NSURL *cloudStoreURL = [self URLForCloudStore];
        if (![[NSFileManager defaultManager] fileExistsAtPath:cloudStoreURL.path]) {
            [self log:@"Cannot rebuild cloud content: Cloud store doesn't exist."];
        }
        else {
            __block BOOL success = NO;
            __block NSError *error = nil;
            self.migrationStoreURL = [[self URLForCloudStoreDirectory] URLByAppendingPathComponent:CloudStoreMigrationSource isDirectory:NO];
            [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:cloudStoreURL options:(NSFileCoordinatorReadingOptions) 0
                                                                             writingItemAtURL:self.migrationStoreURL options:NSFileCoordinatorWritingForReplacing
                                                                                        error:&error byAccessor:
                    ^(NSURL *newReadingURL, NSURL *newWritingURL) {
                        success = [[NSFileManager defaultManager] moveItemAtURL:newReadingURL toURL:newWritingURL error :&error];
                    }];
            if (!success) {
                [self error:error cause:UbiquityStoreErrorCauseSeedStore context:self.migrationStoreURL.path];
                return;
            }
        }

        [self deleteCloudStoreLocalOnly:NO];
        self.cloudEnabled = YES;
    }];
}

#pragma mark - Properties

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
    [cloud synchronize];
    NSString *storeUUID = [cloud objectForKey:StoreUUIDKey];

    // If no storeUUID is set yet, create a new storeUUID and return that as long as no storeUUID is set yet.
    // When the migration to the new storeUUID is successful, we update the iCloud's KVS with a call to -setStoreUUID.
    if (!storeUUID) {
        if (!self.tentativeStoreUUID)
            self.tentativeStoreUUID = [[NSUUID UUID] UUIDString];
        storeUUID = self.tentativeStoreUUID;
    }

    return storeUUID;
}

/**
 * When a tentativeStoreUUID is set, this operation confirms it and writes it as the new storeUUID to the iCloud KVS.
 */
- (void)confirmTentativeStoreUUID {

    if (self.tentativeStoreUUID) {
        NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
        [cloud setObject:self.tentativeStoreUUID forKey:StoreUUIDKey];
        [cloud synchronize];

        [self resetTentativeStoreUUID];
    }
}

/**
 * When a tentativeStoreUUID is set, this operation resets it so that a new one will be generated if necessary.
 */
- (void)resetTentativeStoreUUID {

    self.tentativeStoreUUID = nil;
}

#pragma mark - NSFilePresenter

- (NSURL *)presentedItemURL {

    if (self.cloudEnabled)
        return [self URLForCloudContent];

    return [self URLForLocalStore];
}

-(NSOperationQueue *)presentedItemOperationQueue {

    return _presentedItemOperationQueue;
}

- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler {

    [self clearStore];
    completionHandler(nil);
}


#pragma mark - Notifications

- (void)applicationDidBecomeActive:(NSNotification *)note {

    // Check for iCloud identity changes (ie. user logs into another iCloud account).
    if (![self.currentIdentityToken isEqual:[[NSFileManager defaultManager] ubiquityIdentityToken]])
        [self cloudStoreChanged:nil];
}

- (void)applicationWillEnterForeground:(NSNotification *)note {

    [self loadStore];
}

- (void)applicationDidEnterBackground:(NSNotification *)note {

    [self clearStore];
}

- (void)applicationWillTerminate:(NSNotification *)note {

    [self clearStore];
}

- (void)keyValueStoreChanged:(NSNotification *)note {

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    [cloud synchronize];

    NSArray *changedKeys = (NSArray *)[note.userInfo objectForKey:NSUbiquitousKeyValueStoreChangedKeysKey];
    if ([changedKeys containsObject:StoreUUIDKey]) {
        // The UUID of the active store changed.  We need to switch to the newly activated store.
        [self log:@"StoreUUID changed (reason: %@) to: %@",
                  [note.userInfo objectForKey:NSUbiquitousKeyValueStoreChangeReasonKey],
                  [cloud objectForKey:StoreUUIDKey]];
        [self cloudStoreChanged:nil];
    }

    if ([changedKeys containsObject:StoreCorruptedKey])
        // Cloud content corruption was detected or cleared.
        if (![self checkCloudContentCorruption:nil])
            if (self.cloudEnabled && ![self.persistentStoreCoordinator.persistentStores count])
                // Corruption was removed and our cloud store is not yet loaded.  Try loading the store again.
                [self loadStore];
}

/**
* Triggered when:
* 1. Loading a cloud store.
* 2. StoreCorruptedKey changes are imported to the cloud KVS.
* 3. An NSError is created describing a transaction log import failure (UbiquityManagedStoreDidDetectCorruptionNotification).
*/
- (BOOL)checkCloudContentCorruption:(NSNotification *)note {

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    [cloud synchronize];
    
    if (![cloud boolForKey:StoreCorruptedKey])
        return NO;

    // Cloud content corruption detected.
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:handleCloudContentCorruptionIsCloud:)]) {
        [self log:@"Cloud content corruption detected.  Application will handle."];
        [self.delegate ubiquityStoreManager:self handleCloudContentCorruptionIsCloud:self.cloudEnabled];

        if (self.cloudEnabled)
            // Since the cloud content is corrupt, we must unload the cloud store to prevent
            // unsyncable changes from being made.
            [self clearStore];
    } else {
        // Default strategy for corrupt cloud content: switch to local.
        [self log:@"Cloud content corruption detected.  Handling with default strategy: Falling back to local store."];
        self.cloudEnabled = NO;
    }

    return YES;
}

/**
 * Triggered when:
 * 1. Ubiquity identity changed (NSUbiquityIdentityDidChangeNotification).
 * 2. Store file was deleted (eg. iCloud container deleted in settings).
 * 3. StoreUUID changed (eg. switched to a new cloud store on another device).
 */
- (void)cloudStoreChanged:(NSNotification *)note {

    // Update the identity token in case it changed.
    self.currentIdentityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];

    // Don't reload the store when the local one is active.
    if (!self.cloudEnabled)
        return;

    // Reload the store.
    [self log:@"Cloud store changed.  StoreUUID: %@ (%@), Identity: %@",
                    self.storeUUID, _tentativeStoreUUID ? @"tentative" : @"definite", self.currentIdentityToken];
    [self loadStore];
}

- (void)mergeChanges:(NSNotification *)note {

    [self.persistentStorageQueue addOperationWithBlock:^{
        NSManagedObjectContext *moc = nil;
        if ([self.delegate respondsToSelector:@selector(managedObjectContextForUbiquityChangesInManager:)])
            moc = [self.delegate managedObjectContextForUbiquityChangesInManager:self];
        if (moc)
            [self log:@"Importing ubiquity changes into application's MOC.  Changes:\n%@", note.userInfo];
        else {
            [self log:@"Importing ubiquity changes with default strategy: into persistence store.  Changes:\n%@", note.userInfo];
            moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
            moc.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
            moc.persistentStoreCoordinator = self.persistentStoreCoordinator;
        }

        [moc performBlockAndWait:^{
            [moc mergeChangesFromContextDidSaveNotification:note];

            NSError *error = nil;
            if (![moc save:&error]) {
                [self error:error cause:UbiquityStoreErrorCauseImportChanges context:note];

                // Try to reload the store to see if it's still viable.
                // If not, either the application will handle it or we'll fall back to the local store.
                // TODO: Verify that this works reliably.
                [self loadStore];
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidImportChangesNotification
                                                                    object:self userInfo:[note userInfo]];
            });
        }];
    }];
}

@end
