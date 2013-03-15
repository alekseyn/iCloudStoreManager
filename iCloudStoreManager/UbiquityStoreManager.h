//
//  UbiquityStoreManager.h
//  UbiquityStoreManager
//
// UbiquityStoreManager is a controller for your Core Data persistence layer.
// It provides you with an NSPersistentStoreCoordinator and handles the stores for you.
// It encapsulates everything required to make Core Data integration with iCloud work as reliably as possible.
//
// Aside from this, it features the following functionality:
//
//  - Ability to switch between a separate cloud-synced and local store (an iCloud toggle).
//  - Automatically migrates local data to iCloud when the user has no iCloud store yet.
//  - Handles all iCloud related events such as:
//      - Account changes
//      - External deletion of the cloud data
//      - External deletion of the local store
//      - Importing of ubiquitous changes from other devices
//      - Recovering from exceptional events such as corrupted transaction logs
//  - Some maintenance functionality:
//      - Ability to rebuild the cloud store from transaction logs
//      - Ability to delete the cloud store (allowing it to be recreated from the local store)
//      - Ability to nuke the entire cloud container
//
// Known issues:
//  - Sometimes Apple's iCloud implementation hangs itself coordinating access for importing ubiquitous changes.
//      - Reloading the store with -loadStore can sometimes cause these changes to get imported.
//      - If not, the app needs to be restarted.
//  - Sometimes Apple's iCloud implementation will write corrupting transaction logs to the cloud container.
//      - As a result, all other devices will fail to import any future changes to the store.
//      - The only remedy is to recreate the store.
//      - TODO: This manager allows the cloud store to be recreated and seeded by the old cloud store.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

/**
 * The store managed by the ubiquity manager's coordinator changed (eg. switching (no store) or switched to iCloud or local).
 *
 * This notification is posted after the -ubiquityStoreManager:willLoadStoreIsCloud: or -ubiquityStoreManager:didLoadStoreForCoordinator:isCloud: message was posted to the delegate.
 */
extern NSString *const UbiquityManagedStoreDidChangeNotification;
/**
 * The store managed by the ubiquity manager's coordinator imported changes from iCloud (eg. another device saved changes to iCloud).
 */
extern NSString *const UbiquityManagedStoreDidImportChangesNotification;

typedef enum {
    UbiquityStoreErrorCauseNoError, // Nothing went wrong.  There is no context.
    UbiquityStoreErrorCauseNoAccount, // The user is not logged into iCloud on this device.  There is no context.
    UbiquityStoreErrorCauseDeleteStore, // Error occurred while deleting the store file or its transaction logs.  context = the path of the store.
    UbiquityStoreErrorCauseCreateStorePath, // Error occurred while creating the path where the store needs to be saved.  context = the path of the store.
    UbiquityStoreErrorCauseClearStore, // Error occurred while removing a store from the coordinator.  context = the store.
    UbiquityStoreErrorCauseOpenLocalStore, // Error occurred while opening the local store file.  context = the path of the store.
    UbiquityStoreErrorCauseOpenCloudStore, // Error occurred while opening the cloud store file.  context = the path of the store.
    UbiquityStoreErrorCauseMigrateLocalToCloudStore, // Error occurred while migrating the local store to the cloud.  context = the path of the store or exception that caused the problem.
    UbiquityStoreErrorCauseImportChanges, // Error occurred while importing changes from the cloud into the application's context.  context = the DidImportUbiquitousContentChanges notification.
} UbiquityStoreErrorCause;

typedef enum {
    UbiquityStoreMigrationStrategyCopyEntities, // Migrate by copying all entities from the active store to the new store.
    UbiquityStoreMigrationStrategyIOS, // Migrate using iOS' migration routines (bugged for: cloud -> local on iOS 6.0, local -> cloud on iOS 6.1).
    UbiquityStoreMigrationStrategyManual, // Migrate using the delegate's -ubiquityStoreManager:manuallyMigrateStore:toStore:.
    UbiquityStoreMigrationStrategyNone, // Don't migrate, just create an empty destination store.
} UbiquityStoreMigrationStrategy;

@class UbiquityStoreManager;

@protocol UbiquityStoreManagerDelegate<NSObject>

/** When cloud changes are detected, the manager can merge these changes into your managed object context.
 *
 * If you don't implement this method or return nil, the manager will commit the changes to the store
 * (using NSMergeByPropertyObjectTrumpMergePolicy) but your application may not become aware of them.
 *
 * If you do implement this method, the changes will be merged into your managed object context
 * and the context will be saved afterwards.
 *
 * Regardless of whether this method is implemented or not, a UbiquityManagedStoreDidImportChangesNotification will be
 * posted after the changes are successfully imported into the store.
 */
@optional
- (NSManagedObjectContext *)managedObjectContextForUbiquityChangesInManager:(UbiquityStoreManager *)manager;

/** Triggered when the store manager begins loading a persistence store.
 *
 * Between this and an invocation of -ubiquityStoreManager:didLoadStoreForCoordinator:isCloud: or -ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:, the application should not be using the persistence coordinator.
 * You should probably unset your managed object contexts here to prevent exceptions/hangs in your applications (the coordinator is locked and its store removed).
 * Also useful for indicating in your user interface that the store is loading.
 *
 * @param isCloudStore YES if the cloud store will be loaded.
 *                     NO if the local store will be loaded.
 */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager willLoadStoreIsCloud:(BOOL)isCloudStore;

/** Triggered when the store manager loads a persistence store.
 *
 * This is where you'll init/update your application's persistence layer.
 * You should probably create your main managed object context here.
 *
 * Note the coordinator could change during the application's lifetime (you'll get a new -ubiquityStoreManager:didLoadStoreForCoordinator:isCloud: if this happens).
 *
 * @param isCloudStore YES if the cloud store was just loaded.
 *                     NO if the local store was just loaded.
 */
@required
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didLoadStoreForCoordinator:(NSPersistentStoreCoordinator *)coordinator isCloud:(BOOL)isCloudStore;

/** Triggered when the store manager has detected that the cloud content has failed to import on one of the devices.
 *
 * The result is that the cloud store on this device is no longer guaranteed to be the same as the cloud store on
 * other devices.  Moreover, there is no more guarantee that changes made to the cloud store will sync to other devices.
 * iCloud sync for the cloud store is therefore effectively broken.
 *
 * When this happens, there is only one recovery: The cloud store must be recreated.
 *
 * The most likely cause of this is an Apple bug with regards to synchronizing Core Data relationships using
 * transaction logs.  When two devices simultaneously modify a relationship, the resulting transaction logs can cause
 * an irreparable conflict.
 *
 * The manager protects the user from committing more data into the corrupt cloud content container.
 * If you implement this method, it will be invoked on every device that attempts to use the cloud store until
 * the cloud store is rebuilt.  After invoking this method, if the cloud store is currently enabled, it will be
 * unloaded and the store coordinator will have no store available.
 * If you don't implement this method, the manager will switch to the local store and the cloud store will remain
 * unavailable.
 *
 * When you receive this method, there are a few things you can do to handle the situation:
 * - Switch to the local store (manager.cloudEnabled = NO).
 *      NOTE: The cloud data and cloud syncing will be unavailable.
 * - Keep the existing cloud data but disable iCloud ([manager migrateCloudStoreToLocal]).
 *      NOTE: The existing local store will be lost.
 *      NOTE: After doing this, it would be prudent to delete the cloud store ([manager deleteCloudStoreLocalOnly:NO])
 *            so that enabling iCloud in the future will seed it with the new local store.
 * - Delete the cloud store and recreate it by seeding it with the local store ([manager deleteCloudStoreLocalOnly:NO]).
 *      NOTE: The existing cloud store will be lost.
 * - Rebuild the cloud content by seeding it with the cloud store of this device ([manager rebuildCloudContentFromCloudStore]).
 *      NOTE: Any cloud changes on other devices that failed to sync to this device will be lost.
 *
 * The recommended way to handle this method is to pop an alert to the user, tell him what happened, and give him
 * a choice on how to proceed.  The alert will pop up on each of his devices.  If he wants to rebuild the cloud store,
 * this will enable him to choose what device to press the rebuild button on.
 * Don't forget to dismiss the alert when you get -ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:YES.
 *
 * @param isCloudStore YES if the cloud store is currently loaded.
 *                     NO if the local store is currently loaded.
*/
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager handleCloudContentCorruptionIsCloud:(BOOL)isCloudStore;

/** Triggered when the store manager fails to loads a persistence store.
 *
 * Useful to decide what to do to make a store available to the application.
 *
 * If you don't implement this method, the manager will disable the cloud store and fall back to the local store when loading the cloud store fails.  It's the equivalent to implementing this method with `manager.cloudEnabled = NO;`.
 *
 * @param wasCloudStore YES if the error was caused while attempting to load the cloud store.
 *                      NO if the error was caused while attempting to load the local store.
 */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager failedLoadingStoreWithCause:(UbiquityStoreErrorCause)cause
                     context:(id)context wasCloud:(BOOL)wasCloudStore;

/** Triggered when the store manager encounters an error.  Mainly useful to handle error conditions/logging in whatever way you see fit.
 *
 * If you don't implement this method, the manager will instead detail the error in a few log statements.
 */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didEncounterError:(NSError *)error
                       cause:(UbiquityStoreErrorCause)cause context:(id)context;

/** Triggered whenever the store manager has information to share about its operation.  Mainly useful to plug in your own logger.
 *
 * If you don't implement this method, the manager will just log the message using NSLog.
 */
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager log:(NSString *)message;

/** Triggered when the store manager needs to perform a manual store migration.
 *
 * Implementing this method is required if you set -migrationStrategy to UbiquityStoreMigrationStrategyManual.
 *
 * @param error If the migration fails, write out an error object that describes the problem.
 * @return YES when the migration was successful and the new store may be loaded.
 *         NO to error out and not load the new store (new store will be cleaned up if it exists).
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
- (void)deleteCloudContainerLocalOnly:(BOOL)localOnly;

/**
 * This will delete the iCloud store.
 *
 * @param localOnly If YES, the iCloud transaction logs will be redownloaded and the store rebuilt.  If NO, the store will be permanently lost and a new one will be created by migrating the device's local store.
 */
- (void)deleteCloudStoreLocalOnly:(BOOL)localOnly;

/**
 * This will delete the local store.  There is no recovery.
 */
- (void)deleteLocalStore;

/**
 * This will delete the local store and migrate the cloud store to a new local store.  There is no recovery.
 */
- (void)migrateCloudStoreToLocal;

/**
 * This will delete the cloud content and recreate a new cloud store by seeding it with the current cloud store.
 * Any cloud content and cloud store changes on other devices that are not present on this device's cloud store will be lost.  There is no recovery.
 */
- (void)rebuildCloudContentFromCloudStore;

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
