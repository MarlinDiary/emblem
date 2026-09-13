#import <Foundation/Foundation.h>
#import <Contacts/Contacts.h>
NS_ASSUME_NONNULL_BEGIN
/// Conservative deletion guard: ANY non-Emblem contact/group event invalidates deletion.
BOOL MPHistoryUnchanged(CNContactStore *store, NSData * _Nullable token, NSError **error);
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
/// Read-only, contact-scoped history summary. No contact fields/identifiers are returned.
NSDictionary<NSString *, NSNumber *> * _Nullable MPContactHistoryInspection(CNContactStore *store, NSData * _Nullable token, NSString *identifier, NSError **error);
NS_ASSUME_NONNULL_END

/// Only for a journal-proven app-created card: its original add is not a later edit.
BOOL MPOwnedCreationHistoryUnchanged(NSUInteger additions, NSUInteger laterEvents, NSUInteger unknownEvents, NSUInteger resetEvents);
