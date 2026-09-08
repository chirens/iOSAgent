#import "EKEventStoreBridge.h"

/// 统一把 NSException 转成错误字符串并设置给出参。
static void EKBridgeSetError(NSString *_Nullable *_Nullable outError, NSException *exception) {
    if (outError != NULL) {
        NSString *reason = exception.reason ?: @"(no reason)";
        *outError = [NSString stringWithFormat:@"%@: %@", exception.name, reason];
    }
}

/// 把 NSDate 格式化成本地时间字符串；任何异常都吞掉返回空串。
static NSString *EKBridgeFormatDate(NSDate *_Nullable date) {
    if (date == nil) { return @""; }
    @try {
        static NSDateFormatter *fm = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            fm = [[NSDateFormatter alloc] init];
            fm.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
            fm.dateFormat = @"yyyy-MM-dd HH:mm";
        });
        // NSDateFormatter 非线程安全，这里复制一份使用
        NSDateFormatter *safe = [fm copy];
        NSString *s = [safe stringFromDate:date];
        return s ?: @"";
    }
    @catch (NSException *e) {
        return @"";
    }
}

@implementation EKEventStoreBridge

+ (BOOL)safeHasEventCalendarsForStore:(EKEventStore *)store
                                error:(NSString *_Nullable *_Nullable)outError {
    if (store == nil) {
        if (outError != NULL) { *outError = @"EKEventStore is nil"; }
        return NO;
    }
    @try {
        NSArray<EKCalendar *> *cals = [store calendarsForEntityType:EKEntityTypeEvent];
        return cals.count > 0;
    }
    @catch (NSException *exception) {
        EKBridgeSetError(outError, exception);
        return NO;
    }
}

+ (NSArray<NSDictionary *> *)safeEventDictsForStore:(EKEventStore *)store
                                          startDate:(NSDate *)start
                                            endDate:(NSDate *)end
                                              error:(NSString *_Nullable *_Nullable)outError {
    if (store == nil) {
        if (outError != NULL) { *outError = @"EKEventStore is nil"; }
        return @[];
    }

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];

    @try {
        // 1) 取日历列表（本身也可能抛）
        NSArray<EKCalendar *> *calendars = nil;
        @try {
            calendars = [store calendarsForEntityType:EKEntityTypeEvent];
        }
        @catch (NSException *exception) {
            EKBridgeSetError(outError, exception);
            return @[];
        }
        if (calendars.count == 0) { return @[]; }

        // 2) 构造谓词（传非 nil calendars，规避 nil 触发的内部断言）
        NSPredicate *predicate = nil;
        @try {
            predicate = [store predicateForEventsWithStartDate:start endDate:end calendars:calendars];
        }
        @catch (NSException *exception) {
            EKBridgeSetError(outError, exception);
            return @[];
        }
        if (predicate == nil) {
            if (outError != NULL) { *outError = @"predicateForEvents returned nil"; }
            return @[];
        }

        // 3) 真正读取事件
        NSArray<EKEvent *> *events = nil;
        @try {
            events = [store eventsMatchingPredicate:predicate];
        }
        @catch (NSException *exception) {
            EKBridgeSetError(outError, exception);
            return @[];
        }
        if (events.count == 0) { return @[]; }

        // 4) 【关键】逐个 event 的属性读取也在 @try 内完成。
        //    EKEvent 属性（尤其 calendarItemIdentifier / title / startDate）在 detached
        //    重复事件、读取期间被删除、iCloud 同步中途等场景会抛 NSException。
        //    这里必须就地转成字典，绝不能把 EKEvent 交回 Swift。
        for (EKEvent *e in events) {
            @try {
                if (![e isKindOfClass:[EKEvent class]]) { continue; }

                NSString *identifier = @"";
                @try { identifier = e.calendarItemIdentifier ?: @""; } @catch (NSException *ignored) { }

                NSString *title = @"(无标题)";
                @try { title = (e.title.length > 0) ? e.title : @"(无标题)"; } @catch (NSException *ignored) { }

                NSDate *startDate = nil;
                @try { startDate = e.startDate; } @catch (NSException *ignored) { }
                NSDate *endDate = nil;
                @try { endDate = e.endDate; } @catch (NSException *ignored) { }

                NSString *location = @"";
                @try { location = e.location ?: @""; } @catch (NSException *ignored) { }

                NSString *calName = @"";
                @try { calName = e.calendar.title ?: @""; } @catch (NSException *ignored) { }

                BOOL allDay = NO;
                @try { allDay = e.isAllDay; } @catch (NSException *ignored) { }

                NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:8];
                d[@"id"] = identifier;
                d[@"title"] = title;
                d[@"start"] = EKBridgeFormatDate(startDate);
                d[@"end"] = EKBridgeFormatDate(endDate);
                d[@"location"] = location;
                d[@"calendar"] = calName;
                d[@"allDay"] = @(allDay);
                if (startDate) { d[@"startDate"] = startDate; }
                if (endDate) { d[@"endDate"] = endDate; }

                [result addObject:[d copy]];
            }
            @catch (NSException *exception) {
                // 单条事件异常不应影响整体：跳过这一条，继续下一条。
                continue;
            }
        }
    }
    @catch (NSException *exception) {
        EKBridgeSetError(outError, exception);
        // 已解析出的部分仍然返回，保证用户至少能看到一部分日程
        return [result copy];
    }

    return [result copy];
}

+ (void)safeFetchReminderDictsForStore:(EKEventStore *)store
                                 limit:(NSInteger)limit
                            completion:(void (^)(NSArray<NSDictionary *> *, NSString *_Nullable))completion {
    if (store == nil) {
        if (completion) { completion(@[], @"EKEventStore is nil"); }
        return;
    }

    NSPredicate *predicate = nil;
    @try {
        NSArray<EKCalendar *> *calendars = [store calendarsForEntityType:EKEntityTypeReminder];
        predicate = [store predicateForIncompleteRemindersWithDueDateStarting:nil
                                                                      ending:nil
                                                                   calendars:calendars];
    }
    @catch (NSException *exception) {
        if (completion) {
            completion(@[], [NSString stringWithFormat:@"%@: %@",
                             exception.name, exception.reason ?: @"(no reason)"]);
        }
        return;
    }

    if (predicate == nil) {
        if (completion) { completion(@[], nil); }
        return;
    }

    @try {
        [store fetchRemindersMatchingPredicate:predicate
                                    completion:^(NSArray<EKReminder *> *_Nullable reminders) {
            @try {
                NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
                NSInteger cap = (limit > 0) ? limit : 20;
                for (EKReminder *r in (reminders ?: @[])) {
                    if (out.count >= (NSUInteger)cap) { break; }
                    @try {
                        if (![r isKindOfClass:[EKReminder class]]) { continue; }

                        NSString *identifier = @"";
                        @try { identifier = r.calendarItemIdentifier ?: @""; } @catch (NSException *ignored) { }

                        NSString *title = @"(无标题)";
                        @try { title = (r.title.length > 0) ? r.title : @"(无标题)"; } @catch (NSException *ignored) { }

                        NSString *notes = @"";
                        @try { notes = r.notes ?: @""; } @catch (NSException *ignored) { }

                        NSDate *dueDate = nil;
                        @try { dueDate = r.dueDateComponents.date; } @catch (NSException *ignored) { }

                        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:5];
                        d[@"id"] = identifier;
                        d[@"title"] = title;
                        d[@"notes"] = notes;
                        d[@"due"] = EKBridgeFormatDate(dueDate);
                        if (dueDate) { d[@"dueDate"] = dueDate; }
                        [out addObject:[d copy]];
                    }
                    @catch (NSException *exception) {
                        continue;
                    }
                }
                if (completion) { completion([out copy], nil); }
            }
            @catch (NSException *exception) {
                if (completion) {
                    completion(@[], [NSString stringWithFormat:@"%@: %@",
                                     exception.name, exception.reason ?: @"(no reason)"]);
                }
            }
        }];
    }
    @catch (NSException *exception) {
        if (completion) {
            completion(@[], [NSString stringWithFormat:@"%@: %@",
                             exception.name, exception.reason ?: @"(no reason)"]);
        }
    }
}

@end
