//
//  DNSEvidenceSource.m
//  ControlPlane
//
//  Created by Vladimir Beloborodov on 08/03/2013.
//

#import <SystemConfiguration/SystemConfiguration.h>
#import "DNSEvidenceSource.h"
#import "SearchDomainRuleType.h"
#import "ServerAddressRuleType.h"


@interface DNSEvidenceSource ()

@property (atomic, retain, readwrite) NSSet *searchDomains;
@property (atomic, retain, readwrite) NSSet *dnsServers;

- (void)doFullUpdateFromStore:(SCDynamicStoreRef)store;
- (void)doStop;

@end


#pragma mark C callbacks

static void dnsChange(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
#ifdef DEBUG_MODE
	NSLog(@"dnsChange called with changedKeys:\n%@", changedKeys);
#endif
    [(DNSEvidenceSource *) info doFullUpdateFromStore:store];
}

static BOOL addDNSSearchDomainsToSet(CFDictionaryRef keys, NSString *dnsKey, NSMutableSet *domains) {
    const void *dnsParams;
    if (!CFDictionaryGetValueIfPresent(keys, (CFStringRef) dnsKey, &dnsParams)) {
        return NO;
    }
    
    BOOL isAnyValueAdded = NO;
    
    const void *value;
    if (CFDictionaryGetValueIfPresent((CFDictionaryRef) dnsParams, kSCPropNetDNSDomainName, &value)) {
        [domains addObject:(NSString *) value];
        isAnyValueAdded = YES;
    }
    if (CFDictionaryGetValueIfPresent((CFDictionaryRef) dnsParams, kSCPropNetDNSSearchDomains, &value)) {
        [domains addObjectsFromArray:(NSArray *) value];
        isAnyValueAdded = YES;
    }
    
    return isAnyValueAdded;
}

static BOOL addDNSServersToSet(CFDictionaryRef keys, NSString *dnsKey, NSMutableSet *servers) {
    const void *dnsParams;
    if (!CFDictionaryGetValueIfPresent(keys, (CFStringRef) dnsKey, &dnsParams)) {
        return NO;
    }
    
    const void *value;
    if (CFDictionaryGetValueIfPresent((CFDictionaryRef) dnsParams, kSCPropNetDNSServerAddresses, &value)) {
        [servers addObjectsFromArray:(NSArray *) value];
        return YES;
    }
    
    return NO;
}


@implementation DNSEvidenceSource {
    // for SystemConfiguration asynchronous notifications
    SCDynamicStoreRef store;
    dispatch_queue_t serialQueue;
}

@synthesize searchDomains = _searchDomains;
@synthesize dnsServers = _dnsServers;

- (id)init {
    self = [super initWithRules:@[ [SearchDomainRuleType class], [ServerAddressRuleType class] ]];
    if (!self) {
        return nil;
    }

	return self;
}

- (void)dealloc {
    if (store) {
        SCDynamicStoreSetDispatchQueue(store, NULL);
        CFRelease(store);
    }

    if (serialQueue) {
        dispatch_sync(serialQueue, ^{}); // ensure the queue is fully stopped
        dispatch_release(serialQueue);
    }

	[_searchDomains release];
    [_dnsServers release];

	[super dealloc];
}


typedef struct {
    NSSet *servers;
    NSSet *domains;
} EnumeratedDNSParams;

+ (EnumeratedDNSParams)enumerateFromStore:(SCDynamicStoreRef)store {
    NSArray *dnsKeyPatterns = @[ @"Setup:/Network/Service/[^/]+/DNS", @"State:/Network/Service/[^/]+/DNS" ];
    CFDictionaryRef dict = SCDynamicStoreCopyMultiple(store, NULL, (CFArrayRef) dnsKeyPatterns);
    if (!dict) {
        return (EnumeratedDNSParams) {nil, nil};
    }

	NSMutableSet *servers = [NSMutableSet set], *domains = [NSMutableSet set];
    NSMutableSet *servicesWithDNS = [NSMutableSet setWithCapacity:[(NSDictionary *) dict count]];
    
    // get all unique keys after stripping prefixes 'Setup:/Network/Service/' and 'State:/Network/Service/'
    for (NSString *key in (NSDictionary *) dict) {
        [servicesWithDNS addObject:[key substringFromIndex:23u]];
    }
    
    for (NSString *serviceDNSName in servicesWithDNS) {
        NSString *setupKey = [@"Setup:/Network/Service/" stringByAppendingString:serviceDNSName];
        NSString *stateKey = [@"State:/Network/Service/" stringByAppendingString:serviceDNSName];
        
        if (!addDNSServersToSet(dict, setupKey, servers)) {
            addDNSServersToSet(dict, stateKey, servers);
        }
        
        if (!addDNSSearchDomainsToSet(dict, setupKey, domains)) {
            addDNSSearchDomainsToSet(dict, stateKey, domains);
        }
    }

    CFRelease(dict);

	return (EnumeratedDNSParams) {servers, domains};
}

- (void)doFullUpdateFromStore:(SCDynamicStoreRef)aStore {
	@autoreleasepool {
        EnumeratedDNSParams params = [[self class] enumerateFromStore:aStore];
        
        self.searchDomains = (NSSet *) params.domains;
        self.dnsServers = (NSSet *) params.servers;
        [self setDataCollected:(([params.servers count] > 0) || ([params.domains count] > 0))];

        //[[NSNotificationCenter defaultCenter] postNotificationName:@"evidenceSourceDataDidChange" object:nil];
    }
}

- (void)start {
	if (running) {
		return;
    }

    if (serialQueue) {
        dispatch_sync(serialQueue, ^{}); // ensure we always start with an empty queue
    } else {
        serialQueue = dispatch_queue_create("ControlPlane.DNSEvidenceSource", DISPATCH_QUEUE_SERIAL);
    }

	// Register for asynchronous notifications
	SCDynamicStoreContext ctxt = {0, self, NULL, NULL, NULL}; // {version, info, retain, release, copyDescription}
	store = SCDynamicStoreCreate(NULL, CFSTR("ControlPlane"), dnsChange, &ctxt);
    if (!store) {
        [self doStop];
        return;
    }
    if (!SCDynamicStoreSetDispatchQueue(store, serialQueue)) {
        [self doStop];
        return;
    }

    NSArray *dnsKeyPatterns = @[ @"Setup:/Network/Service/[^/]+/DNS", @"State:/Network/Service/[^/]+/DNS" ];
	if (!SCDynamicStoreSetNotificationKeys(store, NULL, (CFArrayRef) dnsKeyPatterns)) {
        [self doStop];
        return;
    }

    dispatch_async(serialQueue, ^{
        [self doFullUpdateFromStore:store];
    });

	running = YES;
}

- (void)stop {
	if (running) {
        [self doStop];
    }
}

- (void)doStop {
    if (store) {
        SCDynamicStoreSetDispatchQueue(store, NULL);
        CFRelease(store);
        store = NULL;
    }

    if (serialQueue) {
        dispatch_async(serialQueue, ^{
            [self setDataCollected:NO];
            self.searchDomains = nil;
            self.dnsServers = nil;
        });
    }

	running = NO;
}

- (NSString *)name {
	return @"DNS";
}

- (NSString *)friendlyName {
    return NSLocalizedString(@"DNS Parameters", @"");
}

@end
