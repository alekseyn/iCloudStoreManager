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
    UbiquityStoreManagerErrorCauseDeleteStore, // Error occurred while deleting the store file or its transaction logs.
    UbiquityStoreManagerErrorCauseCreateStorePath, // Error occurred while creating the path where the store needs to be saved.
    UbiquityStoreManagerErrorCauseClearStore, // Error occurred while removing the active store from the coordinator.
    UbiquityStoreManagerErrorCauseOpenLocalStore, // Error occurred while opening the local store file.
    UbiquityStoreManagerErrorCauseCreateCloudStore, // Error occurred while creating a new cloud store file.
    UbiquityStoreManagerErrorCauseOpenCloudStore, // Error occurred while opening the cloud store file.
    UbiquityStoreManagerErrorCauseMigrateLocalToCloudStore, // Error occurred while migrating the local store to the cloud.
}               UbiquityStoreManagerErrorCause;

typedef enum {
	UbiquityStoreManagerDataMigrationNone,
	UbiquityStoreManagerDataMigrationByStore,
	UbiquityStoreManagerDataMigrationByModel,
	UbiquityStoreManagerDataMigrationManual
} UbiquityStoreManagerDataMigrationType;

@class UbiquityStoreManager;

@protocol UbiquityStoreManagerDelegate<NSObject>

@required
- (NSManagedObjectContext *)managedObjectContextForUbiquityStoreManager:(UbiquityStoreManager *)usm;

@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didSwitchToCloud:(BOOL)cloudEnabled;
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didEncounterError:(NSError *)error
                       cause:(UbiquityStoreManagerErrorCause)cause context:(id)context;
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager log:(NSString *)message;

@end


@interface UbiquityStoreManager : NSObject <NSFilePresenter, UIAlertViewDelegate>

// The delegate provides the managed object context to use and is informed of events in the ubiquity manager.
@property (nonatomic, weak) id<UbiquityStoreManagerDelegate> delegate;

// Indicates whether the iCloud store or the local store is in use.
@property (nonatomic) BOOL cloudEnabled;

// The coordinator provides access to this manager's active store.
@property (nonatomic, readonly) NSPersistentStoreCoordinator *persistentStoreCoordinator;

// Check to see if the cloud store has ever been seeded
@property (nonatomic, readonly) BOOL hasBeenSeeded;

// Default is set to automatic. However, this is broken in iOS 6.1
@property (nonatomic) UbiquityStoreManagerDataMigrationType dataMigrationType;

/**
 *  Start managing an optionally ubiquitous store coordinator.  Default settings will be used.
 */
- (id)init;

/** Start managing an optionally ubiquitous store coordinator.
 *  @param contentName The name of the local and cloud stores that this manager will create.  If nil, "UbiquityStore" will be used.
 *  @param model The managed object model the store should use.  If nil, all the main bundle's models will be merged.
 *  @param localStoreURL The location where the non-ubiquitous (local) store should be kept. If nil, the local store will be put in the application support directory.
 *  @param containerIdentifier The identifier of the ubiquity container to use for the ubiquitous store. If nil, the entitlement's primary container identifier will be used.
 *  @param additionalStoreOptions Additional persistence options that the stores should be initialized with.
 */
- (id)initStoreNamed:(NSString *)contentName withManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL
 containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions;

/**
 * Backward compatibility for earlier release
 */
- (id)initWithManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL
			 containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions;

/**
 * This will delete the local iCloud data for this application.  There is no recovery.  A new iCloud store will be initialized if enabled.
 */
- (void)nukeCloudContainer;

/**
 * This will delete the local store.  There is no recovery.
 */
- (void)deleteLocalStore;

/**
 * This will delete the iCloud store.  Theoretically, it should be rebuilt from the iCloud transaction logs.
 * TODO: Verify claim.
 */
- (void)deleteCloudStore;

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
