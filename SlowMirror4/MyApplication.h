//
//  MyApplication.h
//  SlowMirror3
//
//  Created by Tatsuo Unemi on 09/10/18.
//  Copyright 2009 Tatsuo Unemi. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "MyView.h"
#import "ContrastAndBrightness.h"
#import "Preferences.h"
#import "MyCamera.h"

typedef enum {
	StateProjectionOff, StateProjectionFadeIn,
	StateBlackAtBeginning,
	StateFadeIn, StateNoDelay, StateDelayed,
	StateFrozen, StateCameraFadeOut, StateOnlyRain,
	StateFadeOut, StateBlackAtEnd,
	N_STATES
} MyState;
typedef enum { FrameQueueEmpty, FrameQueueReady } FrameQueueState;

extern void in_main_thread(void (^proc)(void));
extern void err_msg(NSObject *object, BOOL fatal);
extern void error_msg(NSString *msg, short code);

@interface MyApplication : NSApplication
- (void)preferenceChanged:(NSInteger)index;
- (void)reviseStateTexts;
- (void)setStateStep:(MyState)step;
- (IBAction)preferences:(id)sender;
- (IBAction)goNext:(id)sender;
- (IBAction)goBack:(id)sender;
- (IBAction)restart:(id)sender;
@end

#define MyErrMsg(f,test,fmt,...) if ((test)==0)\
 err_msg([NSString stringWithFormat:NSLocalizedString(fmt,nil),__VA_ARGS__],f);
#define MyAssert(test,fmt,...) MyErrMsg(YES,test,fmt,__VA_ARGS__)
#define MyWarning(test,fmt,...) MyErrMsg(NO,test,fmt,__VA_ARGS__)
