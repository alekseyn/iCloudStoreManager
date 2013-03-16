//
//  AppDelegate.m
//  iCloudStoreManagerExample
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//

#import "AppDelegate.h"
#import "MasterViewController.h"
#import "DetailViewController.h"
#import "UbiquityStoreManager.h"
#import "User.h"

@interface AppDelegate ()
@property(nonatomic, strong) UIAlertView *handleCloudContentAlert;

- (NSURL *)storeURL;
@end


@implementation AppDelegate {
	MasterViewController *masterViewController;
}

@synthesize window						= _window;
@synthesize managedObjectContext		= __managedObjectContext;
@synthesize managedObjectModel			= __managedObjectModel;
@synthesize navigationController		= _navigationController;
@synthesize splitViewController			= _splitViewController;
@synthesize ubiquityStoreManager;

+ (AppDelegate *)appDelegate {
	return (AppDelegate *)[[UIApplication sharedApplication] delegate];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	// STEP 1 - Initialize the UbiquityStoreManager
	ubiquityStoreManager = [[UbiquityStoreManager alloc] initStoreNamed:nil withManagedObjectModel:[self managedObjectModel]
                                                          localStoreURL:[self storeURL] containerIdentifier:nil additionalStoreOptions:nil
                                                               delegate:self];
	
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    // Override point for customization after application launch.
	if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
	    masterViewController = [[MasterViewController alloc] initWithNibName:@"MasterViewController_iPhone" bundle:nil];
	    self.navigationController = [[UINavigationController alloc] initWithRootViewController:masterViewController];
	    self.window.rootViewController = self.navigationController;
	} else {
	    masterViewController = [[MasterViewController alloc] initWithNibName:@"MasterViewController_iPad" bundle:nil];
	    UINavigationController *masterNavigationController = [[UINavigationController alloc] initWithRootViewController:masterViewController];
	    
	    DetailViewController *detailViewController = [[DetailViewController alloc] initWithNibName:@"DetailViewController_iPad" bundle:nil];
	    UINavigationController *detailNavigationController = [[UINavigationController alloc] initWithRootViewController:detailViewController];
		
		masterViewController.detailViewController = detailViewController;
	    
	    self.splitViewController = [[UISplitViewController alloc] init];
	    self.splitViewController.delegate = detailViewController;
	    self.splitViewController.viewControllers = [NSArray arrayWithObjects:masterNavigationController, detailNavigationController, nil];
	    
	    self.window.rootViewController = self.splitViewController;
	}
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
	// Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
	// Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	// Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
	// If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	// Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	// Saves changes in the application's managed object context before the application terminates.
	[self saveContext];
}

- (void)saveContext {
    NSManagedObjectContext *managedObjectContext = self.managedObjectContext;
	
    if (managedObjectContext != nil) {
        if ([managedObjectContext hasChanges]) {
			[managedObjectContext performBlockAndWait:^{
				NSError *error = nil;

				if (![managedObjectContext save:&error]) {
					// Replace this implementation with code to handle the error appropriately.
					// abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development. 
					NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
					abort();
				}
			}];
        } 
    }
}

#pragma mark - Core Data stack

// Returns the managed object model for the application.
// If the model doesn't already exist, it is created from the application's model.
- (NSManagedObjectModel *)managedObjectModel {
    if (__managedObjectModel != nil) {
        return __managedObjectModel;
    }
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"iCloudStoreManagerExample" withExtension:@"momd"];
    __managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    return __managedObjectModel;
}

- (NSURL *)storeURL {
	return [[self applicationDocumentsDirectory] URLByAppendingPathComponent:@"Sample.sqlite"];
}

#pragma mark - Application's Documents directory

// Returns the URL to the application's Documents directory.
- (NSURL *)applicationDocumentsDirectory
{
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
}

#pragma mark - Entities

- (User *)primaryUser {
	// Make sure there is an primary user
	User *primaryUser = [User primaryUserInContext:self.managedObjectContext];
	if (!primaryUser) {			
		// Create and save the default user
		primaryUser = [User insertedNewUserInManagedObjectContext:self.managedObjectContext];
		primaryUser.primary = YES;
		[self saveContext];
    }
	return primaryUser;
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {

    if (alertView == self.handleCloudContentAlert) {
        if (buttonIndex == [alertView firstOtherButtonIndex])
            // Disable iCloud
            self.ubiquityStoreManager.cloudEnabled = NO;
        else if (buttonIndex == [alertView firstOtherButtonIndex] + 1)
            // Lose iCloud data
            [self.ubiquityStoreManager deleteCloudStoreLocalOnly:NO];
        else if (buttonIndex == [alertView firstOtherButtonIndex] + 2)
            // Make iCloud local
            [self.ubiquityStoreManager migrateCloudToLocalAndDeleteCloudStoreLocalOnly:NO];
        else if (buttonIndex == [alertView firstOtherButtonIndex] + 3)
            // Fix iCloud
            [self.ubiquityStoreManager rebuildCloudContentFromCloudStore];
    }
}


#pragma mark - UbiquityStoreManagerDelegate

// STEP 4 - Implement the UbiquityStoreManager delegate methods
- (NSManagedObjectContext *)managedObjectContextForUbiquityChangesInManager:(UbiquityStoreManager *)manager {
    return self.managedObjectContext;
}

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager willLoadStoreIsCloud:(BOOL)isCloudStore {

    __managedObjectContext = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [masterViewController.iCloudSwitch setOn:isCloudStore animated:YES];
        [masterViewController.storeLoadingActivity startAnimating];
    });
}

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager failedLoadingStoreWithCause:(UbiquityStoreErrorCause)cause context:(id)context wasCloud:(BOOL)wasCloudStore {

    dispatch_async(dispatch_get_main_queue(), ^{
        [masterViewController.storeLoadingActivity stopAnimating];
    });
    manager.cloudEnabled = NO;
}

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didLoadStoreForCoordinator:(NSPersistentStoreCoordinator *)coordinator isCloud:(BOOL)isCloudStore {

    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    [moc setPersistentStoreCoordinator:coordinator];

    __managedObjectContext = moc;
    __managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.handleCloudContentAlert isVisible])
            [self.handleCloudContentAlert dismissWithClickedButtonIndex:[self.handleCloudContentAlert cancelButtonIndex]
                                                               animated:YES];

        [masterViewController.iCloudSwitch setOn:isCloudStore animated:YES];
        [masterViewController.storeLoadingActivity stopAnimating];
    });
}

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager handleCloudContentCorruptionIsCloud:(BOOL)isCloudStore {

    dispatch_async(dispatch_get_main_queue(), ^{
        self.handleCloudContentAlert = [[UIAlertView alloc] initWithTitle:@"Problem With iCloud Sync!" message:
                @"An error has occurred within Apple's iCloud causing your devices to no longer "
                        @"sync up properly.\n"
                        @"To fix this, you can either:\n"
                        @"- Disable iCloud\n"
                        @"- Lose your iCloud data and start anew using your local data\n"
                        @"- Make iCloud local and disable iCloud sync\n"
                        @"- Fix iCloud sync\n\n"
                        @"If you 'Make iCloud local', iCloud data will overwrite any local data you may have.\n\n"
                        @"If you 'Fix iCloud' (same as 'Make iCloud local' and turning iCloud sync on again later), "
                        @"be mindful on what device you do this on:  Any changes on other devices that failed to sync "
                        @"will be lost."
                                                                 delegate:self cancelButtonTitle:nil
                                                        otherButtonTitles:@"Disable iCloud", @"Lose iCloud data", @"Make iCloud local", @"Fix iCloud", nil];
        [self.handleCloudContentAlert show];
    });
}

@end
