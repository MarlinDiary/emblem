#import "PortraitContactsBridge.h"
BOOL MPHistoryUnchanged(CNContactStore *store, NSData *token, NSError **error) {
    if (!token) return NO;
    CNChangeHistoryFetchRequest *request = [CNChangeHistoryFetchRequest new];
    request.startingToken = token;
    request.shouldUnifyResults = NO;
    request.includeGroupChanges = YES;
    request.excludedTransactionAuthors = @[@"com.protoyard.emblem", @"org.mailportrait.app"];
    CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *> *result = [store enumeratorForChangeHistoryFetchRequest:request error:error];
    if (!result) return NO;
    return result.value.nextObject == nil;
}

// Only event identity is inspected. A change to a different card/group must not
// strand every app-created contact. Unknown/reset history remains conservative.
static BOOL MPEventAffectsContact(CNChangeHistoryEvent *event, NSString *identifier, BOOL *unknown) {
    if ([event isKindOfClass:CNChangeHistoryDropEverythingEvent.class]) return YES;
    if ([event isKindOfClass:CNChangeHistoryAddContactEvent.class])
        return [((CNChangeHistoryAddContactEvent *)event).contact.identifier isEqualToString:identifier];
    if ([event isKindOfClass:CNChangeHistoryUpdateContactEvent.class])
        return [((CNChangeHistoryUpdateContactEvent *)event).contact.identifier isEqualToString:identifier];
    if ([event isKindOfClass:CNChangeHistoryDeleteContactEvent.class])
        return [((CNChangeHistoryDeleteContactEvent *)event).contactIdentifier isEqualToString:identifier];
    if ([event isKindOfClass:CNChangeHistoryAddMemberToGroupEvent.class])
        return [((CNChangeHistoryAddMemberToGroupEvent *)event).member.identifier isEqualToString:identifier];
    if ([event isKindOfClass:CNChangeHistoryRemoveMemberFromGroupEvent.class])
        return [((CNChangeHistoryRemoveMemberFromGroupEvent *)event).member.identifier isEqualToString:identifier];
    if ([event isKindOfClass:CNChangeHistoryAddGroupEvent.class] ||
        [event isKindOfClass:CNChangeHistoryUpdateGroupEvent.class] ||
        [event isKindOfClass:CNChangeHistoryDeleteGroupEvent.class] ||
        [event isKindOfClass:CNChangeHistoryAddSubgroupToGroupEvent.class] ||
        [event isKindOfClass:CNChangeHistoryRemoveSubgroupFromGroupEvent.class]) return NO;
    *unknown = YES;
    return YES;
}
NSDictionary<NSString *, NSNumber *> *MPContactHistoryInspection(CNContactStore *store, NSData *token, NSString *identifier, NSError **error) {
    if (!token || identifier.length == 0) return @{ @"unchanged": @NO, @"missingToken": @YES };
    CNChangeHistoryFetchRequest *request = [CNChangeHistoryFetchRequest new];
    request.startingToken = token;
    request.shouldUnifyResults = NO;
    request.includeGroupChanges = YES;
    request.additionalContactKeyDescriptors = @[CNContactIdentifierKey];
    request.excludedTransactionAuthors = @[@"com.protoyard.emblem", @"org.mailportrait.app"];
    CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *> *result = [store enumeratorForChangeHistoryFetchRequest:request error:error];
    if (!result) return nil;
    NSUInteger total = 0, affected = 0, unknownCount = 0, reset = 0, additions = 0, updates = 0, deletions = 0;
    for (CNChangeHistoryEvent *event in result.value) {
        total++;
        BOOL unknown = NO;
        if (MPEventAffectsContact(event, identifier, &unknown)) {
            affected++;
            if ([event isKindOfClass:CNChangeHistoryAddContactEvent.class]) additions++;
            if ([event isKindOfClass:CNChangeHistoryUpdateContactEvent.class]) updates++;
            if ([event isKindOfClass:CNChangeHistoryDeleteContactEvent.class]) deletions++;
        }
        if (unknown) unknownCount++;
        if ([event isKindOfClass:CNChangeHistoryDropEverythingEvent.class]) reset++;
    }
    return @{ @"unchanged": @(MPOwnedCreationHistoryUnchanged(additions, affected-additions, unknownCount, reset)), @"addEvents": @(additions), @"updateEvents": @(updates), @"deleteEvents": @(deletions), @"events": @(total), @"affectedEvents": @(affected), @"unknownEvents": @(unknownCount), @"resetEvents": @(reset) };
}

BOOL MPOwnedCreationHistoryUnchanged(NSUInteger additions, NSUInteger laterEvents, NSUInteger unknownEvents, NSUInteger resetEvents) {
    return additions <= 1 && laterEvents == 0 && unknownEvents == 0 && resetEvents == 0;
}
