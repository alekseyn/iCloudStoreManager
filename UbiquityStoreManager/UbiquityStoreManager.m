/**
 * Copyright Maarten Billemont (http://www.lhunath.com, lhunath@lyndir.com)
 *
 * See the enclosed file LICENSE for license information (LGPLv3). If you did
 * not receive this file, see http://www.gnu.org/licenses/lgpl-3.0.txt
 *
 * @author   Maarten Billemont <lhunath@lyndir.com>
 * @license  http://www.gnu.org/licenses/lgpl-3.0.txt
 */

//
//  UbiquityStoreManager.m
//  UbiquityStoreManager
//
//  Created by Maarten Billemont on 05/11/09.
//

#import "UbiquityStoreManager.h"
#import "JRSwizzle.h"
#import "NSError+UbiquityStoreManager.h"


NSString *const UbiquityManagedStoreDidChangeNotification = @"UbiquityManagedStoreDidChangeNotification";
NSString *const UbiquityManagedStoreDidImportChangesNotification = @"UbiquityManagedStoreDidImportChangesNotification";
NSString *const CloudEnabledKey = @"USMCloudEnabledKey"; // local: Whether the user wants the app on this device to use iCloud.
NSString *const StoreUUIDKey = @"USMStoreUUIDKey"; // cloud: The UUID of the active cloud store.
NSString *const StoreContentCorruptedKey = @"USMStoreCorruptedKey"; // cloud: Set to YES when a cloud content corruption has been detected.
NSString *const CloudStoreDirectory = @"CloudStore.nosync";
NSString *const CloudStoreMigrationSource = @"MigrationSource.sqlite";
NSString *const CloudContentDirectory = @"CloudLogs";

@interface UbiquityStoreManager()<NSFilePresenter>

@property(nonatomic, copy) NSString *contentName;
@property(nonatomic, strong) NSManagedObjectModel *model;
@property(nonatomic, copy) NSURL *localStoreURL;
@property(nonatomic, copy) NSString *containerIdentifier;
@property(nonatomic, copy) NSDictionary *additionalStoreOptions;
@property(nonatomic, readonly) NSString *storeUUID;
@property(nonatomic, strong) NSString *tentativeStoreUUID;
@property(nonatomic, strong) NSOperationQueue *persistentStorageQueue;
@property(nonatomic, readonly) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property(nonatomic, strong) id<NSObject, NSCopying, NSCoding> currentIdentityToken;
@property(nonatomic, strong) NSURL *migrationStoreURL;
@property(nonatomic) BOOL attemptingCloudRecovery;
@property(nonatomic) NSString *cloudStoreCorruptUUID;
@property(nonatomic) BOOL cloudStoreLoaded;
@end

@implementation UbiquityStoreManager {
    NSPersistentStoreCoordinator *_persistentStoreCoordinator;
    NSOperationQueue *_presentedItemOperationQueue;
}

+ (void)initialize {

    if (![self respondsToSelector:@selector(jr_swizzleMethod:withMethod:error:)]) {
        NSLog( @"UbiquityStoreManager: Warning: JRSwizzle not present, won't be able to detect desync issues." );
        return;
    }

    NSError *error = nil;
    if (![NSError jr_swizzleMethod:@selector(initWithDomain:code:userInfo:)
                        withMethod:@selector(init_USM_WithDomain:code:userInfo:)
                             error:&error])
        NSLog( @"UbiquityStoreManager: Warning: Failed to swizzle, won't be able to detect desync issues.  Cause: %@", error );
}

- (id)initStoreNamed:(NSString *)contentName withManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL
 containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions
            delegate:(id<UbiquityStoreManagerDelegate>)delegate {

    if (!(self = [super init]))
        return nil;

    // Parameters.
    _delegate = delegate;
    _contentName = contentName == nil? @"UbiquityStore": contentName;
    _model = model == nil? [NSManagedObjectModel mergedModelFromBundles:nil]: model;
    if (!localStoreURL)
        localStoreURL = [[[self URLForApplicationContainer]
                URLByAppendingPathComponent:self.contentName isDirectory:NO]
                URLByAppendingPathExtension:@"sqlite"];
    _localStoreURL = localStoreURL;
    _containerIdentifier = containerIdentifier;
    _additionalStoreOptions = additionalStoreOptions == nil? [NSDictionary dictionary]: additionalStoreOptions;

    // Private vars.
    _currentIdentityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];
    _migrationStrategy = UbiquityStoreMigrationStrategyCopyEntities;
    _persistentStorageQueue = [NSOperationQueue new];
    _persistentStorageQueue.name = [NSString stringWithFormat:@"%@PersistenceQueue", NSStringFromClass( [self class] )];
    _persistentStorageQueue.maxConcurrentOperationCount = 1;
    _presentedItemOperationQueue = [NSOperationQueue new];
    _presentedItemOperationQueue.name = [NSString stringWithFormat:@"%@PresenterQueue", NSStringFromClass( [self class] )];

    // Observe application events.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyValueStoreChanged:)
                                                 name:NSUbiquitousKeyValueStoreDidChangeExternallyNotification
                                               object:[NSUbiquitousKeyValueStore defaultStore]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cloudStoreChanged:)
                                                 name:NSUbiquityIdentityDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ubiquityStoreManagerDidDetectCorruption:)
                                                 name:UbiquityManagedStoreDidDetectCorruptionNotification
                                               object:nil];
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
//    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:)
//                                                 name:UIApplicationWillEnterForegroundNotification
//                                               object:nil];
//    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:)
//                                                 name:UIApplicationDidEnterBackgroundNotification
//                                               object:nil];
//    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:)
//                                                 name:UIApplicationWillTerminateNotification
//                                               object:nil];
#else
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];
#endif

    [self reloadStore];

    return self;
}

- (void)dealloc {

    [NSFileCoordinator removeFilePresenter:self];
    [self.persistentStorageQueue addOperations:@[
            [NSBlockOperation blockOperationWithBlock:^{
                [self.persistentStoreCoordinator tryLock];
                [self clearStore];
                [self.persistentStoreCoordinator unlock];
            }]
    ]                        waitUntilFinished:YES];
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
    return [[[self URLForCloudStoreDirectory] URLByAppendingPathComponent:self.storeUUID isDirectory:NO]
            URLByAppendingPathExtension:@"sqlite"];
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
        NSLog( @"UbiquityStoreManager: %@", message );
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

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Persistence coordinator should only be accessed from the persistence queue.");

    if (!_persistentStoreCoordinator) {
        _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mergeChanges:)
                                                     name:NSPersistentStoreDidImportUbiquitousContentChangesNotification
                                                   object:_persistentStoreCoordinator];
    }

    return _persistentStoreCoordinator;
}

- (void)resetPersistentStoreCoordinator {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Persistence coordinator should only be modified from the persistence queue.");

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

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Store should only be cleared from the persistence queue.");

    [self log:@"Clearing stores..."];
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:willLoadStoreIsCloud:)])
        [self.delegate ubiquityStoreManager:self willLoadStoreIsCloud:self.cloudEnabled];

    // Remove the store from the coordinator.
    self.cloudStoreLoaded = NO;
    [NSFileCoordinator removeFilePresenter:self];
    NSError *error = nil;
    for (NSPersistentStore *store in self.persistentStoreCoordinator.persistentStores)
        if (![self.persistentStoreCoordinator removePersistentStore:store error:&error])
            [self error:error cause:UbiquityStoreErrorCauseClearStore context:store];

    if ([self.persistentStoreCoordinator.persistentStores count])
            // We couldn't remove all the stores, make a new PSC instead.
        [self resetPersistentStoreCoordinator];

    dispatch_async( dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification
                                                            object:self userInfo:nil];
    } );
}

- (void)reloadStore {

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
        }
        @finally {
            [self.persistentStoreCoordinator unlock];
        }
    }];
}

- (void)loadCloudStore {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Active store should only be changed from the persistence queue.");

    [self log:@"Will load cloud store: %@ (%@).", self.storeUUID, _tentativeStoreUUID? @"tentative": @"definite"];

    // Mark store as healthy: opening the store now will tell us whether it's still corrupt.
    self.cloudStoreLoaded = NO;

    id context = nil;
    NSError *error = nil;
    UbiquityStoreErrorCause cause = UbiquityStoreErrorCauseNoError;
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
            [self removeItemAtURL:cloudStoreURL localOnly:NO];
        }

        // Check if we need to seed the store by migrating another store into it.
        UbiquityStoreMigrationStrategy migrationStrategy = self.migrationStrategy;
        NSURL *migrationStoreURL = self.migrationStoreURL? self.migrationStoreURL: [self localStoreURL];
        if (![self cloudSafeForSeeding] || ![[NSFileManager defaultManager] fileExistsAtPath:migrationStoreURL.path])
            migrationStrategy = UbiquityStoreMigrationStrategyNone;

        // Load the cloud store.
        NSMutableDictionary *cloudStoreOptions = [@{
                NSPersistentStoreUbiquitousContentNameKey    : self.contentName,
                NSPersistentStoreUbiquitousContentURLKey     : cloudStoreContentURL,
                NSMigratePersistentStoresAutomaticallyOption : @YES,
                NSInferMappingModelAutomaticallyOption       : @YES,
        } mutableCopy];
        NSMutableDictionary *migrationStoreOptions = [@{
                NSReadOnlyPersistentStoreOption : @YES,
        } mutableCopy];
        [cloudStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
        [migrationStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
        [self loadStoreAtURL:cloudStoreURL withOptions:cloudStoreOptions
         migratingStoreAtURL:migrationStoreURL withOptions:migrationStoreOptions usingStrategy:migrationStrategy
                       cause:&cause context:&context];
    }
    @finally {
        BOOL wasExplicitMigration = self.migrationStoreURL != nil;
        self.migrationStoreURL = nil;

        if (cause == UbiquityStoreErrorCauseNoError) {
            // Store loaded successfully.
            [self confirmTentativeStoreUUID];
            self.cloudStoreLoaded = YES;
            self.attemptingCloudRecovery = NO;
            [NSFileCoordinator addFilePresenter:self];

            [self log:@"Cloud enabled and successfully loaded cloud store."];

            // Give it some "time" to import any incoming transaction logs. This is important:
            // 1. To see if this store is a healthy candidate for content corruption rebuild.
            // 2. To make sure our store is up-to-date before we destroy the cloud content and rebuild it from the store.
            dispatch_after( dispatch_time( DISPATCH_TIME_NOW, NSEC_PER_SEC * 30 ),
                    dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0 ), ^{
                        [self.persistentStorageQueue addOperationWithBlock:^{
                            if (![self.cloudStoreCorruptUUID isEqualToString:self.storeUUID])
                                [self handleCloudContentCorruption];
                        }];
                    } );
        }
        else {
            // An error occurred in the @try block.
            [self unsetTentativeStoreUUID];
            [self clearStore];

            // If we were performing explicit migration, try without in case the problem was caused by the migration store.
            if (wasExplicitMigration) {
                [self log:@"Cloud enabled but failed to load cloud store. Was performing explicit migration; will try without. (cause:%u, %@)",
                          cause, context];
                [self reloadStore];
                return;
            }

            // If we haven't attempted recovery yet (ie. delete the local store), try that first.
            if (!self.attemptingCloudRecovery) {
                [self log:@"Cloud enabled but failed to load cloud store. Attempting recovery by rebuilding from cloud content. (cause:%u, %@)",
                          cause, context];
                self.attemptingCloudRecovery = YES;
                [self deleteCloudStoreLocalOnly:YES];
                return;
            }
            self.attemptingCloudRecovery = NO;

            // Failed to load regardless of recovery attempt.  Mark store as corrupt.
            [self log:@"Cloud enabled but failed to load cloud store. Marking cloud store as corrupt. Store will be unavailable. (cause:%u, %@)",
                      cause, context];
            [self markCloudStoreCorrupted];
        }

        NSPersistentStoreCoordinator *psc = self.persistentStoreCoordinator;
        dispatch_async( dispatch_get_main_queue(), ^{
            if (cause == UbiquityStoreErrorCauseNoError) {
                // Store loaded successfully.
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:)])
                    [self.delegate ubiquityStoreManager:self didLoadStoreForCoordinator:psc isCloud:YES];

                [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification
                                                                    object:self userInfo:nil];
            }
            else {
                // Store failed to load, inform delegate.
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)])
                    [self.delegate ubiquityStoreManager:self failedLoadingStoreWithCause:cause context:context wasCloud:YES];
            }
        } );
    }
}

- (void)loadLocalStore {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Active store should only be changed from the persistence queue.");

    [self log:@"Will load local store."];

    id context = nil;
    NSError *error = nil;
    UbiquityStoreErrorCause cause = UbiquityStoreErrorCauseNoError;
    @try {
        [self clearStore];

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
        NSMutableDictionary *localStoreOptions = [@{
                NSMigratePersistentStoresAutomaticallyOption : @YES,
                NSInferMappingModelAutomaticallyOption       : @YES
        } mutableCopy];
        NSMutableDictionary *migrationStoreOptions = [@{
                NSReadOnlyPersistentStoreOption : @YES
        } mutableCopy];
        if ([[self.migrationStoreURL URLByDeletingLastPathComponent].path
                isEqualToString:[self URLForCloudStoreDirectory].path])
                // Migration store is a cloud store.
            [migrationStoreOptions addEntriesFromDictionary:@{
                    NSPersistentStoreUbiquitousContentNameKey : self.contentName,
                    NSPersistentStoreUbiquitousContentURLKey  : [self URLForCloudContent],
            }];
        [localStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
        [migrationStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
        [self loadStoreAtURL:localStoreURL withOptions:localStoreOptions
         migratingStoreAtURL:migrationStoreURL withOptions:migrationStoreOptions usingStrategy:migrationStrategy
                       cause:&cause context:&context];
    }
    @finally {
        BOOL wasExplicitMigration = self.migrationStoreURL != nil;
        self.migrationStoreURL = nil;

        if (cause == UbiquityStoreErrorCauseNoError) {
            // Store loaded successfully.
            [NSFileCoordinator addFilePresenter:self];

            [self log:@"Cloud disabled and successfully loaded local store."];
        }
        else {
            // An error occurred in the @try block.
            [self clearStore];

            // If we were performing explicit migration, try without in case the problem was caused by the migration store.
            if (wasExplicitMigration) {
                [self log:@"Cloud disabled but failed to load local store. Was performing explicit migration; will try without. (cause:%u, %@)",
                          cause, context];
                [self reloadStore];
                return;
            }

            [self log:@"Cloud disabled but failed to load local store.  Store will be unavailable. (cause:%u, %@)", cause, context];
        }

        NSPersistentStoreCoordinator *psc = self.persistentStoreCoordinator;
        dispatch_async( dispatch_get_main_queue(), ^{
            if (cause == UbiquityStoreErrorCauseNoError) {
                // Store loaded successfully.
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:)]) {
                    [self.delegate ubiquityStoreManager:self didLoadStoreForCoordinator:psc isCloud:NO];
                }

                [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification
                                                                    object:self userInfo:nil];
            }
            else if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)])
                    // Store failed to load, inform delegate.
                [self.delegate ubiquityStoreManager:self failedLoadingStoreWithCause:cause context:context wasCloud:NO];
        } );
    }
}

- (void)loadStoreAtURL:(NSURL *)targetStoreURL withOptions:(NSMutableDictionary *)targetStoreOptions
   migratingStoreAtURL:(NSURL *)migrationStoreURL withOptions:(NSMutableDictionary *)migrationStoreOptions
         usingStrategy:(UbiquityStoreMigrationStrategy)migrationStrategy
                 cause:(UbiquityStoreErrorCause *)cause context:(id *)context {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Active store should only be changed from the persistence queue.");

    NSError *error = nil;
    __block NSError *error_ = nil;
    @try {
        switch (migrationStrategy) {
            case UbiquityStoreMigrationStrategyCopyEntities: {
                [self log:@"Seeding store using strategy: UbiquityStoreMigrationStrategyCopyEntities"];
                NSAssert(migrationStoreURL, @"Cannot migrate: No migration store specified.");

                // Open migration and target store.
                NSPersistentStoreCoordinator *migrationCoordinator =
                        [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
                __block NSPersistentStore *migrationStore = nil;
                [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:migrationStoreURL
                                                                                          options:(NSFileCoordinatorReadingOptions)0
                                                                                            error:&error byAccessor:^(NSURL *newURL) {
                    migrationStore = [migrationCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                        configuration:nil URL:newURL
                                                                              options:migrationStoreOptions
                                                                                error:&error_];
                }];
                if (!migrationStore) {
                    [self error:error_? error_: error cause:*cause = UbiquityStoreErrorCauseOpenSeedStore
                        context:*context = migrationStoreURL.path];
                    break;
                }

                NSPersistentStoreCoordinator *targetCoordinator =
                        [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
                __block NSPersistentStore *targetStore = nil;
                [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:targetStoreURL
                                                                                          options:(NSFileCoordinatorReadingOptions)0
                                                                                            error:&error byAccessor:^(NSURL *newURL) {
                    targetStore = [targetCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                  configuration:nil URL:newURL
                                                                        options:targetStoreOptions
                                                                          error:&error_];
                }];
                if (!targetStore) {
                    [self error:error_? error_: error cause:*cause = UbiquityStoreErrorCauseOpenActiveStore
                        context:*context = targetStoreURL.path];
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

                    NSArray *localObjects = [migrationContext executeFetchRequest:fetch error:&error];
                    if (!localObjects) {
                        migrationFailure = YES;
                        break;
                    }

                    for (NSManagedObject *localObject in localObjects)
                        [self copyMigrateObject:localObject toContext:targetContext usingMigrationCache:migratedIDsBySourceID];
                }

                // Save migrated entities and unload the stores.
                if (!migrationFailure && ![targetContext save:&error])
                    migrationFailure = YES;
                if (![migrationCoordinator removePersistentStore:migrationStore error:&error_])
                    [self error:error_ cause:*cause = UbiquityStoreErrorCauseClearStore context:*context = migrationStore];
                if (![targetCoordinator removePersistentStore:targetStore error:&error_])
                    [self error:error_ cause:*cause = UbiquityStoreErrorCauseClearStore context:*context = targetStore];

                // Handle failure by cleaning up the target store.
                if (migrationFailure) {
                    [self error:error cause:*cause = UbiquityStoreErrorCauseSeedStore context:*context = migrationStoreURL.path];
                    [self removeItemAtURL:targetStoreURL localOnly:NO];
                    break;
                }

                // Migration is finished: load the store.
                [self loadStoreAtURL:targetStoreURL withOptions:targetStoreOptions
                 migratingStoreAtURL:nil withOptions:nil usingStrategy:UbiquityStoreMigrationStrategyNone
                               cause:cause context:context];
                break;
            }

            case UbiquityStoreMigrationStrategyIOS: {
                [self log:@"Seeding store using strategy: UbiquityStoreMigrationStrategyIOS"];
                NSAssert(migrationStoreURL, @"Cannot migrate: No migration store specified.");

                [[[NSFileCoordinator alloc] initWithFilePresenter:nil]
                        coordinateReadingItemAtURL:migrationStoreURL options:(NSFileCoordinatorReadingOptions)0
                                  writingItemAtURL:targetStoreURL options:NSFileCoordinatorWritingForMerging
                                             error:&error byAccessor:
                        ^(NSURL *newReadingURL, NSURL *newWritingURL) {
                            // Add the store to migrate.
                            NSPersistentStore *migrationStore =
                                    [self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                                  configuration:nil URL:newReadingURL
                                                                                        options:migrationStoreOptions
                                                                                          error:&error_];
                            if (!migrationStore)
                                [self error:error_ cause:*cause = UbiquityStoreErrorCauseOpenSeedStore
                                    context:*context = newReadingURL.path];

                            else if (![self.persistentStoreCoordinator migratePersistentStore:migrationStore
                                                                                        toURL:newWritingURL
                                                                                      options:targetStoreOptions
                                                                                     withType:NSSQLiteStoreType
                                                                                        error:&error_])
                                [self error:error_ cause:*cause = UbiquityStoreErrorCauseSeedStore context:*context = newWritingURL.path];
                            else
                                *cause = UbiquityStoreErrorCauseNoError;
                        }];
                if (error)
                    [self error:error cause:UbiquityStoreErrorCauseOpenSeedStore context:migrationStoreURL.path];
                break;
            }

            case UbiquityStoreMigrationStrategyManual: {
                [self log:@"Seeding store using strategy: UbiquityStoreMigrationStrategyManual"];
                NSAssert(migrationStoreURL, @"Cannot migrate: No migration store specified.");

                // Instruct the delegate to migrate the migration store to the target store.
                if (![self.delegate ubiquityStoreManager:self
                                    manuallyMigrateStore:migrationStoreURL withOptions:migrationStoreOptions
                                                 toStore:targetStoreURL withOptions:targetStoreOptions error:&error]) {
                    // Handle failure by cleaning up the target store.
                    [self error:error cause:*cause = UbiquityStoreErrorCauseSeedStore context:*context = migrationStoreURL.path];
                    [self removeItemAtURL:targetStoreURL localOnly:NO];
                    break;
                }

                // Migration is finished: load the target store.
                [self loadStoreAtURL:targetStoreURL withOptions:targetStoreOptions
                 migratingStoreAtURL:nil withOptions:nil usingStrategy:UbiquityStoreMigrationStrategyNone
                               cause:cause context:context];
                break;
            }

            case UbiquityStoreMigrationStrategyNone: {
                [self log:@"Loading store without seeding."];
                NSAssert([self.persistentStoreCoordinator.persistentStores count] == 0, @"PSC should have no stores before trying to load one.");

                // Load the target store.
                [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:targetStoreURL
                                                                                          options:(NSFileCoordinatorReadingOptions)0
                                                                                            error:&error byAccessor:^(NSURL *newURL) {
                    if (![self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                       configuration:nil URL:newURL
                                                                             options:targetStoreOptions
                                                                               error:&error_])
                        [self error:error_ cause:*cause = UbiquityStoreErrorCauseOpenActiveStore context:*context = newURL.path];
                }];

                if (error)
                    [self error:error cause:*cause = UbiquityStoreErrorCauseOpenActiveStore context:*context = targetStoreURL.path];
                if ([self.persistentStoreCoordinator.persistentStores count])
                    *cause = UbiquityStoreErrorCauseNoError;

                break;
            }
        }
    }
    @catch (id exception) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:2];
        if (exception)
            [userInfo setObject:[(id<NSObject>)exception description] forKey:NSLocalizedFailureReasonErrorKey];
        if (error_)
            [userInfo setObject:error_ forKey:NSUnderlyingErrorKey];
        else if (error)
            [userInfo setObject:error forKey:NSUnderlyingErrorKey];

        [self error:[NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:userInfo]
              cause:*cause = UbiquityStoreErrorCauseSeedStore context:*context = exception];
    }
}

- (id)copyMigrateObject:(NSManagedObject *)sourceObject toContext:(NSManagedObjectContext *)destinationContext
    usingMigrationCache:(NSMutableDictionary *)migratedIDsBySourceID {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Migration should only be done from the persistence queue.");

    if (!sourceObject)
        return nil;

    NSManagedObjectID *destinationObjectID = [migratedIDsBySourceID objectForKey:sourceObject.objectID];
    if (destinationObjectID)
        return [destinationContext objectWithID:destinationObjectID];

    @autoreleasepool {
        // Create migrated object.
        NSEntityDescription *entity = sourceObject.entity;
        NSManagedObject *destinationObject = [NSEntityDescription insertNewObjectForEntityForName:entity.name
                                                                           inManagedObjectContext:destinationContext];
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
                    [(NSMutableArray *)value addObject:[self copyMigrateObject:element toContext:destinationContext
                                                           usingMigrationCache:migratedIDsBySourceID]];
            }
            else
                value = [self copyMigrateObject:[sourceObject primitiveValueForKey:key] toContext:destinationContext
                            usingMigrationCache:migratedIDsBySourceID];

            [destinationObject setPrimitiveValue:value forKey:key];
        }

        return destinationObject;
    }
}

- (BOOL)cloudSafeForSeeding {

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    [cloud synchronize];

    if (!self.tentativeStoreUUID && [cloud objectForKey:StoreUUIDKey])
            // Migration is only safe when the target is a new store (tentative or no StoreUUID).
        return NO;

    if ([[NSFileManager defaultManager] fileExistsAtPath:[self URLForCloudStore].path])
            // Migration is only safe when the cloud store does not yet exist.
        return NO;

    return YES;
}

- (void)removeItemAtURL:(NSURL *)directoryURL localOnly:(BOOL)localOnly {

    // The file coordination below fails without an error, when the file at directoryURL doesn't exist.  We ignore this.
    NSError *error = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateWritingItemAtURL:directoryURL
                                                                              options:NSFileCoordinatorWritingForDeleting
                                                                                error:&error byAccessor:
            ^(NSURL *newURL) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:newURL.path])
                    return;

                NSError *error_ = nil;
                if (localOnly && [[NSFileManager defaultManager] isUbiquitousItemAtURL:newURL]) {
                    if (![[NSFileManager defaultManager] evictUbiquitousItemAtURL:newURL error:&error_])
                        [self error:error_ cause:UbiquityStoreErrorCauseDeleteStore context:newURL.path];
                }
                else {
                    if (![[NSFileManager defaultManager] removeItemAtURL:newURL error:&error_])
                        [self error:error_ cause:UbiquityStoreErrorCauseDeleteStore context:newURL.path];
                }
            }];

    if (error)
        [self error:error cause:UbiquityStoreErrorCauseDeleteStore context:directoryURL.path];
}

- (void)deleteCloudContainerLocalOnly:(BOOL)localOnly {

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will delete the cloud container %@.", localOnly? @"on this device": @"on this device and in the cloud"];

        if (self.cloudEnabled)
            [self clearStore];

        // Delete the whole cloud container.
        [self removeItemAtURL:[self URLForCloudContainer] localOnly:localOnly];

        // Unset the storeUUID so a new one will be created.
        if (!localOnly) {
            [self createTentativeStoreUUID];
            NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
            [cloud synchronize];
            for (id key in [[cloud dictionaryRepresentation] allKeys])
                [cloud removeObjectForKey:key];
            // Don't synchronize.  Otherwise another devices might recreate the cloud store before we do.
        }

        if (self.cloudEnabled)
            [self reloadStore];
    }];
}

- (void)deleteCloudStoreLocalOnly:(BOOL)localOnly {

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will delete the cloud store (UUID:%@) %@.", self.storeUUID,
                  localOnly? @"on this device": @"on this device and in the cloud"];

        if (self.cloudEnabled)
            [self clearStore];

        // Clean up any cloud stores and transaction logs.
        [self removeItemAtURL:[self URLForCloudStore] localOnly:localOnly];
        [self removeItemAtURL:[self URLForCloudContent] localOnly:localOnly];

        // Create a tentative StoreUUID so a new cloud store will be created.
        if (!localOnly)
            [self createTentativeStoreUUID];

        if (self.cloudEnabled)
            [self reloadStore];
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
            [self reloadStore];
    }];
}

- (void)migrateCloudToLocalAndDeleteCloudStoreLocalOnly:(BOOL)localOnly {

    [self.persistentStorageQueue cancelAllOperations];
    [self.persistentStorageQueue addOperationWithBlock:^{
        self.migrationStoreURL = [self URLForCloudStore];
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.migrationStoreURL.path]) {
            [self log:@"Cannot migrate cloud to local: Cloud store doesn't exist."];
            self.migrationStoreURL = nil;
            return;
        }

        [self log:@"Will overwrite the local store with the cloud store."];

        [self deleteLocalStore];
        self.cloudEnabled = NO;
        [self deleteCloudStoreLocalOnly:localOnly];
    }];
}

- (void)rebuildCloudContentFromCloudStoreOrLocalStore:(BOOL)allowRebuildFromLocalStore {

    [self.persistentStorageQueue cancelAllOperations];
    [self.persistentStorageQueue addOperationWithBlock:^{

        NSURL *cloudStoreURL = [self URLForCloudStore];
        if (![[NSFileManager defaultManager] fileExistsAtPath:cloudStoreURL.path]) {
            if (allowRebuildFromLocalStore) {
                [self log:@"Cannot rebuild cloud content: Cloud store doesn't exist.  Will rebuild from local store."];
                [self deleteCloudStoreLocalOnly:NO];
            }
            else {
                [self log:@"Cannot rebuild cloud content: Cloud store doesn't exist.  Giving up."];
                [self reloadStore];
            }

            return;
        }

        [self log:@"Will rebuild cloud content from the cloud store."];
        [self clearStore];

        NSError *error = nil;
        __block NSError *error_ = nil;
        __block BOOL success = NO;
        self.migrationStoreURL = [[self URLForCloudStoreDirectory] URLByAppendingPathComponent:CloudStoreMigrationSource isDirectory:NO];
        [[[NSFileCoordinator alloc] initWithFilePresenter:nil]
                coordinateReadingItemAtURL:cloudStoreURL options:(NSFileCoordinatorReadingOptions)0
                          writingItemAtURL:self.migrationStoreURL options:NSFileCoordinatorWritingForReplacing
                                     error:&error byAccessor:
                ^(NSURL *newReadingURL, NSURL *newWritingURL) {
                    [[NSFileManager defaultManager] removeItemAtURL:newWritingURL error:&error_];
                    success = [[NSFileManager defaultManager] moveItemAtURL:newReadingURL toURL:newWritingURL error :&error_];
                }];
        if (!success) {
            [self error:error_? error_: error cause:UbiquityStoreErrorCauseSeedStore context:self.migrationStoreURL.path];
            [self reloadStore];
            return;
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

    [self.persistentStorageQueue addOperationWithBlock:^{
        NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
        [local setBool:enabled forKey:CloudEnabledKey];

        [self reloadStore];
    }];
}

- (NSString *)storeUUID {

    if (self.tentativeStoreUUID)
            // A tentative StoreUUID is set; this means a new cloud store is being created.
        return self.tentativeStoreUUID;

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    [cloud synchronize];
    NSString *storeUUID = [cloud objectForKey:StoreUUIDKey];

    if (!storeUUID) {
        // No StoreUUID is set; this means there is no cloud store yet.  Set a new tentative StoreUUID to create one.
        if ([NSOperationQueue currentQueue] == self.persistentStorageQueue)
            return [self createTentativeStoreUUID];
        else
            return @"tentative"; // This is only for -presentedItemURL
    }

    return storeUUID;
}

/**
 * When a tentative StoreUUID is set, this operation confirms it and writes it as the new StoreUUID to the iCloud KVS.
 */
- (void)confirmTentativeStoreUUID {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Tentative StoreUUID should only be confirmed from the persistence queue.");

    if (self.tentativeStoreUUID) {
        [self log:@"Confirming tentative StoreUUID: %@", self.tentativeStoreUUID];
        NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
        [cloud setObject:self.tentativeStoreUUID forKey:StoreUUIDKey];
        [cloud removeObjectForKey:StoreContentCorruptedKey];
        [cloud synchronize];

        [self unsetTentativeStoreUUID];
    }
}

/**
 * Creates a new a tentative StoreUUID.  This will result in a new cloud store being created.
 */
- (NSString *)createTentativeStoreUUID {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Tentative StoreUUID should only be set from the persistence queue.");

    return self.tentativeStoreUUID = [[NSUUID UUID] UUIDString];
}

/**
 * Creates a new a tentative StoreUUID.  This will result in a new cloud store being created.
 */
- (void)unsetTentativeStoreUUID {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Tentative StoreUUID should only be unset from the persistence queue.");

    self.tentativeStoreUUID = nil;
}

#pragma mark - NSFilePresenter

- (NSURL *)presentedItemURL {

    if (self.cloudEnabled)
        return [self URLForCloudContent];

    return [self URLForLocalStore];
}

- (NSOperationQueue *)presentedItemOperationQueue {

    return _presentedItemOperationQueue;
}

- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler {

    [self.persistentStorageQueue addOperations:@[
            [NSBlockOperation blockOperationWithBlock:^{
                [self clearStore];

                if (self.cloudEnabled) {
                    [self removeItemAtURL:[self URLForCloudStore] localOnly:NO];
                    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
                    [cloud removeObjectForKey:StoreContentCorruptedKey];
                    [cloud synchronize];
                }
            }]
    ]                        waitUntilFinished:YES];

    completionHandler( nil );

    if (self.cloudEnabled) {
        if ([self.delegate respondsToSelector:@selector(ubiquityStoreManagerHandleCloudContentDeletion:)])
            [self.delegate ubiquityStoreManagerHandleCloudContentDeletion:self];
    }
    else
        [self reloadStore];
}

#pragma mark - Notifications

- (void)applicationDidBecomeActive:(NSNotification *)note {

    // Check for iCloud identity changes (ie. user logs into another iCloud account).
    if (![self.currentIdentityToken isEqual:[[NSFileManager defaultManager] ubiquityIdentityToken]])
        [self cloudStoreChanged:nil];
}

//- (void)applicationWillEnterForeground:(NSNotification *)note {
//
//    [self reloadStore];
//}
//
//- (void)applicationDidEnterBackground:(NSNotification *)note {
//
//    [self.persistentStorageQueue addOperations:@[
//            [NSBlockOperation blockOperationWithBlock:^{
//                [self clearStore];
//            }]
//    ]                        waitUntilFinished:YES];
//}
//
//- (void)applicationWillTerminate:(NSNotification *)note {
//
//    [self.persistentStorageQueue addOperations:@[
//            [NSBlockOperation blockOperationWithBlock:^{
//                [self clearStore];
//            }]
//    ]                        waitUntilFinished:YES];
//}

- (void)keyValueStoreChanged:(NSNotification *)note {

    NSUbiquitousKeyValueStore * cloud = [NSUbiquitousKeyValueStore defaultStore];
    [cloud synchronize];

    NSArray *changedKeys = (NSArray *)[note.userInfo objectForKey:NSUbiquitousKeyValueStoreChangedKeysKey];
    if ([changedKeys containsObject:StoreUUIDKey]) {
        // The UUID of the active store changed.  We need to switch to the newly activated store.
        [self log:@"StoreUUID changed -> %@ (reason: %@)",
              [cloud objectForKey:StoreUUIDKey], [note.userInfo objectForKey:NSUbiquitousKeyValueStoreChangeReasonKey]];

        [self.persistentStorageQueue cancelAllOperations];
        [self.persistentStorageQueue addOperationWithBlock:^{
            [self unsetTentativeStoreUUID];
            [self cloudStoreChanged:nil];
        }];
    }

    if ([changedKeys containsObject:StoreContentCorruptedKey]) {
        // Cloud content corruption was detected or cleared.
        [self log:@"StoreContentCorruptedKey changed -> %@ (reason: %@)",
                  [cloud objectForKey:StoreContentCorruptedKey], [note.userInfo objectForKey:NSUbiquitousKeyValueStoreChangeReasonKey]];

        if (self.cloudEnabled)
            [self.persistentStorageQueue addOperationWithBlock:^{
                if (![self handleCloudContentCorruption] && !self.cloudStoreLoaded)
                    // Corruption was removed and our cloud store is not yet loaded.  Try loading the store again.
                    [self reloadStore];
            }];
    }
}

/**
 * Triggered when:
 * 1. An NSError is created describing a transaction log import failure (UbiquityManagedStoreDidDetectCorruptionNotification).
 */
- (void)ubiquityStoreManagerDidDetectCorruption:(NSNotification *)note {

    [self log:@"Detected iCloud transaction log import failure: %@", note.object];
    [self markCloudStoreCorrupted];
}

- (void)markCloudStoreCorrupted {

    self.cloudStoreCorruptUUID = self.storeUUID;

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    [cloud setBool:YES forKey:StoreContentCorruptedKey];
    [cloud synchronize];

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self handleCloudContentCorruption];
    }];
}

- (BOOL)handleCloudContentCorruption {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue,
    @"Cloud corruption can only be checked from the persistence queue.");

    if (!self.cloudEnabled)
        // Cloud not enabled: cannot handle corruption.
        return NO;

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    [cloud synchronize];

    if (![cloud boolForKey:StoreContentCorruptedKey])
        // Cloud content is not corrupt.
        return NO;

    // Unload the cloud store if it's loaded and corrupt.
    BOOL cloudStoreCorrupt = [self.cloudStoreCorruptUUID isEqualToString:self.storeUUID];
    if (cloudStoreCorrupt)
        [self clearStore];

    // Notify the delegate of corruption.
    [self log:@"Cloud content corruption detected (store %@).", cloudStoreCorrupt? @"corrupt": @"healthy"];
    BOOL defaultStrategy = YES;
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:handleCloudContentCorruptionWithHealthyStore:)])
        defaultStrategy = ![self.delegate ubiquityStoreManager:self
                  handleCloudContentCorruptionWithHealthyStore:!cloudStoreCorrupt];

    // Handle corruption.
    if (!defaultStrategy)
        [self log:@"Application handled cloud corruption."];

    else {
        if (cloudStoreCorrupt)
            // Store is corrupt: no store available.
            [self log:@"Handling cloud corruption with default strategy: Wait for a remote rebuild."];
        else {
            // Store is healthy: rebuild cloud store.
            [self log:@"Handling cloud corruption with default strategy: Rebuilding cloud content."];
            [self rebuildCloudContentFromCloudStoreOrLocalStore:NO];
        }
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
    id newIdentityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];
    if (![self.currentIdentityToken isEqual:newIdentityToken]) {
        [self log:@"Identity token changed: %@ -> %@", self.currentIdentityToken, newIdentityToken];
        self.currentIdentityToken = newIdentityToken;
    }

    // If the cloud store was active, reload it.
    if (self.cloudEnabled)
        [self reloadStore];
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

                // Reloading the store will import the changes and make sure that the store hasn't been corrupted.
                // TODO: Verify that this works reliably.
                [self reloadStore];
                return;
            }

            dispatch_async( dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidImportChangesNotification
                                                                    object:self userInfo:[note userInfo]];
            } );
        }];
    }];
}

@end
