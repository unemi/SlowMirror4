//
//  MyCamera.h
//  SlowMirror4
//
//  Created by Tatsuo Unemi on 2025/08/10.
//

@import Cocoa;
@import AVKit;
NS_ASSUME_NONNULL_BEGIN

extern void check_camera_usage_authorization(void (^block)(void));

@interface MyCamera : NSObject
	<AVCaptureVideoDataOutputSampleBufferDelegate>
- (CVPixelBufferRef)CVPixelBuffer:(NSUInteger *)timeP;
- (void)setCameraPopUp:(NSPopUpButton *)camPopUp sizePopUp:(NSPopUpButton *)sizePopUp;
- (void)startStop:(BOOL)start;
- (void)chooseCamera:(NSPopUpButton *)camPopUp;
- (void)chooseCamSize:(NSPopUpButton *)sizePopUp;
@end

NS_ASSUME_NONNULL_END
