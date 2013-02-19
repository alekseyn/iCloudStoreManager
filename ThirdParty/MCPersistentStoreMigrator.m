// Copyright (c) 2012 The Mental Faculty BV.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
// Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
// Neither the name of The Mental Faculty BV nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import <CoreData/CoreData.h>

#import "MCPersistentStoreMigrator.h"

@interface MCPersistentStoreMigrator ()

-(BOOL)save:(NSError **)error;

@end

@implementation MCPersistentStoreMigrator {
    NSMutableDictionary *migratedIDsBySourceID;
    NSMutableDictionary *excludedRelationshipsByEntity;
    NSManagedObjectContext *destinationContext, *sourceContext;
    NSPersistentStore *sourceStore, *destinationStore;
    NSManagedObjectModel *originalManagedObjectModel;
    NSMutableArray *sourceObjectIDsOfUnsavedCounterparts;
}

@synthesize managedObjectModel;
@synthesize destinationStoreURL, sourceStoreURL;
@synthesize sourceStoreOptions, destinationStoreOptions;

-(id)initWithManagedObjectModel:(NSManagedObjectModel *)model sourceStoreURL:(NSURL *)newSourceURL destinationStoreURL:(NSURL *)newDestinationURL
{
    self = [super init];
    if ( self ) {
        destinationContext = nil;
        sourceContext = nil;
        originalManagedObjectModel = model;
        sourceStoreURL = [newSourceURL copy];
        destinationStoreURL = [newDestinationURL copy];
        excludedRelationshipsByEntity = [[NSMutableDictionary alloc] initWithCapacity:10];
        sourceStoreOptions = [NSDictionary dictionaryWithObject:(id)kCFBooleanTrue forKey:NSReadOnlyPersistentStoreOption];
    }
    return self;
}

-(void)setupContexts
{    
    // Destination context
    NSError *error;
    NSPersistentStoreCoordinator *destinationCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:managedObjectModel];
    [destinationCoordinator lock];
    destinationStore = [destinationCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:destinationStoreURL options:destinationStoreOptions error:&error];
    [destinationCoordinator unlock];
    NSAssert(destinationStore != nil, @"Destination Store was nil: %@", error);
    destinationContext = [[NSManagedObjectContext alloc] init];
    destinationContext.persistentStoreCoordinator = destinationCoordinator;
    
    // Source context
    NSPersistentStoreCoordinator *sourceCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:managedObjectModel];
    [sourceCoordinator lock];
    sourceStore = [sourceCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:sourceStoreURL options:sourceStoreOptions error:&error];
    [sourceCoordinator unlock];
    NSAssert(sourceStore != nil, @"Source Store was nil: %@", error);
    sourceContext = [[NSManagedObjectContext alloc] init];
    sourceContext.persistentStoreCoordinator = sourceCoordinator;
    
    // Copy metadata
    NSMutableDictionary *metadata = [[sourceCoordinator metadataForPersistentStore:sourceStore] mutableCopy];
    [metadata addEntriesFromDictionary:[destinationCoordinator metadataForPersistentStore:destinationStore]];
    [destinationCoordinator setMetadata:metadata forPersistentStore:destinationStore];
}

-(void)beginMigration
{
    managedObjectModel = [originalManagedObjectModel copy];
    [self setupContexts];
    migratedIDsBySourceID = [[NSMutableDictionary alloc] initWithCapacity:500];
    sourceObjectIDsOfUnsavedCounterparts = [NSMutableArray arrayWithCapacity:500];
}

-(void)endMigration
{
    sourceStore = nil;
    destinationStore = nil;
    [destinationContext reset];
    [sourceContext reset];
    destinationContext = nil;
    sourceContext = nil;
    migratedIDsBySourceID = nil;
    sourceObjectIDsOfUnsavedCounterparts = nil;
}

-(BOOL)save:(NSError **)error
{
    BOOL success = [self saveDestinationContext:error];
    [destinationContext reset];
    [sourceContext reset];
    return success;
}

-(BOOL)saveDestinationContext:(NSError **)error
{
    // Get permanent object ids
    NSMutableArray *unsavedObjects = [NSMutableArray arrayWithCapacity:sourceObjectIDsOfUnsavedCounterparts.count];
    for ( id sourceID in sourceObjectIDsOfUnsavedCounterparts ) {
        id unsavedObject = [destinationContext objectWithID:[migratedIDsBySourceID objectForKey:sourceID]];
        [unsavedObjects addObject:unsavedObject];
    }
    
    if ( ![destinationContext obtainPermanentIDsForObjects:unsavedObjects error:error] ) return NO;
    
    NSEnumerator *unsavedObjectsEnum = [unsavedObjects objectEnumerator];
    for ( id sourceID in sourceObjectIDsOfUnsavedCounterparts ) {
        NSManagedObject *unsavedObject = [unsavedObjectsEnum nextObject];
        [migratedIDsBySourceID setObject:unsavedObject.objectID forKey:sourceID];
    }
    sourceObjectIDsOfUnsavedCounterparts = [NSMutableArray arrayWithCapacity:500];
     
    // Save
    if ( [destinationContext hasChanges] ) return [destinationContext save:error];
    
    return YES;
}

-(BOOL)migrateEntityWithName:(NSString *)entityName batchSize:(NSUInteger)batchSize save:(BOOL)save error:(NSError **)error
{    
    NSEntityDescription *entity = [managedObjectModel.entitiesByName objectForKey:entityName];
    NSFetchRequest *fetch = [[NSFetchRequest alloc] initWithEntityName:entityName];
    fetch.fetchBatchSize = batchSize;
    fetch.relationshipKeyPathsForPrefetching = entity.relationshipsByName.allKeys;

    NSArray *sourceObjects = [sourceContext executeFetchRequest:fetch error:error];
    if ( !sourceObjects ) return NO;
    
    NSUInteger i = 0;
    while ( i < sourceObjects.count ) {
        @autoreleasepool {
            NSManagedObject *rootObject = [sourceObjects objectAtIndex:i];
            [self migrateRootObject:rootObject];
            i++;
            if ( batchSize && (i % batchSize == 0) && save ) {
                if ( ![self save:error] ) return NO;
            }
        }
    }
    
    BOOL success = YES;
    if ( save ) success = [self save:error];
    
    return success;
}

-(void)snipRelationship:(NSString *)relationshipKey inEntity:(NSString *)entityName
{
    NSMutableSet *excludes = [excludedRelationshipsByEntity objectForKey:entityName];
    if ( !excludes ) excludes = [NSMutableSet set];
    [excludes addObject:relationshipKey];
    [excludedRelationshipsByEntity setObject:excludes forKey:entityName];
}

-(id)migrateRootObject:(NSManagedObject *)rootObject
{
    if ( !rootObject ) return nil;
    
    NSManagedObjectID *counterpartID = [migratedIDsBySourceID objectForKey:rootObject.objectID];
    if ( counterpartID ) return [destinationContext objectWithID:counterpartID];
    
    NSManagedObject *counterpart;
    
    @autoreleasepool {
        // Create counterpart
        NSEntityDescription *entity = rootObject.entity;
        counterpart = [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:destinationContext];
        
        // Add to mapping
        [migratedIDsBySourceID setObject:counterpart.objectID forKey:rootObject.objectID];
        [sourceObjectIDsOfUnsavedCounterparts addObject:rootObject.objectID];
        
        // Set attributes
        NSArray *attributeKeys = entity.attributesByName.allKeys;
        for ( NSString *key in attributeKeys ) {
            [counterpart setPrimitiveValue:[rootObject primitiveValueForKey:key] forKey:key];
        }
        
        // Set relationships recursively
        NSSet *exclusions = [excludedRelationshipsByEntity objectForKey:entity.name];
        for ( NSRelationshipDescription *relationDescription in entity.relationshipsByName.allValues ) {
            NSString *key = relationDescription.name;
            if ( [exclusions containsObject:key] ) continue;
            id newValue = nil;
            if ( relationDescription.isToMany ) {
                newValue = [[counterpart primitiveValueForKey:key] mutableCopy];
                for ( NSManagedObject *destinationObject in [rootObject primitiveValueForKey:key] ) {
                    NSManagedObject *destinationCounterpart = [self migrateRootObject:destinationObject];
                    [newValue addObject:destinationCounterpart];
                }
            }
            else {            
                NSManagedObject *destinationObject = [rootObject primitiveValueForKey:key];
                newValue = ( destinationObject ? [self migrateRootObject:destinationObject] : nil );
            }
            
            // If the inverse relationship is snipped, use the full KVC methods, so that it gets set too
            if ( [exclusions containsObject:relationDescription.inverseRelationship.name] ) 
                [counterpart setValue:newValue forKey:key];
            else 
                [counterpart setPrimitiveValue:newValue forKey:key];
        }
    }

    return counterpart;
}

-(BOOL)stitchRelationship:(NSString *)relationshipName inEntity:(NSString *)entityName save:(BOOL)save error:(NSError **)error
{
    const NSInteger batchSize = 100;
    
    NSEntityDescription *entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:sourceContext];
    NSRelationshipDescription *relationshipDescription = [entity.relationshipsByName objectForKey:relationshipName];
    
    NSFetchRequest *fetch = [[NSFetchRequest alloc] init];
    NSEntityDescription *fetchEntity = [NSEntityDescription entityForName:entityName inManagedObjectContext:sourceContext];
    fetch.entity = fetchEntity;
    fetch.fetchBatchSize = batchSize;
    
    NSArray *sourceObjects = [sourceContext executeFetchRequest:fetch error:error];
    if ( !sourceObjects ) return NO;
    
    NSInteger i = 0;
    for ( NSManagedObject *sourceObject in sourceObjects ) {
        @autoreleasepool {
            NSManagedObjectID *counterpartID = [migratedIDsBySourceID objectForKey:sourceObject.objectID];
            NSAssert(counterpartID != nil, @"Could not find counterpart for object in stitchRelationship:...\nSource Object: %@", sourceObject);
            NSManagedObject *counterpart = (id)[destinationContext objectWithID:counterpartID];
            
            if ( relationshipDescription.isToMany ) {
                id container = [[counterpart valueForKey:relationshipName] mutableCopy];
                for ( NSManagedObject *destinationObject in [sourceObject valueForKey:relationshipName] ) {
                    NSManagedObjectID *destinationCounterpartID = [migratedIDsBySourceID objectForKey:destinationObject.objectID];
                    NSManagedObject *destinationCounterpart = (id)[destinationContext objectWithID:destinationCounterpartID];
                    [container addObject:destinationCounterpart];
                }
                [counterpart setValue:container forKey:relationshipName];
            }
            else {
                NSManagedObject *destinationObject = [sourceObject valueForKey:relationshipName];
                if ( destinationObject ) {
                    NSManagedObjectID *destinationCounterpartID = [migratedIDsBySourceID objectForKey:destinationObject.objectID];
                    NSAssert(destinationCounterpartID != nil, @"A destination object was missing in migration");
                    NSManagedObject *destinationCounterpart = (id)[destinationContext objectWithID:destinationCounterpartID];
                    [counterpart setValue:destinationCounterpart forKey:relationshipName];
                }
            }
            
            if ( ++i % batchSize == 0 && save ) {
                if ( ![self save:error] ) return NO;
            }
        }
    }
    
    BOOL success = YES;
    if ( save ) success = [self save:error];
    
    return success;
}

@end


