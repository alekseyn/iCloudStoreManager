//
//  User.m
//  iCloudStoreManagerExample
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//

#import "User.h"
#import "AppDelegate.h"

@implementation User

@dynamic timestamp;
@dynamic primary;
@dynamic events;

+ (User *)primaryUserInContext:(NSManagedObjectContext *)context {
	User *user = nil;
	NSManagedObjectModel *model = [AppDelegate appDelegate].managedObjectModel;
	
	NSFetchRequest *fetchRequest = [[model fetchRequestTemplateForName:@"primaryUser"] copy];
	
	NSError *error;
	NSArray *results = [context executeFetchRequest:fetchRequest error:&error];
	if (results && [results count] > 0) {
		user = [results objectAtIndex:0];
	}
	return user;
}

+ (User *)insertedNewUserInManagedObjectContext:(NSManagedObjectContext *)context {
	return [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([User class]) inManagedObjectContext:context];
}

- (User *)userInContext:(NSManagedObjectContext *)context {
	if (context == self.managedObjectContext) {
		return self;
	}
	else {
		return (User *)[context objectWithID:[self objectID]];
	}
}

@end
