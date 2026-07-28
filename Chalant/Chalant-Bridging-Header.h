// The only Objective-C in the project, and it exists for one reason:
// Swift cannot catch an NSException, and AVAudioEngine raises them.
#import "ObjC/ChalantExceptionShim.h"
