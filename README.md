
iCloudStoreManager Notes - Updated June 16, 2012

INTRODUCTION

This standalone iOS project demonstrates using iCloud to sync a CoreData store between different iOS devices, what is often referred to as a Shoebox-style app. It must be run on an actual iOS device.

CHANGES

June 16, 2012
1. NSLog messages completely removed from UbiquityStoreManager. To view log messages or errors, simply implement the corresponding delegate method.
2. A warning message has been added when destructively deleting the iCloud store (i.e., when tapping the "Clear iCloud Data" button).
3. NSFileCoordinator is now used to coordinate the deletion of transaction logs when an iCloud store is deleted.
4. iCloud is now automatically disabled when a user deletes their iCloud data using iCloud System Preferences (on a Mac) or iCloud Settings (on an iOS device)
5. Version number bumped up to 1.1.
6. Min. deployment target set to 5.1 (recommended by Apple engineers)

USING THE APP

To run the app you will first need to setup the iCloud entitlements. If you are not familiar with this, there is an excellent discussion here: http://oleb.net/blog/2011/11/ios5-tech-talk-michael-jurewitz-on-icloud-storage/

After installing the app on at least two devices. Generate a few lines of data by tapping the + symbol. Then tap the iCloud switch to ON. After anywhere from 10 seconds to 10 minutes you should see the second device's iCloud switch automatically switch ON, and the data on both devices should now be the same. Add new data, or delete data by swiping, on any device to observe how the data stays in sync. However, be prepared to see propagation delays that can be many minutes.

You can also try switching iCloud OFF and ON on either device to see how it can easily be switched between local data and iCloud data.

THE UX MODEL

The user experience model follows a very simple set of rules. An iCloud switch is required so that users can control from which device they seed iCloud. This is important because once an iCloud store is seeded with data, it should not be seeded again.

1. A user can seed iCloud with a baseline set of data from any device.
2. Once iCloud is seeded from one device, other devices are automatically enabled to use iCloud using the seeded data. This may take anywhere from 10 seconds to 10 minutes. My experience with iCloud is that it can be very slow.
3. If a user attempts to seed iCloud from multiple devices at the same time, the last device to seed iCloud with data wins.
4. A user can at any time disable iCloud from within the app. That will switch the app from the iCloud store to the local data store. These stores are completely separate and independent.
5. A user can at any time enable iCloud from within the app. That will switch the app from using the local data store to the iCloud store.

For test purposes ONLY, tapping the Clear iCloud Data button will delete all iCloud data from all devices (it may take many seconds or many minutes for this action to propagate to other devices). Each individual device will be automatically switched to using it's local data, and iCloud disabled within the app.

USING UbiquityStoreManager

The goal was to implement the simplest possible API. Apple's instructions on how to use Core Data with iCloud are deceivingly simple. Hopefully this class will make it truly simple and straightforward.

To implement this same functionality in your own app, all you need is UbiquityStoreManager.h and UbiquityStoreManager.m.  There are roughly 7+ steps required in configuring and using UbiquityStoreManager. Search for STEP to find examples of all of the changes you will likely need to make it work in your own project.

This class includes alert messages to assist the user in making the appropriate choices when enabling or disabling iCloud.

The three most important methods are listed here:

1. Use this method to create and initialize a single instance in your app delegate class:

- (id)initWithManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)storeURL;

2. Instead of creating your own persistent coordinator, you must use the one supplied by UbiquityStoreManager.

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator;

3. And to switch between using the iCloud store and the local data store, call this method.

- (void)useiCloudStore:(BOOL)willUseiCloud;

However, using just these three methods is not sufficient for Core Data to function properly with iCloud. Please look at the source code to see all of the other methods and properties required.

TESTING AND KNOWN PROBLEMS

This has been tested out on an iPhone 4, iPhone 4S, original iPad, iPad 2, and the new iPad (3rd generation). Everything has been tested with up to five devices and works well in most cases. However, changes may sometimes take many minutes to propagate, leading you to think it's not working. But all of the devices will eventually sync up. Using iOS 5.1 is better than using iOS 5.0.

iCloudStoreManager is released under the New BSD License.

Copyright (c) 2012, Yodel Code LLC
All rights reserved.
