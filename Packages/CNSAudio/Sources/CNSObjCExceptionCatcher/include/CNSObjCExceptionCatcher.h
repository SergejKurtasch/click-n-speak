#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CNSObjCExceptionCatcher : NSObject

+ (BOOL)perform:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)outError;

@end

NS_ASSUME_NONNULL_END
