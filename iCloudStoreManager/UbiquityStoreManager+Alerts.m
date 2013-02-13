//
//  UbiquityStoreManager+Alerts.m
//  iCloudStoreManagerExample
//
//  Created by Aleksey Novicov on 2/12/13.
//  Copyright (c) 2013 Yodel Code LLC. All rights reserved.
//

#import "UbiquityStoreManager+Alerts.h"

#if TARGET_OS_IPHONE
#define OS_Alert UIAlertView
#else
#define OS_Alert NSAlert
#endif

#define MOVE_TO_CLOUD_ALERT_TAG		100
#define SWITCH_TO_CLOUD_ALERT_TAG	101
#define TRY_LATER_ALERT_TAG			102
#define NOT_SIGNED_IN_ALERT_TAG		103
#define SWITCH_TO_LOCAL_ALERT_TAG	104
#define RESET_ALERT_TAG				105

@implementation UbiquityStoreManager (Alerts)

- (void)alertUserWhileEnablingCloudStore:(BOOL)useCloud {
	// To provide the option of using iCloud immediately upon first running of an app,
	// make sure a persistentStoreCoordinator exists.
	
	if ([[NSFileManager defaultManager] ubiquityIdentityToken]) {
		if (useCloud) {
			if (!self.cloudEnabled) {
				NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
				
				// If an iCloud store already exists, ask the user if they want to switch over to iCloud
				if (cloud) {
					if (self.hasBeenSeeded) {
						if ([self.URLForLocalStore checkResourceIsReachableAndReturnError:nil])
							[self switchToCloudDataAlert];
						else
							self.cloudEnabled = YES;
					}
					else {
						if ([self.URLForLocalStore checkResourceIsReachableAndReturnError:nil])
							[self moveDataToCloudAlert];
						else
							self.cloudEnabled = YES;
					}
				}
				else {
					[self tryLaterAlert];
				}
			}
		}
		else {
			if (self.cloudEnabled) {
				if ([self.URLForLocalStore checkResourceIsReachableAndReturnError:nil])
					[self switchToLocalDataAlert];
			}
			else {
				self.cloudEnabled = NO;
			}
		}
	}
	else {
		[self notSignedInAlert];
		[self didSwitchToCloud:NO];
	}
}

#pragma mark - Message Strings

// Subclass UbiquityStoreManager and override these methods if you want to customize these messages

- (NSString *)moveDataToiCloudTitle {
	return @"Move Data to iCloud";
}

- (NSString *)moveDataToiCloudMessage {
	return @"Your data is about to be moved to iCloud. If you prefer to start using iCloud with data from a different device, tap Cancel and enable iCloud from that other device.";
}

- (NSString *)switchDataToiCloudTitle {
	return  @"iCloud Data";
}

- (NSString *)switchDataToiCloudMessage {
	return @"Would you like to switch to using data from iCloud?";
}

- (NSString *)tryLaterTitle {
	return @"iCloud Not Available";
}

- (NSString *)tryLaterMessage {
	return @"iCloud is not currently available. Please try again later.";
}


- (NSString *)notSignedInTitle {
	return @"iCloud Not Configured";
}

- (NSString *)notSignedInMessage {
	return @"Open iCloud Settings, and make sure you are logged in.";
}

- (NSString *)switchToLocalDataTitle {
	return @"Stop Using iCloud";
}

- (NSString *)switchToLocalDataMessage {
	return @"If you stop using iCloud you will switch to using local data on this device only. Your local data is completely separate from iCloud. Any changes you make will not be be synchronized with iCloud.";
}

- (NSString *)hardResetTitle {
	return @"Delete iCloud Data";
}

- (NSString *)hardResetMessage {
	return @"Your iCloud data for this app will be deleted from all of your devices, and you will be switched to using local data specific to each device. Any changes you make will not be be synchronized with iCloud.";
}

#pragma mark - UIAlertView

- (void)alertView:(OS_Alert *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
	if (alertView.tag == MOVE_TO_CLOUD_ALERT_TAG) {
		if (buttonIndex == 1) {
			// Move the data from the local store to the iCloud store
			self.cloudEnabled = YES;
		}
		else {
			[self didSwitchToCloud:NO];
		}
	}
	
	if (alertView.tag == SWITCH_TO_CLOUD_ALERT_TAG) {
		if (buttonIndex == 1) {
			// Switch to using data from iCloud
			self.cloudEnabled = YES;
		}
		else {
			[self didSwitchToCloud:NO];
		}
	}
	
	if (alertView.tag == SWITCH_TO_LOCAL_ALERT_TAG) {
		if (buttonIndex == 1) {
			// Switch to using data from iCloud
			self.cloudEnabled = NO;
		}
		else {
			[self didSwitchToCloud:YES];
		}
	}
	
	if (alertView.tag == RESET_ALERT_TAG) {
		if (buttonIndex == 1) {
			// Proceed with hard reset
			[self nukeCloudContainer];
		}
	}
}

- (void)moveDataToCloudAlert {
#if TARGET_OS_IPHONE
	UIAlertView *moveDataAlert = [[UIAlertView alloc] initWithTitle: [self moveDataToiCloudTitle]
															message: [self moveDataToiCloudMessage]
														   delegate: self
												  cancelButtonTitle: @"Cancel"
												  otherButtonTitles: @"Move Data", nil];
	[moveDataAlert show];
#else
    NSAlert *moveDataAlert = [NSAlert alertWithMessageText: [self moveDataToiCloudTitle]
											 defaultButton: @"Move Data"
										   alternateButton: @"Cancel"
											   otherButton: nil
								 informativeTextWithFormat: [self moveDataToiCloudMessage]];
	
    NSInteger button = [moveDataAlert runModal];
    [self alertView:moveDataAlert didDismissWithButtonIndex:button == NSAlertDefaultReturn? 1: 0];
#endif
	moveDataAlert.tag = MOVE_TO_CLOUD_ALERT_TAG;
}

- (void)switchToCloudDataAlert {
#if TARGET_OS_IPHONE
	UIAlertView *switchToiCloudAlert = [[UIAlertView alloc] initWithTitle: [self switchDataToiCloudTitle]
																  message: [self switchDataToiCloudMessage]
																 delegate: self
														cancelButtonTitle: @"Cancel"
														otherButtonTitles: @"Use iCloud", nil];
	[switchToiCloudAlert show];
#else
    NSAlert *switchToiCloudAlert = [NSAlert alertWithMessageText: [self switchDataToiCloudTitle]
												   defaultButton: @"Use iCloud"
												 alternateButton: @"Cancel"
													 otherButton: nil
									   informativeTextWithFormat: [self switchDataToiCloudMessage]];
	
    NSInteger button = [switchToiCloudAlert runModal];
    [self alertView:switchToiCloudAlert didDismissWithButtonIndex:button == NSAlertDefaultReturn? 1: 0];
#endif
	switchToiCloudAlert.tag = SWITCH_TO_CLOUD_ALERT_TAG;
}

- (void)tryLaterAlert {
#if TARGET_OS_IPHONE
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle: [self tryLaterTitle]
													message: [self tryLaterMessage]
												   delegate: nil
										  cancelButtonTitle: @"Done"
										  otherButtonTitles: nil];
	[alert show];
#else
    NSAlert *alert = [NSAlert alertWithMessageText: [self tryLaterTitle]
									 defaultButton: @"Cancel"
								   alternateButton: nil
									   otherButton: nil
						 informativeTextWithFormat: [self tryLaterMessage]];
    [alert runModal];
#endif
	alert.tag = TRY_LATER_ALERT_TAG;
}

- (void)notSignedInAlert {
#if TARGET_OS_IPHONE
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle: [self notSignedInTitle]
													message: [self notSignedInMessage]
												   delegate: nil
										  cancelButtonTitle: @"Done"
										  otherButtonTitles: nil];
	[alert show];
#else
    NSAlert *alert = [NSAlert alertWithMessageText: [self notSignedInTitle]
									 defaultButton: @"Cancel"
								   alternateButton: nil
									   otherButton: nil
						 informativeTextWithFormat: [self notSignedInMessage]];
    [alert runModal];
#endif
	alert.tag = NOT_SIGNED_IN_ALERT_TAG;
}

- (void)switchToLocalDataAlert {
#if TARGET_OS_IPHONE
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle: [self switchToLocalDataTitle]
													message: [self switchToLocalDataMessage]
												   delegate: self
										  cancelButtonTitle: @"Cancel"
										  otherButtonTitles: @"Continue", nil];
	[alert show];
#else
    NSAlert *alert = [NSAlert alertWithMessageText: [self switchToLocalDataTitle]
									 defaultButton: @"Continue"
								   alternateButton: @"Cancel"
									   otherButton: nil
						 informativeTextWithFormat: [self switchToLocalDataMessage]];
	
    NSInteger button = [alert runModal];
    [self alertView:alert didDismissWithButtonIndex:button == NSAlertDefaultReturn? 1: 0];
#endif
	alert.tag = SWITCH_TO_LOCAL_ALERT_TAG;
}

- (void)resetCloudAlert {
#if TARGET_OS_IPHONE
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle: [self hardResetTitle]
													message: [self hardResetMessage]
												   delegate: self
										  cancelButtonTitle: @"Cancel"
										  otherButtonTitles: @"Continue", nil];
	[alert show];
#else
    NSAlert *alert = [NSAlert alertWithMessageText: [self hardResetTitle]
									 defaultButton: @"Continue"
								   alternateButton: @"Cancel"
									   otherButton: nil
						 informativeTextWithFormat: [self hardResetMessage]];
	
    NSInteger button = [alert runModal];
    [self alertView:alert didDismissWithButtonIndex:button == NSAlertDefaultReturn? 1: 0];
#endif
	alert.tag = RESET_ALERT_TAG;
}

#pragma mark - Convenience methods

- (void)didSwitchToCloud:(BOOL)didSwitch {
	if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didSwitchToiCloud:)]) {
		[self.delegate ubiquityStoreManager:self didSwitchToCloud:didSwitch];
	}
}

#pragma mark - Test methods

- (NSArray *)fileList {
	NSArray *fileList = nil;
	
	NSFileManager *fileManager	= [NSFileManager defaultManager];
	NSURL *cloudURL				= [self URLForCloudContainer];
	
	if (cloudURL)
		fileList = [fileManager subpathsAtPath:[cloudURL path]];
	
	return fileList;
}

@end
