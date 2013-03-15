//
// Created by lhunath on 2013-03-13.
//
// To change the template use AppCode | Preferences | File Templates.
//


#import "NSManagedObject+UbiquityStoreManager.h"


@implementation NSError (UbiquityStoreManager)

- (id)init_USM_WithDomain:(NSString *)domain code:(NSInteger)code userInfo:(NSDictionary *)dict {

    self = [self init_USM_WithDomain:domain code:code userInfo:dict];
    if ([domain isEqualToString:NSCocoaErrorDomain] && code == 134302) {
        NSLog(@"Detected iCloud transaction log import failure: %@", self);
        NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
        [cloud setValue:@YES forKeyPath:StoreCorruptedKey];
        [cloud synchronize];

        [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidDetectCorruptionNotification
                                                            object:self];
    }

    return self;
}

@end
