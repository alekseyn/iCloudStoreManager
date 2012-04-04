//
//  AppDelegate.m
//  iCloudStoreManager
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//

#import "AppDelegate.h"
#import "MasterViewController.h"
#import "DetailViewController.h"
#import "User.h"

@interface AppDelegate ()
- (NSURL *)storeURL;
@end


@implementation AppDelegate {
	MasterViewController *masterViewController;
}

@synthesize window						= _window;
@synthesize managedObjectContext		= __managedObjectContext;
@synthesize managedObjectModel			= __managedObjectModel;
@synthesize persistentStoreCoordinator	= __persistentStoreCoordinator;
@synthesize navigationController		= _navigationController;
@synthesize splitViewController			= _splitViewController;
@synthesize ubiquityStoreManager;

+ (AppDelegate *)appDelegate {
	return (AppDelegate *)[[UIApplication sharedApplication] delegate];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	// STEP 1 - Initialize the UbiquityStoreManager
	ubiquityStoreManager = [[UbiquityStoreManager alloc] initWithManagedObjectModel: [self managedObjectModel]
																	  localStoreURL: [self storeURL]];
	
	// STEP 2a  - Setup the delegate
	ubiquityStoreManager.delegate = self;
	
	// For test purposes only. NOT FOR USE IN PRODUCTION
	ubiquityStoreManager.hardResetEnabled = YES;

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    // Override point for customization after application launch.
	if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
	    masterViewController = [[MasterViewController alloc] initWithNibName:@"MasterViewController_iPhone" bundle:nil];
	    self.navigationController = [[UINavigationController alloc] initWithRootViewController:masterViewController];
	    self.window.rootViewController = self.navigationController;
	    masterViewController.managedObjectContext = self.managedObjectContext;
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
	    masterViewController.managedObjectContext = self.managedObjectContext;
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
	// STEP 2b - Check to make sure user has not deleted the iCloud data from Settings
	[self.ubiquityStoreManager checkiCloudStatus];
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

// Returns the managed object context for the application.
// If the context doesn't already exist, it is created and bound to the persistent store coordinator for the application.
- (NSManagedObjectContext *)managedObjectContext {
    
    if (__managedObjectContext != nil) {
        return __managedObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
	
    if (coordinator != nil) {
		NSManagedObjectContext* moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        
        [moc performBlockAndWait:^{
            [moc setPersistentStoreCoordinator: coordinator];
		}];
		
        __managedObjectContext = moc;
 		__managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
	}
    return __managedObjectContext;
}

// Returns the managed object model for the application.
// If the model doesn't already exist, it is created from the application's model.
- (NSManagedObjectModel *)managedObjectModel {
    if (__managedObjectModel != nil) {
        return __managedObjectModel;
    }
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"iCloudStoreManager" withExtension:@"momd"];
    __managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    return __managedObjectModel;
}

- (NSURL *)storeURL {
	return [[self applicationDocumentsDirectory] URLByAppendingPathComponent:@"Sample.sqlite"];
}

// Returns the persistent store coordinator for the application.
// If the coordinator doesn't already exist, it is created and the application's store added to it.
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator {
    if (__persistentStoreCoordinator == nil) {
		
		// STEP 3 - Get the persistentStoreCoordinator from the UbiquityStoreManager
        __persistentStoreCoordinator = [ubiquityStoreManager persistentStoreCoordinator];
    }
    
    return __persistentStoreCoordinator;
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

#pragma mark - UbiquityStoreManagerDelegate

// STEP 4 - Implement the UbiquityStoreManager delegate methods

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager mergeChangesFromiCloud:(NSNotification *)notification {
	NSManagedObjectContext* moc = [self managedObjectContext];
	[ubiquityStoreManager mergeiCloudChanges:notification forContext:moc];
}

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didSwitchToiCloud:(BOOL)didSwitch {
	[masterViewController.iCloudSwitch setOn:didSwitch animated:YES];
}


@end
