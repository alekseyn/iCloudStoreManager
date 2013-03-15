//
// Created by lhunath on 2013-03-13.
//
// To change the template use AppCode | Preferences | File Templates.
//


#import <Foundation/Foundation.h>

NSString *const UbiquityManagedStoreDidDetectCorruptionNotification = @"UbiquityManagedStoreDidDetectCorruptionNotification";
NSString *const StoreCorruptedKey = @"USMStoreCorruptedKey"; // cloud: Set to YES when a cloud content corruption has been detected.

@interface NSError (UbiquityStoreManager)

- (id)init_USM_WithDomain:(NSString *)domain code:(NSInteger)code userInfo:(NSDictionary *)dict;

@end
