//
//  AppDelegate.m
//  UbiquityStoreManagerExample
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//

#import <CoreGraphics/CoreGraphics.h>
#import "AppDelegate.h"
#import "MasterViewController.h"
#import "DetailViewController.h"
#import "UbiquityStoreManager.h"
#import "User.h"

@interface AppDelegate ()
@property(nonatomic, strong) UIAlertView *handleCloudContentAlert;

@property(nonatomic, strong) UIAlertView *handleCloudContentWarningAlert;

@property(nonatomic, strong) UIAlertView *handleLocalStoreAlert;
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
    NSLog(@"Starting UbiquityStoreManagerExample on device: %@\n\n", [UIDevice currentDevice].name);

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
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"UbiquityStoreManagerExample" withExtension:@"momd"];
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

    if (alertView == self.handleCloudContentAlert && buttonIndex == [alertView firstOtherButtonIndex]) {
        // Fix Now
        self.handleCloudContentWarningAlert = [[UIAlertView alloc] initWithTitle:@"Fix iCloud Now" message:
                @"This problem can usually be auto‑corrected by opening the app on another device where you recently made changes.\n"
                        @"If you wish to correct the problem from this device anyway, it is possible that recent changes on another device will be lost."
                                                                        delegate:self
                                                               cancelButtonTitle:@"Back"
                                                               otherButtonTitles:@"Fix Anyway", nil];
        [self.handleCloudContentWarningAlert show];
    }

    if (alertView == self.handleCloudContentWarningAlert) {
        if (buttonIndex == alertView.cancelButtonIndex)
                // Back
            [self.handleCloudContentAlert show];

        if (buttonIndex == alertView.firstOtherButtonIndex)
                // Fix Anyway
            [self.ubiquityStoreManager rebuildCloudContentFromCloudStoreOrLocalStore:YES];
    }

    if (alertView == self.handleLocalStoreAlert && buttonIndex == [alertView firstOtherButtonIndex])
        [self.ubiquityStoreManager deleteLocalStore];
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
        
        if (!wasCloudStore && ![self.handleLocalStoreAlert isVisible]) {
            self.handleLocalStoreAlert = [[UIAlertView alloc] initWithTitle:@"Local Store Problem" message:
                    @"Your datastore got corrupted and needs to be recreated."
                                                                   delegate:self
                                                          cancelButtonTitle:nil otherButtonTitles:@"Recreate", nil];
            [self.handleLocalStoreAlert show];
        }
    });
}

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didLoadStoreForCoordinator:(NSPersistentStoreCoordinator *)coordinator isCloud:(BOOL)isCloudStore {

    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    [moc setPersistentStoreCoordinator:coordinator];

    __managedObjectContext = moc;
    __managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.handleCloudContentAlert dismissWithClickedButtonIndex:[self.handleCloudContentAlert firstOtherButtonIndex] + 9
                                                           animated:YES];
        [self.handleCloudContentWarningAlert dismissWithClickedButtonIndex:[self.handleCloudContentWarningAlert firstOtherButtonIndex] + 9
                                                           animated:YES];

        [masterViewController.iCloudSwitch setOn:isCloudStore animated:YES];
        [masterViewController.storeLoadingActivity stopAnimating];
    });
}

- (BOOL)ubiquityStoreManager:(UbiquityStoreManager *)manager handleCloudContentCorruptionWithHealthyStore:(BOOL)storeHealthy {

    if ([self.handleCloudContentAlert isVisible] || [self.handleCloudContentWarningAlert isVisible])
        NSLog(@"already showing.");
    else if (manager.cloudEnabled && !storeHealthy)
        dispatch_async(dispatch_get_main_queue(), ^{
            self.handleCloudContentAlert = [[UIAlertView alloc] initWithTitle:@"iCloud Sync Problem" message:
                    @"\n\n\n\nWaiting for another device to auto‑correct the problem..."
                                                                     delegate:self
                                                            cancelButtonTitle:nil otherButtonTitles:@"Fix Now", nil];
            UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
            activityIndicator.center = CGPointMake( 142, 90 );
            [activityIndicator startAnimating];
            [self.handleCloudContentAlert addSubview:activityIndicator];
            [self.handleCloudContentAlert show];
        });

    return NO;
}

@end
