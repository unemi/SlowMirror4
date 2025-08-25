//
//  Preferences.h
//  SlowMirror3
//
//  Created by Tatsuo Unemi on 09/10/20.
//  Copyright 2009 Tatsuo Unemi. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "MyCamera.h"

typedef struct {
	CGFloat projectionWidth;
	CGFloat delayRatio;
	CGFloat deteriorationTime;
	CGFloat brightnessWindowLow;
	CGFloat brightnessWindowHigh;
	CGFloat bloomRadius;
	CGFloat maxContrast;
	CGFloat fadeInTime;
	CGFloat cameraFadeOutTime;
	CGFloat rainFadeOutTime;
	CGFloat fadingGamma;
} PrefParams;

typedef enum {
	TagProjectionWidth,
	TagDelayRaio,
	TagDeteriorationTime,
	TagBrightnessCutLow,
	TagBrightnessCutHigh,
	TagBloomRadius,
	TagMaxContrast,
	TagFadeInTime,
	TagCameraFadeOutTime,
	TagRainFadeOutTime,
	TagFadingGamma,
	N_PARAMS
} PrefPrmTag;

@interface Preferences : NSWindowController <NSWindowDelegate>
+ (void)openPanelWithCamera:(MyCamera *)myCam;
+ (void)loadDefaultsTo:(PrefParams *)prm;
+ (void)removeDefaults:(PrefParams *)prm;
@end

extern Preferences *thePreference;
