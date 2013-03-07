//
//  UbiquityStoreManager.h
//  UbiquityStoreManager
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//
// UbiquityStoreManager manages the transfer of your SQL CoreData store from your local
// application sandbox to iCloud. Even though it is not reinforced, UbiquityStoreManager
// is expected to be used as a singleton.
//
// NSUbiquitousKeyValueStore is the mechanism used to discover which iCloud store to use.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

/**
 * The store managed by the ubiquity manager's coordinator changed (eg. switched from iCloud to local).
 */
extern NSString *const UbiquityManagedStoreDidChangeNotification;
/**
 * The store managed by the ubiquity manager's coordinator imported changes from iCloud (eg. another device saved changes to iCloud).
 */
extern NSString *const UbiquityManagedStoreDidImportChangesNotification;
/**
 * The key at which the UUID of the device that is inhibiting exclusive access to the store can be found in the context of UbiquityStoreErrorCauseNoExclusiveAccess.
 */
extern NSString *const UbiquityManagedStoreExclusiveDeviceUUIDKey;
/**
 * The key at which the name of the device that is inhibiting exclusive access to the store can be found in the context of UbiquityStoreErrorCauseNoExclusiveAccess.
 */
extern NSString *const UbiquityManagedStoreExclusiveDeviceNameKey;

typedef enum {
    UbiquityStoreErrorCauseNoAccount, // The user is not logged into iCloud on this device.  There is no context.
    UbiquityStoreErrorCauseDeleteStore, // Error occurred while deleting the store file or its transaction logs.  context = the path of the store.
    UbiquityStoreErrorCauseCreateStorePath, // Error occurred while creating the path where the store needs to be saved.  context = the path of the store.
    UbiquityStoreErrorCauseClearStore, // Error occurred while removing a store from the coordinator.  context = the store.
    UbiquityStoreErrorCauseOpenLocalStore, // Error occurred while opening the local store file.  context = the path of the store.
    UbiquityStoreErrorCauseOpenCloudStore, // Error occurred while opening the cloud store file.  context = the path of the store.
    UbiquityStoreErrorCauseMigrateLocalToCloudStore, // Error occurred while migrating the local store to the cloud.  context = the path of the store or exception that caused the problem.
    UbiquityStoreErrorCauseImportChanges, // Error occurred while importing changes from the cloud into the application's context.  context = the DidImportUbiquitousContentChanges notification.
    UbiquityStoreErrorCauseNoExclusiveAccess // This device was unable to obtain exclusive access to the store.  context = a dictionary with keys UbiquityManagedStoreExclusiveDeviceUUIDKey, UbiquityManagedStoreExclusiveDeviceNameKey.
} UbiquityStoreErrorCause;

typedef enum {
    UbiquityStoreMigrationStrategyCopyEntities, // Migrate by copying all entities from the active store to the new store.
    UbiquityStoreMigrationStrategyIOS, // Migrate using iOS' migration routines (bugged for: cloud -> local on iOS 6.0, local -> cloud on iOS 6.1).
    UbiquityStoreMigrationStrategyManual, // Migrate using the delegate's -ubiquityStoreManager:manuallyMigrateStore:toStore:.
    UbiquityStoreMigrationStrategyNone, // Don't migrate, just create an empty destination store.
} UbiquityStoreMigrationStrategy;

typedef enum {
    UbiquityStoreDesyncAvoidanceStrategyExclusiveAccess, // Avoid cloud desync by requesting exclusive access to the cloud store and failing to load the store if another device has it.  Persistence will be unavailable while another device has exclusive access.
    UbiquityStoreDesyncAvoidanceStrategyExclusiveWriteAccess, // Avoid cloud desync by requesting exclusive access to the cloud store and opening the store read-only if another device has it.  Persistence will be read-only while another device has exclusive access.
    UbiquityStoreDesyncAvoidanceStrategyExclusiveOrMigrateToLocal, // Avoid cloud desync by requesting exclusive access to the cloud store and migrating it to the local store if another device has it.  Persistence will be read-write but changes won't be synced while another device has exclusive access.
    UbiquityStoreDesyncAvoidanceStrategyNone, // Don't try to avoid cloud desync.  If it happens, your application can try and cope with it from -ubiquityStoreManager:failedLoadingStoreWithCause:wasCloud:.
} UbiquityStoreDesyncAvoidanceStrategy;

@class UbiquityStoreManager;

@protocol UbiquityStoreManagerDelegate<NSObject>

/** The application should provide a managed object context to use for importing cloud changes.
 *
 * After importing the changes to the context, the context will be saved.
 */
@required
- (NSManagedObjectContext *)managedObjectContextForUbiquityChangesInManager:(UbiquityStoreManager *)manager;

/** Triggered when the store manager begins loading a persistence store.
 *
 * Between this and an invocation of -ubiquityStoreManager:didLoadStoreForCoordinator:isCloud: or -ubiquityStoreManager:failedLoadingStoreWithCause:wasCloud:, the application should not be using the persistence coordinator.
 * You should probably unset your managed object contexts here to prevent exceptions/hangs in your applications (the coordinator is locked and its store removed).
 * Also useful for indicating in your user interface that the store is loading.
 */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager willLoadStoreIsCloud:(BOOL)isCloudStore;

/** Triggered when the store manager loads a persistence store.
 *
 * This is where you'll init/update your application's persistence layer.
 * You should probably create your main managed object context here.  Note the coordinator could change during the application's lifetime.
 */
@required
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didLoadStoreForCoordinator:(NSPersistentStoreCoordinator *)coordinator isCloud:(BOOL)isCloudStore;

/** Triggered when the store manager fails to loads a persistence store.
 *
 * Useful to decide what to do to make a store available to the application.
 * You should probably unset your managed object contexts here to prevent exceptions in your applications (the coordinator has no more store).
 * If you don't implement this, the default behaviour is to disable cloud when loading the cloud store fails and do nothing when loading the local store fails.  You can implement this simply with `manager.cloudEnabled = NO;`.
 *
 * IMPORTANT: When this method is triggered, the store is likely irreparably broken.
 * Unless your application has a way to recover, you should probably delete the store in question (cloud/local).
 * Until you do, the user will remain unable to use that store.
 */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager failedLoadingStoreWithCause:(UbiquityStoreErrorCause)cause context:(id)context wasCloud:(BOOL)wasCloudStore;

/** Triggered when the store manager encounters an error.  Mainly useful to handle error conditions in whatever way you see fit. */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didEncounterError:(NSError *)error
                       cause:(UbiquityStoreErrorCause)cause context:(id)context;

/** Triggered whenever the store manager has information to share about its operation.  Mainly useful to plug in your own logger. */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager log:(NSString *)message;

/** Triggered when the store manager needs to perform a manual store migration.
 * @param error Write out an error object here when the migration fails.
 * @return YES when the migration was successful and the new store may be loaded.  NO to error out and not load the new store (new store will be cleaned up if it exists).
 */
@optional
- (BOOL)ubiquityStoreManager:(UbiquityStoreManager *)manager
        manuallyMigrateStore:(NSURL *)oldStore withOptions:oldStoreOptions
                     toStore:(NSURL *)newStore withOptions:newStoreOptions error:(NSError **)error;

@end

@interface UbiquityStoreManager : NSObject

/** The delegate provides the managed object context to use and is informed of events in the ubiquity manager. */
@property (nonatomic, weak) id<UbiquityStoreManagerDelegate> delegate;

/** Determines what strategy to use when migrating from one store to another (eg. local -> cloud).  Default is UbiquityStoreMigrationStrategyCopyEntities. */
@property (nonatomic, assign) UbiquityStoreMigrationStrategy migrationStrategy;

/** Determines what strategy to use to avoid causing the cloud store on different devices to get desynced.  Default is UbiquityStoreDesyncAvoidanceStrategyExclusiveAccess.
 *
 * Because of bugs in iOS' iCloud implementation, desyncs happen when two devices simultaneously mutate a relationship.
 */
@property (nonatomic, assign) UbiquityStoreDesyncAvoidanceStrategy desyncAvoidanceStrategy;

/** Indicates whether the iCloud store or the local store is in use. */
@property (nonatomic) BOOL cloudEnabled;

/** Start managing an optionally ubiquitous store coordinator.
 *  @param contentName The name of the local and cloud stores that this manager will create.  If nil, "UbiquityStore" will be used.
 *  @param model The managed object model the store should use.  If nil, all the main bundle's models will be merged.
 *  @param localStoreURL The location where the non-ubiquitous (local) store should be kept. If nil, the local store will be put in the application support directory.
 *  @param containerIdentifier The identifier of the ubiquity container to use for the ubiquitous store. If nil, the entitlement's primary container identifier will be used.
 *  @param additionalStoreOptions Additional persistence options that the stores should be initialized with.
 *  @param delegate The application controller that will be handling the application's persistence responsibilities.
 */
- (id)initStoreNamed:(NSString *)contentName withManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL
 containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions delegate:(id<UbiquityStoreManagerDelegate>)delegate;

/**
 * This will delete all the data from iCloud for this application.
 *
 * @param localOnly If YES, the iCloud data will be redownloaded when needed.  If NO, the container's data will be permanently lost.
 *
 * Unless you intend to delete more than just the active cloud store, you should probably use -deleteCloudStoreLocalOnly: instead.
 */
- (BOOL)deleteCloudContainerLocalOnly:(BOOL)localOnly;

/**
 * This will delete the iCloud store.
 *
 * @param localOnly If YES, the iCloud transaction logs will be redownloaded and the store rebuilt.  If NO, the store will be permanently lost and a new one will be created by migrating the device's local store.
 */
- (BOOL)deleteCloudStoreLocalOnly:(BOOL)localOnly;

/**
 * This will delete the local store.  There is no recovery.
 */
- (BOOL)deleteLocalStore;

/**
 * Determine whether it's safe to seed the cloud store with a local store.
 */
- (BOOL)cloudSafeForSeeding;

/**
 * @return URL to the active app's ubiquity container.
 */
- (NSURL *)URLForCloudContainer;

/**
 * @return URL to the directory where we put cloud store databases for this app.
 */
- (NSURL *)URLForCloudStoreDirectory;

/**
 * @return URL to the active cloud store's database.
 */
- (NSURL *)URLForCloudStore;

/**
 * @return URL to the directory where we put cloud store transaction logs for this app.
 */
- (NSURL *)URLForCloudContentDirectory;

/**
 * @return URL to the active cloud store's transaction logs.
 */
- (NSURL *)URLForCloudContent;

/**
 * @return URL to the directory where we put the local store database for this app.
 */
- (NSURL *)URLForLocalStoreDirectory;

/**
 * @return URL to the local store's database.
 */
- (NSURL *)URLForLocalStore;

@end
