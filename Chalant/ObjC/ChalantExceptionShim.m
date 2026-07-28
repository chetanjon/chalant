#import "ChalantExceptionShim.h"

NSErrorDomain const CHRaisedExceptionErrorDomain = @"com.cj.chalant.RaisedException";
NSString *const CHExceptionNameKey = @"CHExceptionName";

@implementation CHExceptionCatcher

+ (BOOL)runBlock:(NS_NOESCAPE void (^)(void))block
           error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"no reason given";
            *error = [NSError errorWithDomain:CHRaisedExceptionErrorDomain
                                         code:0
                                     userInfo:@{
                CHExceptionNameKey: exception.name ?: @"NSException",
                NSLocalizedDescriptionKey: reason,
            }];
        }
        return NO;
    }
}

@end
