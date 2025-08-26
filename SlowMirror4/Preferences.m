//
//  Preferences.m
//  SlowMirror3
//
//  Created by Tatsuo Unemi on 09/10/20.
//  Copyright 2009 Tatsuo Unemi. All rights reserved.
//

#import "Preferences.h"
#import "AppDelegate.h"

union pf { CGFloat f[N_PARAMS]; PrefParams p; };
struct { NSString *key; CGFloat min, max, dflt; } ParamInfo[] = {
	{ @"Projection Width (%)", 25., 100., 75.},
	{ @"Delay Ratio", .1, 1., .75 },
	{ @"Deterioration Time", 0., 60., 15. },
	{ @"Brightness Cut Low", 0., 1., .1 },
	{ @"Brightness Cut High", 0., 1., .9 },
	{ @"Bloom Radius", 0., 10., 5. },
	{ @"Max Contrast", 0., 1., .5 },
	{ @"Fade In Time", 0., 30., 15. },
	{ @"Camera Fade Out Time", 0., 30., 15. },
	{ @"Rain Fade Out Time", 0., 30., 15. },
	{ @"Gamma for Fading", -1., 1., 0. } 
};
Preferences *thePreference = nil;

@interface Preferences () {
	PrefParams *params;
	NSMutableArray<NSTextField *> *pTitles, *pInputs;
	NSMutableArray<NSSlider *> *pSliders;
	IBOutlet NSPopUpButton *cameraPopUp, *camSizePopUp, *projectorPopUp;
	IBOutlet NSTextField *prjSizeTxt;
	NSUndoManager *undoManager;
	MyCamera *myCamera;
}
@end

@implementation Preferences
- (void)changeValue:(NSControl *)sender {
	union pf *q = (union pf *)params;
	PrefPrmTag index = (PrefPrmTag)sender.tag;
	CGFloat value = sender.doubleValue, orgValue = q->f[index];
	if (value == orgValue) return;
	q->f[index] = value;
	if ([sender isMemberOfClass:NSTextField.class]) {
		if (index < pSliders.count) pSliders[index].doubleValue = value;
	} else if (index < pInputs.count) pInputs[index].doubleValue = value;
	[(AppDelegate *)NSApp.delegate preferenceChanged:index];
	[UserDefaults setDouble:value forKey:ParamInfo[index].key];
	[undoManager registerUndoWithTarget:sender handler:^(NSControl *cntrl) {
		cntrl.doubleValue = orgValue;
		[cntrl sendAction:cntrl.action to:cntrl.target];
	}];
	[undoManager setActionName:ParamInfo[index].key];
}
- (void)setCamera:(MyCamera *)myCam {
	params = ((AppDelegate *)NSApp.delegate).params;
	union pf *q = (union pf *)params;
	undoManager = ((AppDelegate *)NSApp.delegate).undoManager;
	pTitles = NSMutableArray.new;
	pInputs = NSMutableArray.new;
	pSliders = NSMutableArray.new;
	for (NSView *view in self.window.contentView.subviews) {
		if ([view isMemberOfClass:NSTextField.class]) {
			NSTextField *txt = (NSTextField *)view;
			if (txt.editable) {
				if (pInputs.count < N_PARAMS) [pInputs addObject:txt];
			} else if (pTitles.count < N_PARAMS) [pTitles addObject:txt];
		} else if ([view isMemberOfClass:NSSlider.class])
			if (pSliders.count < N_PARAMS) [pSliders addObject:(NSSlider *)view];
	}
	NSComparator comp_y = ^(NSView * view1, NSView * view2) {
		CGFloat a = view1.frame.origin.y, b = view2.frame.origin.y;
		return (a > b)? NSOrderedAscending : (a < b)? NSOrderedDescending : NSOrderedSame;
	};
	[pInputs sortUsingComparator:comp_y];
	[pTitles sortUsingComparator:comp_y];
	[pSliders sortUsingComparator:comp_y];
	for (NSInteger i = 0; i < pInputs.count; i ++) {
		pInputs[i].tag = i;
		pInputs[i].target = self;
		pInputs[i].action = @selector(changeValue:);
		pInputs[i].doubleValue = q->f[i];
	}
	for (NSInteger i = 0; i < pSliders.count; i ++) {
		pSliders[i].tag = i;
		pSliders[i].target = self;
		pSliders[i].action = @selector(changeValue:);
		pSliders[i].minValue = ParamInfo[i].min;
		pSliders[i].maxValue = ParamInfo[i].max;
		pSliders[i].doubleValue = q->f[i];
	}
	for (NSInteger i = 0; i < pTitles.count; i ++)
		pTitles[i].stringValue = ParamInfo[i].key;

	cameraPopUp.target = camSizePopUp.target = myCam;
	cameraPopUp.action = @selector(chooseCamera:);
	camSizePopUp.action = @selector(chooseCamSize:);
	[myCam setCameraPopUp:cameraPopUp sizePopUp:camSizePopUp];
	projectorPopUp.target = NSApp.delegate;
	projectorPopUp.action = @selector(chooseProjector:);
	[(AppDelegate *)NSApp.delegate setProjectorPopUp:projectorPopUp
		sizeText:prjSizeTxt];
}
- (NSString *)windowNibName { return @"Preferences"; }
+ (void)openPanelWithCamera:(MyCamera *)myCam {
	if (!thePreference) {
		thePreference = [Preferences.alloc initWithWindow:nil];
		[thePreference setCamera:myCam];
	}
	[thePreference showWindow:nil];
}
+ (void)loadDefaultsTo:(PrefParams *)prm {
	union pf *q = (union pf *)prm;
	NSNumber *numb;
	NSUserDefaults *ud = UserDefaults;
	for (PrefPrmTag i = 0; i < N_PARAMS; i ++) {
		numb = [ud objectForKey:ParamInfo[i].key];
		if (numb) q->f[i] = numb.doubleValue;
		else q->f[i] = ParamInfo[i].dflt;
		[(AppDelegate *)NSApp.delegate preferenceChanged:i];
	}
}
- (void)loadValuesFromDict:(NSDictionary<NSString *, NSNumber *> *)dict {
	union pf *q = (union pf *)params;
	NSMutableDictionary *md = NSMutableDictionary.new;
	for (PrefPrmTag i = 0; i < N_PARAMS; i ++) {
		NSNumber *num = dict[ParamInfo[i].key];
		if (num == nil) continue;
		CGFloat orgVal = q->f[i], newVal = num.doubleValue;
		if (orgVal == newVal) continue;
		pInputs[i].doubleValue = pSliders[i].doubleValue = q->f[i] = newVal;
		[(AppDelegate *)NSApp.delegate preferenceChanged:i];
		md[ParamInfo[i].key] = @(orgVal);
	}
	if (md.count > 0) {
		[undoManager registerUndoWithTarget:self handler:
			^(id tgt) { [self loadValuesFromDict:md]; }];
		[undoManager setActionName:@"Reset"];
	}
}
+ (void)removeDefaults:(PrefParams *)prm {
	NSDictionary<NSString *, id> *dict = UserDefaults.dictionaryRepresentation;
	for (NSString *key in dict.keyEnumerator)
		[UserDefaults removeObjectForKey:key];
	union pf *q = (union pf *)prm;
	if (thePreference) {
		NSMutableDictionary *md = NSMutableDictionary.new;
		for (NSInteger i = 0; i < N_PARAMS; i ++) {
			CGFloat orgVal = q->f[i], newVal = ParamInfo[i].dflt;
			if (orgVal != newVal) md[ParamInfo[i].key] = @(newVal);
		}
		if (md.count > 0) [thePreference loadValuesFromDict:md];
	} else for (PrefPrmTag i = 0; i < N_PARAMS; i ++) {
		CGFloat orgVal = q->f[i], newVal = ParamInfo[i].dflt;
		if (orgVal == newVal) continue;
		q->f[i] = newVal;
		[(AppDelegate *)NSApp.delegate preferenceChanged:i];
	}
}
- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)window {
	return undoManager;
}
@end
