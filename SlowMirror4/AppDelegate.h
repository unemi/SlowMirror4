//
//  AppDelegate.h
//  SlowMirror3
//
//  Created by Tatsuo Unemi on 09/10/18.
//  Copyright 2009 Tatsuo Unemi. All rights reserved.
//
/**
	ToDo List
	OSC Reply
 */
#import <Cocoa/Cocoa.h>
#import "Preferences.h"

#define DFLT_SCR_WIDTH 1920
#define DFLT_SCR_HEIGHT 1080 

typedef enum {
	StateProjectionOff,
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
extern NSUInteger current_time_us(void);

@interface AppDelegate : NSObject <NSApplicationDelegate,
	NSMenuItemValidation, NSWindowDelegate>
- (PrefParams *)params;
- (void)preferenceChanged:(PrefPrmTag)tag;
- (void)setStateStep:(MyState)step;
- (void)enableOperations:(BOOL)enable;
- (void)setProjectorPopUp:(NSPopUpButton *)popUp sizeText:(NSTextField *)szTx;
- (void)chooseProjector:(id)sender;
- (IBAction)preferences:(id)sender;
- (IBAction)goNext:(id)sender;
- (IBAction)goBack:(id)sender;
- (IBAction)restart:(id)sender;
- (IBAction)toggleCamera:(id)sender;
- (BOOL)cameraState;
- (MyState)currentState;
- (void)cameraOn;
- (void)cameraOff;
- (int)buttonState;
@end

#define UserDefaults NSUserDefaults.standardUserDefaults
#define MyErrMsg(f,test,fmt,...) if ((test)==0)\
 err_msg([NSString stringWithFormat:NSLocalizedString(fmt,nil),__VA_ARGS__],f);
#define MyAssert(test,fmt,...) MyErrMsg(YES,test,fmt,__VA_ARGS__)
#define MyWarning(test,fmt,...) MyErrMsg(NO,test,fmt,__VA_ARGS__)
