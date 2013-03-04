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

typedef enum {
    UbiquityStoreManagerErrorCauseNoAccount, // The user is not logged into iCloud on this device.
    UbiquityStoreManagerErrorCauseDeleteStore, // Error occurred while deleting the store file or its transaction logs.
    UbiquityStoreManagerErrorCauseCreateStorePath, // Error occurred while creating the path where the store needs to be saved.
    UbiquityStoreManagerErrorCauseClearStore, // Error occurred while removing the active store from the coordinator.
    UbiquityStoreManagerErrorCauseOpenLocalStore, // Error occurred while opening the local store file.
    UbiquityStoreManagerErrorCauseOpenCloudStore, // Error occurred while opening the cloud store file.
    UbiquityStoreManagerErrorCauseMigrateLocalToCloudStore, // Error occurred while migrating the local store to the cloud.
    UbiquityStoreManagerErrorCauseImportChanges // Error occurred while importing changes from the cloud into the application's context.
}               UbiquityStoreManagerErrorCause;

typedef enum {
    UbiquityStoreManagerMigrationStrategyCopyEntities, // Migrate by copying all entities from the active store to the new store.
    UbiquityStoreManagerMigrationStrategyIOS, // Migrate using iOS' migration routines (bugged for: cloud -> local on iOS 6.0, local -> cloud on iOS 6.1).
    UbiquityStoreManagerMigrationStrategyManual, // Migrate using the delegate's -ubiquityStoreManager:manuallyMigrateStore:toStore:.
    UbiquityStoreManagerMigrationStrategyNone, // Don't migrate, just create an empty destination store.
}               UbiquityStoreManagerMigrationStrategy;

@class UbiquityStoreManager;

@protocol UbiquityStoreManagerDelegate<NSObject>

/** The application should provide a managed object context to use for importing cloud changes.
 *
 * After importing the changes to the context, the context will be saved.
 */
@required
- (NSManagedObjectContext *)managedObjectContextForUbiquityChangesInManager:(UbiquityStoreManager *)manager;

/** Triggered when the store manager loads a persistence store.
 *
 * This is where you'll init/update your application's persistence layer.
 */
@required
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didLoadStoreForCoordinator:(NSPersistentStoreCoordinator *)coordinator isCloud:(BOOL)isCloudStore;

/** Triggered when the store manager begins loading a persistence store.
 *
 * Between this and an invocation of -ubiquityStoreManager:didLoadStoreForCoordinator:isCloud: or -ubiquityStoreManager:failedLoadingStoreWithCause:wasCloud:, the application should not be using the persistence coordinator.  Ideally, you could unset your managed object contexts here.
 * Also useful for indicating in your user interface that the store is loading.
 */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager willLoadStoreIsCloud:(BOOL)isCloudStore;
/** Triggered when the store manager fails to loads a persistence store.  Useful to decide what to do to make a store available to the application. If you don't implement this, the default behaviour is to disable cloud when loading the cloud store fails and do nothing when loading the local store fails. */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager failedLoadingStoreWithCause:(UbiquityStoreManagerErrorCause)cause wasCloud:(BOOL)wasCloudStore;
/** Triggered when the store manager encounters an error.  Mainly useful to handle error conditions in whatever way you see fit. */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didEncounterError:(NSError *)error
                       cause:(UbiquityStoreManagerErrorCause)cause context:(id)context;
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

// The delegate provides the managed object context to use and is informed of events in the ubiquity manager.
@property (nonatomic, weak) id<UbiquityStoreManagerDelegate> delegate;

// Determines what strategy to use when migrating from one store to another (eg. local -> cloud).
@property (nonatomic, assign) UbiquityStoreManagerMigrationStrategy migrationStrategy;

// Indicates whether the iCloud store or the local store is in use.
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
 * This will delete all the data from iCloud for this application.  There is no recovery.  A new iCloud store will be created if enabled.
 */
- (BOOL)nukeCloudContainer;

/**
 * This will delete the local store.  There is no recovery.
 */
- (BOOL)deleteLocalStore;

/**
 * This will delete the iCloud store.  Theoretically, it should be rebuilt from the iCloud transaction logs.
 * TODO: Verify claim.
 */
- (BOOL)deleteCloudStore;

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
