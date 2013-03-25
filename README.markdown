# About

`UbiquityStoreManager` is a controller that implements iCloud integration with Core Data for you.

While Apple portrays iCloud integration as trivial, the contrary is certainly true.  Especially for Core Data, there are many caveats, side-effects and undocumented behaviors that need to be handled to get a reliable implementation.

Unfortunately, Apple also has a bunch of serious bugs left to work out in this area, which can sometimes lead to cloud stores that become desynced or even irreparably broken.  `UbiquityStoreManager` handles these situations as best as possible.

The API has been kept as simple as possible while giving you, the application developer, the hooks you need to get the behavior you want.  Wherever possible, `UbiquityStoreManager` implements safe and sane default behavior to handle exceptional situations.  These cases are well documented in the API documentation, as well as your ability to plug into the manager and implement your own custom behavior.

# Getting Started

To get started with `UbiquityStoreManager`, all you need to do is instantiate it:

    [[UbiquityStoreManager alloc] initStoreNamed:nil
                          withManagedObjectModel:nil
                                   localStoreURL:nil
                             containerIdentifier:nil
                          additionalStoreOptions:nil
                                        delegate:self]

And then wait in your delegate for the manager to bring up your persistence layer:

    - (void)ubiquityStoreManager:(UbiquityStoreManager *)manager willLoadStoreIsCloud:(BOOL)isCloudStore {
    
        self.moc = nil;
    }
    
    - (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didLoadStoreForCoordinator:(NSPersistentStoreCoordinator *)coordinator isCloud:(BOOL)isCloudStore {
        self.moc = [[NSManagedObjectContext alloc]
                initWithConcurrencyType:NSMainQueueConcurrencyType];
        [moc setPersistentStoreCoordinator:coordinator];
        [moc setMergePolicy:NSMergeByPropertyObjectTrumpMergePolicy];
    }

That’s it!  The manager set up your `NSPersistentStoreCoordinator`, you created an `NSManagedObjectContext`, you’re ready to go.

Just keep in mind, as aparent from the code above, that your `moc` can be `nil`.  This happens when the manager is not (yet) ready with loading the store.  It can also occur after the store has been loaded (eg. cloud is turned on/off or the store needs to be re-loaded).  So just make sure that your application deals gracefully with your main `moc` being unavailable.

Initially, the manager will be using a local store.  To enable iCloud (you may want to do this after the user toggles iCloud on), just flip the switch:

    manager.cloudEnabled = YES;

# Surely I’m not done yet!

That depends on how much you want to get involved with what `UbiquityStoreManager` does internally to handle your store, and how much feedback you want to give your user with regards to what’s going on.

For instance, you may want to implement visible feedback for while persistence is unavailable (eg. show an overlay with a loading spinner).  You’d bring this spinner up in `-ubiquityStoreManager:willLoadStoreIsCloud:` and dismiss it in `-ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:`.

It’s probably also a good idea to update your main `moc` whenever ubiquity changes are getting imported into your store from other devices.  To do this, simply provide the manager with your `moc` by returning it from `-managedObjectContextForUbiquityChangesInManager:` and optionally register an observer for `UbiquityManagedStoreDidImportChangesNotification`.

# What if things go wrong?

And don’t be fooled: Things do go wrong.  Apple has a few kinks to work out, some of these can cause the cloud store to become irreparably desynced.

`UbiquityStoreManager` does its best to deal with these issues, mostly automatically.  Because the manager takes great care to ensure no data-loss occurs there are some rare cases where the store cannot be automatically salvaged.  It is therefore important that you implement some failure handling, at least in the way recommended by the manager.

While it theoretically shouldn’t happen, sometimes ubiquity changes designed to sync your cloud store with the store on other devices can be incompatible with your cloud store.  Usually, this happens due to an Apple bug in dealing with relationships that are simultaneously edited from different devices, causing conflicts that can’t be handled.  Interestingly, the errors happen deep within Apple’s iCloud implementation and doesn’t bother to notify you through any public API.  `UbiquityStoreManager` implements a way of detecting these issues when they occur and deals with them as best as it can.  

Whenever problems occur with importing transaction logs (ubiquity changes), your application can be notified and optionally intervene by implementing `-ubiquityStoreManager:handleCloudContentCorruptionWithHealthyStore:` in your delegate.  If you just want to be informed and let the manager handle the situation, return `NO`.  If you want to handle the situation in a different way than what the manager does by default, return `YES` after dealing with the problem yourself.

Essentially, the manager deals with import exceptions by unloading the store on the device where ubiquity changes conflict with the store and notifying all other devices that the store has entered a **”corrupted”** state.  Other devices may not experience any errors (they may be the authors of the corrupting logs, or they may not experience conflicts between their store and the logs).  When any of these **healthy** devices receive word of the store corruption, they will initiate a store rebuild causing a brand new cloud store to be created populated by the old cloud store’s entities.  At this point, all devices will switch over to the new cloud store and the corruption state will be cleared.

You are recommended to implement `-ubiquityStoreManager:handleCloudContentCorruptionWithHealthyStore:` by returning `NO` but informing the user of what is going on.  Here’s an example implementation that displays an alert for the user if his device needs to wait for another device to fix the corruption:

    - (BOOL)ubiquityStoreManager:(UbiquityStoreManager *)manager
            handleCloudContentCorruptionWithHealthyStore:(BOOL)storeHealthy {
    
        if (![self.cloudAlert isVisible] && manager.cloudEnabled && !storeHealthy)
            dispatch_async( dispatch_get_main_queue(), ^{
                self.cloudAlert = [[UIAlertView alloc]
                        initWithTitle:@"iCloud Sync Problem"
                              message:@"\n\n\n\n"
                    @"Waiting for another device to auto‑correct the problem..."
                             delegate:self
                    cancelButtonTitle:nil otherButtonTitles:@"Fix Now", nil];
                UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc]
                        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
                activityIndicator.center = CGPointMake( 142, 90 );
                [activityIndicator startAnimating];
                [self.cloudAlert addSubview:activityIndicator];
                [self.cloudAlert show];
            } );
    
        return NO;
    }

The above code gives the user the option of hitting the `Fix Now` button, which would invoke `[manager rebuildCloudContentFromCloudStoreOrLocalStore:YES]`.  Essentially, it initiates the cloud store rebuild locally.  More about this later.

Your app can now deal with Apple’s iCloud bugs, congratulations!

Unless you want to get into the deep water, ***you’re done now***.  What follows is for brave souls or those seeking for maximum control.

# What else have you got?

Since this is murky terrain, `UbiquityStoreManager` tries its best to keep interested delegates informed of what’s going on, and even gives it the ability to intervene in non-standard ways.

If you use a logger, you can plug it in by implementing `-ubiquityStoreManager:log:`.  This method is called whenever the manager has something to say about what it’s doing.  We’re pretty verbose, so you may even want to implement this just to shut the manager up in production.

If you’re interested in getting the full details about any error conditions, implement `-ubiquityStoreManager:didEncounterError:cause:context:` and you shall receive.

If the cloud content gets deleted, the manager unloads the persistence stores.  This may happen, for instance, if the user has gone into `Settings` and deleted the iCloud data for your app, possibly in an attempt to make space on his iCloud account.  By default, this will leave your app without any persistence until the user restarts the app.  If iCloud is still enabled in the app, a new store will be created for him.  You could handle this a little differently, depending on what you think is right: You may want to just display a message to the user asking him whether he wants iCloud disabled or re-enabled.  Or you may want to just disable iCloud and switch to the local store.  You would handle this from `-ubiquityStoreManagerHandleCloudContentDeletion:`.

If you read the previous section carefully, you should understand that problems may occur during the importing of ubiquitous changes made by other devices.  The default way of handling the situation can usually automatically resolve the situation but may take some time to completely come about and may involve user interaction.  You may choose to handle the situation differently by implementing `-ubiquityStoreManager:handleCloudContentCorruptionWithHealthyStore:` and returning `YES` after dealing with the corruption yourself.  The manager provides the following methods for you, which you can use for some low-level maintenance of the stores:
    * `-reloadStore` — Just clear and re-open or retry opening the active store.
    * `-deleteCloudContainerLocalOnly:` — All iCloud data for your application will be deleted.  That’s ***not just your Core Data store***!
    * `-deleteCloudStoreLocalOnly:` — Your Core Data cloud store will be deleted.
    * `-deleteLocalStore` — This will delete your local Core Data store (ea. the store that’s active when `manager.cloudEnabled = NO`).
    * `-migrateCloudToLocalAndDeleteCloudStoreLocalOnly:` — Use this method to stop using iCloud but migrate all cloud data into the local store.
    * `-rebuildCloudContentFromCloudStoreOrLocalStore:` — This is where the cloud store rebuild magic happens.  Invoke this method to create a new cloud store and copy your current cloud data into it.

Many of these methods take a `localOnly` parameter.  Set it to `YES` if you don’t want to affect the user’s iCloud data.  The operation will happen on the local device only.  For instance, if you run `[manager deleteCloudStoreLocalOnly:YES]`, the cloud store on the device will be deleted.  If `cloudEnabled` is `YES`, the manager will subsequently re-open the cloud store which will cause a re-download of all iCloud’s transaction logs for the store.  These transaction logs will then get replayed locally causing your local store to be repopulated from what’s in iCloud.

# Disclaimer

I provide `UbiquityStoreManager` and its example application to you for free and do not take any responsability for what it may do in your application.

# License

`UbiquityStoreManager` is licensed under the LGPLv3.  Feel free to use it in any of your applications.  I’m also happy to receive any comments, feedback or review any pull requests.

Creating `UbiquityStoreManager` has taken me a huge amount of work and few developers have so far been brave enough to try and solve the iCloud for Core Data problem that Apple left us with.  If this solution is useful to you, please consider saying thanks or donating to the cause.

<a href='http://www.pledgie.com/campaigns/19629'><img alt='Click here to lend your support to: UbiquityStoreManager and make a donation at www.pledgie.com !' src='http://www.pledgie.com/campaigns/19629.png?skin_name=chrome' border='0' /></a>