//
//  MasterViewController.m
//  iCloudStoreManagerExample
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//

#import "MasterViewController.h"
#import "DetailViewController.h"
#import "AppDelegate.h"
#import "UbiquityStoreManager.h"
#import "User.h"

@interface MasterViewController ()
- (void)configureCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath;
@end

@implementation MasterViewController

@synthesize detailViewController = _detailViewController;
@synthesize fetchedResultsController = __fetchedResultsController;
@synthesize managedObjectContext = __managedObjectContext;
@synthesize iCloudSwitch;
@synthesize clearButton;
@synthesize tableHeaderView;

- (IBAction)setiCloudState:(id)sender {
	UISwitch *aSwitch = sender;
	
	// STEP 5a - Set the state of the UbiquityStoreManager to reflect the current UI
	[[[AppDelegate appDelegate] ubiquityStoreManager] useiCloudStore:aSwitch.on alertUser:YES];
}

- (IBAction)cleariCloud:(id)sender {
	iCloudSwitch.on = NO;
	
	// STEP 6 - UbiquityStoreManager hard reset. FOR TESTING ONLY! Do not expose to the end user!
	[[[AppDelegate appDelegate] ubiquityStoreManager] hardResetCloudStorage];
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
		self.title = NSLocalizedString(@"Master", @"Master");
		if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
		    self.clearsSelectionOnViewWillAppear = NO;
		    self.contentSizeForViewInPopover = CGSizeMake(320.0, 600.0);
		}
    }
    return self;
}
							
- (void)reloadFetchedResults:(NSNotification*)note {
	
	// STEP 7a - Do not allow use of any NSManagedObjectContext until UbiquityStoreManager is ready
	
	if ([[AppDelegate appDelegate] ubiquityStoreManager].isReady) {
		
		// Make sure a primary user has been created
		[[AppDelegate appDelegate] primaryUser];
		
		// Refetch the data
		self.fetchedResultsController = nil;		
		[self fetchedResultsController];
		
		if (note) {
			[self.tableView reloadData];
			
			// STEP 5b - Display current state of the UbiquityStoreManager
			BOOL enabled = [[AppDelegate appDelegate] ubiquityStoreManager].iCloudEnabled;
			[iCloudSwitch setOn:enabled animated:YES];
		}
	}
}

- (void)viewDidLoad {
    [super viewDidLoad];
	
	// Do any additional setup after loading the view, typically from a nib.
	self.navigationItem.leftBarButtonItem = self.editButtonItem;

	UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(insertNewObject:)];
	self.navigationItem.rightBarButtonItem = addButton;

	// iCloud support
	[self reloadFetchedResults:nil];
	
	// Observe the app delegate telling us when it's finished asynchronously setting up the persistent store
    [[NSNotificationCenter defaultCenter] addObserver: self
											 selector: @selector(reloadFetchedResults:)
												 name: RefetchAllDatabaseDataNotificationKey
											   object: nil];
	
	self.tableView.tableHeaderView = self.tableHeaderView;

	// STEP 5c - Display current state of the UbiquityStoreManager
	self.iCloudSwitch.on = [[AppDelegate appDelegate] ubiquityStoreManager].iCloudEnabled;
}

- (void)viewDidUnload
{
    [super viewDidUnload];
    // Release any retained subviews of the main view.
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
	if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
	    return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
	} else {
	    return YES;
	}
}

- (void)insertNewObject:(id)sender
{
	NSManagedObjectContext *context = [self.fetchedResultsController managedObjectContext];

	[context performBlockAndWait:^{
		NSEntityDescription *entity = [[self.fetchedResultsController fetchRequest] entity];
		NSManagedObject *newManagedObject = [NSEntityDescription insertNewObjectForEntityForName:[entity name] inManagedObjectContext:context];
		
		User *user = [[[AppDelegate appDelegate] primaryUser] userInContext:context];
		
		// If appropriate, configure the new managed object.
		// Normally you should use accessor methods, but using KVC here avoids the need to add a custom class to the template.
		[newManagedObject setValue:[NSDate date] forKey:@"timeStamp"];
		[newManagedObject setValue:user forKey:@"user"];
		
		// Save the context.
		NSError *error = nil;
		if (![context save:&error]) {
			// Replace this implementation with code to handle the error appropriately.
			// abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development. 
			NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
			abort();
		}
	}];
}

#pragma mark - Table View

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {

	// STEP 7b - Do not allow use of any NSManagedObjectContext until UbiquityStoreManager is ready

	if ([[AppDelegate appDelegate] ubiquityStoreManager].isReady)
		return [[self.fetchedResultsController sections] count];
	else 
		return 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	id <NSFetchedResultsSectionInfo> sectionInfo = [[self.fetchedResultsController sections] objectAtIndex:section];
	return [sectionInfo numberOfObjects];
}

// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *CellIdentifier = @"Cell";
    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }

	[self configureCell:cell atIndexPath:indexPath];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Return NO if you do not want the specified item to be editable.
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSManagedObjectContext *context = [self.fetchedResultsController managedObjectContext];
		
		[context performBlockAndWait:^{
			[context deleteObject:[self.fetchedResultsController objectAtIndexPath:indexPath]];
			
			NSError *error = nil;
			if (![context save:&error]) {
				// Replace this implementation with code to handle the error appropriately.
				// abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development. 
				NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
				abort();
			}
		}];
    }   
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    // The table view should not be re-orderable.
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[self.tableView deselectRowAtIndexPath:indexPath animated:YES];
	
    NSManagedObject *object = [[self fetchedResultsController] objectAtIndexPath:indexPath];
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
	    if (!self.detailViewController) {
	        self.detailViewController = [[DetailViewController alloc] initWithNibName:@"DetailViewController_iPhone" bundle:nil];
	    }
        self.detailViewController.detailItem = object;
        [self.navigationController pushViewController:self.detailViewController animated:YES];
    } else {
        self.detailViewController.detailItem = object;
    }
	self.detailViewController.fileList = [[[AppDelegate appDelegate] ubiquityStoreManager] fileList];
	[self.detailViewController.tableView reloadData];
}

#pragma mark - Fetched results controller

- (NSFetchedResultsController *)fetchedResultsController {

	// STEP 7c - Do not allow use of any NSManagedObjectContext until UbiquityStoreManager is ready

	if (![[AppDelegate appDelegate] ubiquityStoreManager].isReady)
		return nil;

    if (__fetchedResultsController != nil) {
        return __fetchedResultsController;
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    // Edit the entity name as appropriate.
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"Event" inManagedObjectContext:self.managedObjectContext];
    [fetchRequest setEntity:entity];
    
    // Set the batch size to a suitable number.
    [fetchRequest setFetchBatchSize:20];
    
    // Edit the sort key as appropriate.
    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"timeStamp" ascending:NO];
    NSArray *sortDescriptors = [NSArray arrayWithObjects:sortDescriptor, nil];
    
    [fetchRequest setSortDescriptors:sortDescriptors];
    
    // Edit the section name key path and cache name if appropriate.
    // nil for section name key path means "no sections".
    NSFetchedResultsController *aFetchedResultsController = [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:self.managedObjectContext sectionNameKeyPath:nil cacheName:@"Master"];
    aFetchedResultsController.delegate = self;
    self.fetchedResultsController = aFetchedResultsController;
    
	[self.managedObjectContext performBlockAndWait:^{
		NSError *error = nil;
		if (![self.fetchedResultsController performFetch:&error]) {
			// Replace this implementation with code to handle the error appropriately.
			// abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development. 
			NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
			abort();
		}
	}];
    
    return __fetchedResultsController;
}    

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller
{
    [self.tableView beginUpdates];
}

- (void)controller:(NSFetchedResultsController *)controller didChangeSection:(id <NSFetchedResultsSectionInfo>)sectionInfo
           atIndex:(NSUInteger)sectionIndex forChangeType:(NSFetchedResultsChangeType)type
{
    switch(type) {
        case NSFetchedResultsChangeInsert:
            [self.tableView insertSections:[NSIndexSet indexSetWithIndex:sectionIndex] withRowAnimation:UITableViewRowAnimationFade];
            break;
            
        case NSFetchedResultsChangeDelete:
            [self.tableView deleteSections:[NSIndexSet indexSetWithIndex:sectionIndex] withRowAnimation:UITableViewRowAnimationFade];
            break;
    }
}

- (void)controller:(NSFetchedResultsController *)controller didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath
{
    UITableView *tableView = self.tableView;
    
    switch(type) {
        case NSFetchedResultsChangeInsert:
            [tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
            break;
            
        case NSFetchedResultsChangeDelete:
            [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
            break;
            
        case NSFetchedResultsChangeUpdate:
            [self configureCell:[tableView cellForRowAtIndexPath:indexPath] atIndexPath:indexPath];
            break;
            
        case NSFetchedResultsChangeMove:
            [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
            [tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:newIndexPath]withRowAnimation:UITableViewRowAnimationFade];
            break;
    }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
    [self.tableView endUpdates];
}

/*
// Implementing the above methods to update the table view in response to individual changes may have performance implications if a large number of changes are made simultaneously. If this proves to be an issue, you can instead just implement controllerDidChangeContent: which notifies the delegate that all section and object changes have been processed. 
 
 - (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
    // In the simplest, most efficient, case, reload the table view.
    [self.tableView reloadData];
}
 */

- (void)configureCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath
{
    NSManagedObject *object = [self.fetchedResultsController objectAtIndexPath:indexPath];
    cell.textLabel.text = [[object valueForKey:@"timeStamp"] description];
}

@end
