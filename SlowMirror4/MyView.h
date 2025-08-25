//
//  MyView.h
//  SlowMirror3
//
//  Created by Tatsuo Unemi on 09/10/18.
//  Copyright 2009 Tatsuo Unemi. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

@interface MonitorView : NSView
@property NSString *message;
@end

@interface CameraMonitorView : MonitorView {
	NSBitmapImageRep *bitmapImage;
}
- (void)drawImage:(NSBitmapImageRep *)image;
@end

@class ResultMonitorView;
@interface ProjectionView : NSView <NSWindowDelegate, NSMenuItemValidation>
@property CGFloat fps;
- (instancetype)initWithFrame:(NSRect)frame
	monitor:(ResultMonitorView *)mntView widthRate:(CGFloat)wRate;
- (void)setCIImage:(CIImage *)image;
- (void)setBitmapImage:(NSBitmapImageRep *)bitmap opacity:(CGFloat)op;
- (void)reviseCorners:(CGFloat)newRate;
@end

@interface ResultMonitorView : MonitorView
- (void)setProjectionView:(ProjectionView *)view;
@end

@interface AdjstMsgWindow : NSWindowController
@end

@interface ProgressText : NSTextField
- (void)setProgression:(CGFloat)value;
@end
