#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>

NS_ASSUME_NONNULL_BEGIN

/// EventKit 内部 NSException 兜底桥：
/// Swift 的 try/catch 无法捕获 Objective-C 抛出的 NSException；
/// 某些 iOS 17/18 设备 + iCloud 同步日历场景下，EKEventStore.events(matching:)
/// 会触发内部断言失败而直接终止进程。
/// 通过 Objective-C 的 @try/@catch 包装调用，失败时返回空数组并把错误信息带回来。
@interface EKEventStoreBridge : NSObject

/// 安全地调用 store.events(matching: predicate)。
/// @param store    EKEventStore 实例
/// @param predicate predicateForEvents 生成的 NSPredicate
/// @param outError 若发生异常，返回 "name: reason" 字符串；否则为 nil
/// @return 成功时返回事件数组；异常时返回空数组
+ (NSArray<EKEvent *> *)safeEventsForStore:(EKEventStore *)store
                                 predicate:(NSPredicate *)predicate
                                     error:(NSString * _Nullable * _Nullable)outError;

@end

NS_ASSUME_NONNULL_END
