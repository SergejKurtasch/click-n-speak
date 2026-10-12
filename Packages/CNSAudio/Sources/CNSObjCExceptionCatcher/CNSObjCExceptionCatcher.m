#import "CNSObjCExceptionCatcher.h"

@implementation CNSObjCExceptionCatcher

+ (BOOL)perform:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)outError {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outError) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            userInfo[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            userInfo[@"NSExceptionName"] = exception.name;
            if (exception.userInfo) {
                userInfo[@"NSExceptionUserInfo"] = exception.userInfo;
            }
            *outError = [NSError errorWithDomain:@"com.sergej.clicknspeak.objc-exception"
                                            code:-1
                                        userInfo:userInfo];
        }
        return NO;
    }
}

@end
