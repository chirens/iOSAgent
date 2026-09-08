#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>

NS_ASSUME_NONNULL_BEGIN

/// EventKit 异常隔离桥。
///
/// 背景：EventKit（EKEventStore / EKEvent / EKReminder）内部会在多种边缘情况下抛
/// Objective-C NSException（日历数据库未就绪、事件在读取期间被删除、重复事件的
/// detached 实例、iCloud 同步中途……）。Swift 的 `try/catch` **捕获不了 NSException**，
/// 一抛就是进程终止 —— 这就是日程功能连续多个版本「修了又闪」的根因。
///
/// 唯一可靠办法：用 Objective-C 的 `@try/@catch` 把**整条读取链路**（含每个 EKEvent
/// 的属性读取）全部包起来，Swift 侧只接收 Foundation 值对象（NSArray<NSDictionary *>），
/// 绝不触碰任何 EKEvent / EKReminder 实例。
///
/// ⚠️ 教训：桥只包 `eventsMatchingPredicate:` 是不够的 —— 返回 [EKEvent] 后在 Swift 里
/// 读 `e.calendarItemIdentifier` / `e.title` / `e.startDate` 依然会抛异常。
/// **EKEvent 对象必须在 ObjC 侧就地转成字典再返回。**
@interface EKEventStoreBridge : NSObject

/// 安全读取指定时间范围内的日程，返回字典数组（键：id / title / start / end /
/// startDate / endDate / location / calendar / allDay）。
/// 任何异常都被捕获：失败时返回空数组并通过 outError 给出原因，绝不崩溃。
+ (NSArray<NSDictionary *> *)safeEventDictsForStore:(EKEventStore *)store
                                          startDate:(NSDate *)start
                                            endDate:(NSDate *)end
                                              error:(NSString *_Nullable *_Nullable)outError;

/// 安全查询是否有可用的事件日历（不读事件）。异常时返回 NO。
+ (BOOL)safeHasEventCalendarsForStore:(EKEventStore *)store
                                error:(NSString *_Nullable *_Nullable)outError;

/// 安全读取未完成提醒（异步）。
/// ⚠️ 必须是回调式：EKEventStore 的 fetchReminders 回调在主队列派发，
/// 而调用方是 @MainActor（主线程），若在 ObjC 里用信号量同步等待会直接死锁。
/// 属性到字典的转换仍在 ObjC 的 @try 内完成。
+ (void)safeFetchReminderDictsForStore:(EKEventStore *)store
                                 limit:(NSInteger)limit
                            completion:(void (^)(NSArray<NSDictionary *> *_Nonnull dicts,
                                                 NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
