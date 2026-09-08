#import "EKEventStoreBridge.h"

@implementation EKEventStoreBridge

+ (NSArray<EKEvent *> *)safeEventsForStore:(EKEventStore *)store
                                 predicate:(NSPredicate *)predicate
                                     error:(NSString * _Nullable * _Nullable)outError {
    @try {
        return [store eventsMatchingPredicate:predicate];
    }
    @catch (NSException *exception) {
        if (outError != NULL) {
            NSString *reason = exception.reason ?: @"(no reason)";
            *outError = [NSString stringWithFormat:@"%@: %@", exception.name, reason];
        }
        return @[];
    }
}

@end
