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
@property (nonatomic, readonly) NSString           *storeUUID;
@property (nonatomic, strong) NSString             *tentativeStoreUUID;
@property (nonatomic, strong) NSOperationQueue     *persistentStorageQueue;
@property (nonatomic) BOOL loadingStore;

@end


@implementation UbiquityStoreManager {
    NSOperationQueue *_presentedItemOperationQueue;
}

@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

- (id)init {
	
    return self = [self initStoreNamed:nil withManagedObjectModel:nil localStoreURL:nil containerIdentifier:nil additionalStoreOptions:nil];
}

- (id)initStoreNamed:(NSString *)contentName withManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL
 containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions {
	
    if (!(self = [super init]))
        return nil;
	
    // Parameters
    _contentName            = contentName == nil? @"UbiquityStore": contentName;
    _model                  = model == nil? [NSManagedObjectModel mergedModelFromBundles:nil]: model;
    if (!localStoreURL)
        localStoreURL = [[[self URLForApplicationContainer]
						  URLByAppendingPathComponent:self.contentName isDirectory:NO]
						 URLByAppendingPathExtension:@"sqlite"];
	
    _localStoreURL          = localStoreURL;
    _containerIdentifier    = containerIdentifier;
    _additionalStoreOptions = additionalStoreOptions == nil? [NSDictionary dictionary]: additionalStoreOptions;
	self.dataMigrationType		= UbiquityStoreManagerDataMigrationNone;
	
    // Private vars
    _persistentStorageQueue = [NSOperationQueue new];
    _persistentStorageQueue.name = [NSString stringWithFormat:@"%@PersistenceQueue", NSStringFromClass([self class])];
	
    _presentedItemOperationQueue = [NSOperationQueue new];
    _presentedItemOperationQueue.name = [NSString stringWithFormat:@"%@PresenterQueue", NSStringFromClass([self class])];
	
    return self;
}

- (id)initWithManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions {
	return [self initStoreNamed:nil withManagedObjectModel:model localStoreURL:localStoreURL containerIdentifier:containerIdentifier
		 additionalStoreOptions:additionalStoreOptions];
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
    applicationSupportURL = [applicationSupportURL URLByAppendingPathComponent:[NSRunningApplication currentApplication].bundleIdentifier isDirectory:YES];
	
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
    return [[self URLForCloudContainer] URLByAppendingPathComponent:CloudStoreDirectory isDirectory:YES];
}

- (NSURL *)URLForCloudStore {
	
    // Our cloud store is in the cloud store databases directory and is identified by the active storeUUID.
    NSString *uuid = self.storeUUID;
    NSAssert(uuid, @"No storeUUID set.");
    return [[[self URLForCloudStoreDirectory] URLByAppendingPathComponent:uuid isDirectory:NO] URLByAppendingPathExtension:@"sqlite"];
}

- (NSURL *)URLForCloudContentDirectory {
	
    // The transaction logs are in the ubiquity container and are synced by iCloud.
    return [[self URLForCloudContainer] URLByAppendingPathComponent:CloudLogsDirectory isDirectory:YES];
}

- (NSURL *)URLForCloudContent {
	
    // Our cloud store's logs are in the cloud store transaction logs directory and is identified by the active storeUUID.
    NSString *uuid = self.storeUUID;
    NSAssert(uuid, @"No storeUUID set.");
    return [[self URLForCloudContentDirectory] URLByAppendingPathComponent:uuid isDirectory:YES];
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

- (void)loadLocalStore {
	@try {
		// Load local store if iCloud is disabled.
		NSError             *error             = nil;
		NSMutableDictionary *localStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
												  @YES, NSMigratePersistentStoresAutomaticallyOption,
												  @YES, NSInferMappingModelAutomaticallyOption,
												  nil];
		[localStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
		
		// Make sure local store directory exists.
		if (![[NSFileManager defaultManager] createDirectoryAtPath:[self URLForLocalStoreDirectory].path
									   withIntermediateDirectories:YES attributes:nil error:&error])
			[self error:error cause:UbiquityStoreManagerErrorCauseCreateStorePath context:[self URLForCloudStoreDirectory].path];
		
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
	
	[self log:@"iCloud disabled. %@",  [self.persistentStoreCoordinator.persistentStores count]? @"Loaded local store.": @"Failed to load local store."];
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification object:self userInfo:nil];
		if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didSwitchToCloud:)])
			[self.delegate ubiquityStoreManager:self didSwitchToCloud:NO];
	});
}

- (void)loadCloudStore {
    [self.persistentStorageQueue addOperationWithBlock:^{
        @try {
            if (![self URLForCloudContainer]) {
                // iCloud is not enabled on this device.  Disable iCloud in the app (will cause a re-load using the local store).
                // TODO: Notify user?
                self.loadingStore = NO;
                self.cloudEnabled = NO;
                return;
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
			
            // Determine whether we can seed the cloud store from the local store.
            if ([self cloudSafeForSeeding] && [[NSFileManager defaultManager] fileExistsAtPath:[self URLForLocalStore].path]) {
 				
				[self log:@"Migrating local store to new cloud store."];
				
				switch (self.dataMigrationType) {
						
					// NOTE: The iOS 6.1 release notes indicate that migratePersistentStore crashes when used with iCloud
						
					case UbiquityStoreManagerDataMigrationAutomatic:
					{
						// First add the local store, then migrate it to the cloud store.
						NSPersistentStore *migratingStore = [self.persistentStoreCoordinator addPersistentStoreWithType: NSSQLiteStoreType
																										  configuration: nil
																													URL: [self URLForLocalStore]
																												options: migratingStoreOptions
																												  error: &error];
						if (!migratingStore)
							[self error:error cause:UbiquityStoreManagerErrorCauseOpenLocalStore context:[self URLForLocalStore]];
						
						else if (![self.persistentStoreCoordinator migratePersistentStore: migratingStore
																					toURL: cloudStoreURL
																				  options: cloudStoreOptions
																				 withType: NSSQLiteStoreType
																					error: &error])
							[self error:error cause:UbiquityStoreManagerErrorCauseMigrateLocalToCloudStore context:cloudStoreURL.path];
					}
						break;
						
					case UbiquityStoreManagerDataMigrationManual:
						// TODO (AN)
						break;
						
					case UbiquityStoreManagerDataMigrationNone:
					{
						// Not seeding, just add a new cloud store.
						if (![self.persistentStoreCoordinator addPersistentStoreWithType: NSSQLiteStoreType
																		   configuration: nil
																					 URL: cloudStoreURL
																				 options: cloudStoreOptions
																				   error: &error]) {
							[self error:error cause:UbiquityStoreManagerErrorCauseCreateCloudStore context:cloudStoreURL.path];
						}
					}
						break;
				}
            }
			// Not seeding, just add the cloud store.
            else if (![self.persistentStoreCoordinator addPersistentStoreWithType: NSSQLiteStoreType
                                                                    configuration: nil
																			  URL: cloudStoreURL
                                                                          options: cloudStoreOptions
                                                                            error: &error])
                [self error:error cause:UbiquityStoreManagerErrorCauseOpenCloudStore context:cloudStoreURL.path];
			
            if ([self.persistentStoreCoordinator.persistentStores count]) {
                [self confirmTentativeStoreUUID];
                [self observeStore];
            }
        }
		@catch (NSException *exception) {
			[self log:@"%@: %@", exception.name, exception.reason];
		}
        @finally {
            [self.persistentStoreCoordinator unlock];
            self.loadingStore = NO;
			
			self.tentativeStoreUUID = nil;
        }
		
		NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
		[local setBool:self.hasBeenSeeded forKey:CloudEnabledKey];
		
        [self log:@"iCloud enabled. %@", (self.hasBeenSeeded) ? @"Loaded cloud store.": @"Failed to load cloud store."];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification object:self userInfo:nil];
            if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didSwitchToCloud:)])
                [self.delegate ubiquityStoreManager:self didSwitchToCloud:self.hasBeenSeeded];
        });
    }];
}

- (void)loadStore {
	
    @synchronized (self) {
        if (self.loadingStore)
            return;
        self.loadingStore = YES;
    }
	
	if (!self.cloudEnabled)
		[self loadLocalStore];
	else
		// Otherwise, load iCloud store asynchronously (init of iCloud may take some time).
		[self loadCloudStore];
}

- (BOOL)cloudSafeForSeeding {
	
    if (!self.tentativeStoreUUID)
        // Migration is only safe when the storeUUID is tentative.
        return NO;
	
    if ([[NSFileManager defaultManager] fileExistsAtPath:[self URLForCloudStore].path])
        // Migration is only safe when the cloud store does not yet exist.
        return NO;
	
    return YES;
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

- (void)clearTransactionLogs {
	
    NSURL *url				= [[self URLForCloudContainer] URLByAppendingPathComponent:CloudLogsDirectory];
	NSError *error			= nil;
	NSFileCoordinator *fc	= [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	
	[fc coordinateWritingItemAtURL: url
						   options: NSFileCoordinatorWritingForDeleting
							 error: &error
						byAccessor: ^(NSURL *itemURL) {
							NSError *error_ = nil;
							
							[[NSFileManager defaultManager] removeItemAtURL:itemURL error:&error_];
							[self error:error_ cause:UbiquityStoreManagerErrorCauseDeleteStore context:itemURL.path];
 						}];
	if (error)
		[self error:error cause:UbiquityStoreManagerErrorCauseDeleteStore context:url.path];
}

- (void)nukeCloudContainer {
	
	[self.persistentStorageQueue addOperationWithBlock:^{
		NSURL *cloudContainerURL = [self URLForCloudContainer];
		
		if (cloudContainerURL && [[NSFileManager defaultManager] fileExistsAtPath:cloudContainerURL.path]) {
			[self.persistentStoreCoordinator lock];
			[self clearStore];
			[self clearTransactionLogs];
			
			// Unset the storeUUID so a new one will be created.
			NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
			[cloud removeObjectForKey:StoreUUIDKey];
			[cloud synchronize];
			
			// Clear this just in case we got stuck in an expected state
			self.tentativeStoreUUID = nil;
			
			[self.persistentStoreCoordinator unlock];
			[self loadStore];
		}
	}];
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
        self.tentativeStoreUUID = nil;
    }
}

- (BOOL)hasBeenSeeded {
    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    NSString *storeUUID = [cloud objectForKey:StoreUUIDKey];
	
	return (storeUUID != nil) || (self.tentativeStoreUUID != nil);
}

#pragma mark - NSFilePresenter

- (NSURL *)presentedItemURL {
	
    if (self.cloudEnabled)
        return [self URLForCloudStore];
	
    return [self URLForLocalStore];
}

-(NSOperationQueue *)presentedItemOperationQueue {
    
    return _presentedItemOperationQueue;
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
	// TODO: (AN) should probably go back to using the local store?
	// There are two use cases to be concerned about here - a race condition for the initial seeding,
	// and a change in the iCloud account. (sign in/sign out/switch to another account)
    [self loadStore];
}

- (void)mergeChanges:(NSNotification *)note {
	
    [self log:@"Cloud store updates:\n%@", note.userInfo];
    [self.persistentStorageQueue addOperationWithBlock:^{
        NSManagedObjectContext *moc = [self.delegate managedObjectContextForUbiquityStoreManager:self];
		
        [moc performBlock:^{
            [moc mergeChangesFromContextDidSaveNotification:note];

			dispatch_async(dispatch_get_main_queue(), ^{
				[[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidImportChangesNotification object:self
																  userInfo:[note userInfo]];
			});
		}];
    }];
}

@end
