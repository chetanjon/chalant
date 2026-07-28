#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Domain for exceptions caught on Swift's behalf. `userInfo` carries
/// `CHExceptionNameKey` and `NSLocalizedDescriptionKey` (the reason).
extern NSErrorDomain const CHRaisedExceptionErrorDomain;
extern NSString *const CHExceptionNameKey;

/// The one thing Swift cannot do for itself.
///
/// An `NSException` is not a Swift error. There is no `catch` that sees
/// one, so raising it ends the process where it stands. That is not a
/// theoretical gap here: `AVAudioEngine` raises rather than returns for
/// a family of misuse, and one of those, installing a second tap on a
/// bus that already had one, killed this app on the first voice session
/// after a permission grant.
///
/// A method rather than a free function on purpose: Swift only applies
/// the trailing-NSError-to-`throws` conversion to Objective-C methods,
/// so this is what lets the call read as an ordinary `try` on the Swift
/// side.
///
/// A caught exception means the framework abandoned an operation
/// partway, so its state must be assumed inconsistent afterwards.
/// Callers are expected to tear the thing down and rebuild it, never to
/// carry on as though the call had merely returned false.
@interface CHExceptionCatcher : NSObject

+ (BOOL)runBlock:(NS_NOESCAPE void (^)(void))block
           error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
