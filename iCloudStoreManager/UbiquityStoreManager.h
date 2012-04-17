//
//  UbiquityStoreManager.h
//  UbiquityStoreManager
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//
// UbiquityStoreManager manages the transfer of your SQL CoreData store from your local
// application sandbox to iCloud. Even though it is not reinforced, UbiquityStoreManager
// is expected to be used as a singleton. This sample code is curently for iOS only.
//
// This class implements a very simple model. Once iCloud is seeded by data from a
// particular device, the iCloud store can never be re-seeded with fresh data.
// However, different devices can repeatedly switch between using their local store
// and the iCloud store. This is not necessarily a recommended practice but is implemented
// this way for testing and learning purposes.
//
// NSUbiquitousKeyValueStore is the mechanism used to discover which iCloud store to use.
// There may be better ways, but for now, that is what is being used.
//
// Use the "Clear iCloud Data" button to reset iCloud data. This hard reset will propagate to all
// devices if the device's app is running. However, there may be a propagation delay of 20 sec. or more.
// or more.

#import <Foundation/Foundation.h>

NSString * const RefetchAllDatabaseDataNotificationKey;
NSString * const RefreshAllViewsNotificationKey;

@class UbiquityStoreManager;

@protocol UbiquityStoreManagerDelegate <NSObject>
- (NSManagedObjectContext *)managedObjectContextForUbiquityStoreManager:(UbiquityStoreManager *)usm;
@optional
- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didSwitchToiCloud:(BOOL)didSwitch;
@end

@interface UbiquityStoreManager : NSObject <UIAlertViewDelegate>

// The delegate confirms when a device has been switched to using either iCloud data or local data
@property (nonatomic, weak) id<UbiquityStoreManagerDelegate> delegate;

// This property indicates whether the iCloud store or the local store is in use. To
// change state of this property, use useiCloudStore: method
@property (nonatomic, readonly) BOOL iCloudEnabled;

// This property indicates when the persistentStoreCoordinator is ready. This property
// is always set immediately before the RefetchAllDatabaseDataNotification is sent.
@property (nonatomic, readonly) BOOL isReady;

// Setting this property to YES is helpful for test purposes. It is highly recommended
// to set this to NO for production deployment
@property (nonatomic) BOOL hardResetEnabled;

// Start by instantiating a UbiquityStoreManager with a managed object model. A valid localStoreURL
// is also required even if iCloud support is not currently enabled for this device. If it is enabled,
// it is required in case the user disables iCloud support for this device. If iCloud support is disabled
// after being initially enabled, the store on iCloud is NOT migrated back to the local device.
- (id)initWithManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)storeURL;

// Always use this method to instantiate or retrieve the main persistentStoreCoordinator.
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator;

// If the user has decided to start using iCloud, call this method. And vice versa.
- (void)useiCloudStore:(BOOL)willUseiCloud;

// Reset iCloud data. Intended for test purposes only
- (void)hardResetCloudStorage;

// Checks iCloud to ensure user has not deleted all iCloud data (nuke all use case).
// If the iCloud data has been deleted from within the Settings app or Mac System Preferences,
// iCloud will be disabled and the active store will be switched over to local store
- (void)checkiCloudStatus;

// Array of all files and directorys in the ubiquity store. Useful for testing
- (NSArray *)fileList;

// File URL for the currently selected store
- (NSURL *)currentStoreURL;

@end
