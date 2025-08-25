//
//  OSCReceiver.h
//  SlowMirror4
//
//  Created by Tatsuo Unemi on 2025/08/15.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OSCReceiver : NSObject
- (void)closeSocketIfOpen;
@end

NS_ASSUME_NONNULL_END
