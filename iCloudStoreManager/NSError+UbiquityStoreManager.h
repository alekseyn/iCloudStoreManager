//
// Created by lhunath on 2013-03-13.
//
// To change the template use AppCode | Preferences | File Templates.
//


#import <Foundation/Foundation.h>


extern NSString *const UbiquityManagedStoreDidDetectCorruptionNotification;
extern NSString *const StoreCorruptedKey;

@interface NSError(UbiquityStoreManager)

- (id)init_USM_WithDomain:(NSString *)domain code:(NSInteger)code userInfo:(NSDictionary *)dict;

@end
