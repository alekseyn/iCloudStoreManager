//
//  UbiquityStoreManager+Alerts.h
//  iCloudStoreManagerExample
//
//  Created by Aleksey Novicov on 2/12/13.
//  Copyright (c) 2013 Yodel Code LLC. All rights reserved.
//

#import "UbiquityStoreManager.h"

@interface UbiquityStoreManager (Alerts)

// If the user has decided to start or stop using iCloud, call this method.
- (void)alertUserWhileEnablingCloudStore:(BOOL)useCloud;

// Reset cloud store with warning
- (void)resetCloudAlert;

// Check with user before seeding and switching to cloud store
- (void)moveDataToCloudAlert;

// Check with user before switching to cloud store
- (void)switchToCloudDataAlert;

// Check with user before switching to local store
- (void)switchToLocalDataAlert;

// Warnings
- (void)tryLaterAlert;
- (void)notSignedInAlert;

// Private methods
- (void)didSwitchToCloud:(BOOL)didSwitch;

// Test methods
- (NSArray *)fileList;

@end
