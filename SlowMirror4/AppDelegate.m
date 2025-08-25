//
//  MyApplication.m
//  SlowMirror3
//
//  Created by Tatsuo Unemi on 09/10/18.
//  Copyright 2009 Tatsuo Unemi. All rights reserved.
//

#import "AppDelegate.h"
#import "MyView.h"
#import "ContrastAndBrightness.h"
#import "MyCamera.h"
#import "OSCReceiver.h"
#import <sys/sysctl.h>
@import CoreImage.CIFilterBuiltins;

#define CAMERA_FPS cameraFPS
#define N_LAYER_FRAMES 364
#define MAX_STORAGE_LIMIT 17179869184L

void in_main_thread(void (^proc)(void)) {
	if (NSThread.isMainThread) proc();
	else dispatch_async(dispatch_get_main_queue(), proc);
}
static void show_alert(NSObject *object, short err, BOOL fatal) {
	in_main_thread( ^{
		NSAlert *alt;
		if ([object isKindOfClass:NSError.class])
			alt = [NSAlert alertWithError:(NSError *)object];
		else {
			NSString *str = [object isKindOfClass:NSString.class]?
				(NSString *)object : object.description;
			if (err != noErr)
				str = [NSString stringWithFormat:@"%@\nerror code = %d", str, err];
			alt = NSAlert.new;
			alt.alertStyle = fatal? NSAlertStyleCritical : NSAlertStyleWarning;
			alt.messageText = [NSString stringWithFormat:@"%@ in %@",
				fatal? @"Error" : @"Warning",
				[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"]];
			alt.informativeText = str;
		}
		[alt runModal];
		if (fatal) [NSApp terminate:nil];
	} );
}
void err_msg(NSObject *object, BOOL fatal) {
	show_alert(object, 0, fatal);
}
void error_msg(NSString *msg, short err) {
	show_alert(msg, err, NO);
}
NSUInteger current_time_us(void) {
	static NSUInteger startTime = 0;
	struct timeval tv;
	gettimeofday(&tv, NULL);
	if (startTime == 0) startTime = tv.tv_sec;
	return (tv.tv_sec - startTime) * 1000000L + tv.tv_usec;
}
static void draw_time(NSTextField *txt, NSUInteger time) {
	NSUInteger minutes = time / 60000000L;
	float sec = (time - minutes * 60000000L) / 1e6;
	txt.stringValue = [NSString stringWithFormat:@"%02ld:%05.2f", minutes, sec];
}
static void draw_memory_size(NSTextField *txt, NSUInteger size) {
	if (size < 1024) txt.integerValue = size;
	else {
		char unitCh[] = "KMGTP", *pu;
		for (pu = unitCh; pu[0]; pu ++, size /= 1024)
		if (size < 1024 * 1024) {
			float sz = size / 1024.;
			txt.stringValue = [NSString stringWithFormat:[NSString
				stringWithFormat:@"%%.%df %%cB", 3 - (int)log10f(sz)], sz, pu[0]];
			break;
		}
	}
}
static BOOL should_keep_rainy(MyState step) {
	return step >= StateDelayed && step <= StateFadeOut;
}
static BOOL is_rainy(MyState step) {
	return step >= StateFrozen && step <= StateFadeOut;
}
static BOOL needs_camera(MyState step) {
	return step >= StateFadeIn && step <= StateDelayed;
}
static BOOL is_fading(MyState step) {
	return step == StateFadeIn || step == StateDelayed
		|| step == StateCameraFadeOut || step == StateFadeOut;
}

@interface FrameData : NSObject
@property (readonly) NSUInteger time;
@property (readonly) NSData *data;
@end
@implementation FrameData
- (instancetype)initWithData:(NSData *)dt time:(NSUInteger)tm {
	if (!(self = [super init])) return nil;
	_time = tm;
	_data = dt;
	return self;
}
@end

@interface AppDelegate () {
	IBOutlet NSWindow *mainWindow;
	IBOutlet NSMenu *fullScrCtxMenu;
	IBOutlet NSTextField *stateText;
	IBOutlet NSTextField *elapsedTxt, *playbackTxt, *delayTxt,
		*storageTxt, *strgMaxTxt;
	IBOutlet NSTextField *dspFPSDgt, *camFPSDgt, *camSizeTxt;
	IBOutlet NSButton *nextBtn, *backBtn, *restartBtn, *cameraBtn;
	IBOutlet CameraMonitorView *cameraMonitor;
	IBOutlet ResultMonitorView *resultMonitor;
	IBOutlet OSCReceiver *oscReceiver;
	ProjectionView *projectionView;
	NSWindow *fullScreenWindow;
	NSPopUpButton *prjPopUp;
	NSTextField *prjSizeTxt;
	NSMutableArray<NSTextField *> *stateTexts;
	NSBitmapImageRep *realtimeImage;
	NSConditionLock *frameQueueLock;
	NSMutableArray<NSData *> *layerFrames;
	NSMutableArray<FrameData *> *frameQueue;
	MyState stateStep;
	NSInteger layerFrameIndex;
	NSUInteger timeOffset, playbackTime, storageSize, storageLimit;
	NSUInteger tmOffsetAfterLimit, fadeInOutStartTime;
	CGFloat cameraFPS, rainFPS;
	CGFloat opacity, deterioration;
	CIImage *lastDelayedImage;
	CIFilter<CIBloom> *bloom;
	CIFilter<CICompositeOperation> *screenBlend;
	ContrastAndBrightness *contrast;
	BrightnessFilter *brightness;
	BrightnessWindowFilter *layerBrightness;
	PrefParams params;
	MyCamera *myCamera;
}
@end

@implementation AppDelegate
- (PrefParams *)params { return &params; }
- (CGFloat)fadingValue:(CGFloat)value {
	return pow(value, pow(10., params.fadingGamma));
}
- (CGFloat)fading:(CGFloat)span {
	return (current_time_us() - fadeInOutStartTime) / 1e6 / span;
}
- (void)fadeOut:(CGFloat)span state:(MyState)state {
	if (state != stateStep) return;
	opacity = fmax(0., 1. - [self fading:span]);
	[(ProgressText *)stateTexts[state] setProgression:1. - opacity];
	if (opacity <= 0.) [self setStateStep:state + 1];
}
- (void)drawProjectionView:(NSBitmapImageRep *)cameraImage {
	MyState state;
	if (should_keep_rainy((state = stateStep))) {
		CIImage *imageC, *imageM;
		if (state == StateDelayed && !cameraImage) return;
		if (cameraImage) {
			imageC = [CIImage.alloc initWithBitmapImageRep:cameraImage];
			if (params.bloomRadius > 0.) {
				bloom.inputImage = imageC;
				bloom.radius = params.bloomRadius;
				bloom.intensity = deterioration;
				imageC = bloom.outputImage;
			}
			if (cameraImage.size.width != DFLT_SCR_WIDTH) {
				NSSize sz = cameraImage.size;
				CGFloat scl = DFLT_SCR_HEIGHT / sz.height;
				CGFloat offset = (DFLT_SCR_WIDTH - sz.width * scl) / 2.;
				imageC = [imageC imageByApplyingTransform:
					CGAffineTransformMake(scl, 0, 0, scl, offset, 0)];
			}
			lastDelayedImage = imageC;
		}
		NSBitmapImageRep *layerImage = [NSBitmapImageRep.alloc
			initWithData:layerFrames[layerFrameIndex]];
		layerFrameIndex = (layerFrameIndex + 1) % layerFrames.count;
		deterioration = (state == StateDelayed)?
			fmin(1., [self fading:params.deteriorationTime]) : 1.;
		imageM = [CIImage.alloc initWithBitmapImageRep:layerImage];
		NSSize sz = layerImage.size;
		CGFloat scl = DFLT_SCR_WIDTH * params.projectionWidth/100. / sz.width;
		CGFloat offset = (DFLT_SCR_WIDTH - sz.width * scl) / 2.;
		imageM = [imageM imageByApplyingTransform:
			CGAffineTransformMake(scl, 0, 0, DFLT_SCR_HEIGHT / sz.height, offset, 0)];
		[layerBrightness setValue:imageM forKey:@"inputImage"];
		[layerBrightness setValue:@(deterioration) forKey:@"inputBias"];
		imageM = [layerBrightness valueForKey:@"outputImage"];
		switch (state) {
			case StateFadeOut:
			[contrast setValue:@([self fadingValue:opacity]) forKey:@"inputOpacity"]; break;
			case StateOnlyRain:
			[contrast setValue:@(1.) forKey:@"inputOpacity"]; break;
			default:
			if (state == StateCameraFadeOut) {
				[brightness setValue:lastDelayedImage forKey:@"inputImage"];
				[brightness setValue:@([self fadingValue:opacity]) forKey:@"inputBrightness"];
				imageC = [brightness valueForKey:@"outputImage"];
			} else imageC = lastDelayedImage;
			screenBlend.inputImage = imageM;
			screenBlend.backgroundImage = imageC;
			imageM = screenBlend.outputImage;
			[contrast setValue:@(1.) forKey:@"inputOpacity"];
		}
		[contrast setValue:imageM forKey:@"inputImage"];
		[contrast setValue:@(deterioration * params.maxContrast) forKey:@"inputContrast"];
		imageM = [contrast valueForKey:@"outputImage"];
		[projectionView setCIImage:imageM];
		switch (state) {
			case StateCameraFadeOut: [self fadeOut:params.cameraFadeOutTime state:state]; break;
			case StateFadeOut: [self fadeOut:params.rainFadeOutTime state:state];
			default: break;
		}
	} else [projectionView setBitmapImage:cameraImage opacity:[self fadingValue:opacity]];
}
- (NSUInteger)getRealTimeImage {
	NSUInteger time = 0;
	CVPixelBufferRef cvPixBuf = [myCamera CVPixelBuffer:&time];
	simd_uint3 fSize = {
		(uint)CVPixelBufferGetWidth(cvPixBuf),
		(uint)CVPixelBufferGetHeight(cvPixBuf),
		(uint)CVPixelBufferGetBytesPerRow(cvPixBuf) };
	OSType pxFmt = CVPixelBufferGetPixelFormatType(cvPixBuf);
	if (pxFmt != kCVPixelFormatType_OneComponent8)
		err_msg(@"Camera image is not in an 8bit grayscale format.", YES);
	if (realtimeImage == nil ||
		fSize.x != realtimeImage.pixelsWide || fSize.y != realtimeImage.pixelsHigh) {
		NSBitmapImageRep *bm = [NSBitmapImageRep.alloc initWithBitmapDataPlanes:NULL
			pixelsWide:fSize.x pixelsHigh:fSize.y
			bitsPerSample:8 samplesPerPixel:1 hasAlpha:NO isPlanar:NO
			colorSpaceName:NSCalibratedWhiteColorSpace
			bytesPerRow:fSize.z bitsPerPixel:8];
		if (bm != nil) realtimeImage = bm;
		else err_msg(@"Could not make a bitmap for camera image.", YES);
		NSTextField *szTxt = camSizeTxt;
		in_main_thread(^{ szTxt.stringValue =
			[NSString stringWithFormat:@"%d x %d", fSize.x, fSize.y]; });
	}
	unsigned char *bmData = (unsigned char *)realtimeImage.bitmapData;
	CVPixelBufferLockBaseAddress(cvPixBuf, kCVPixelBufferLock_ReadOnly);
	unsigned char *baseAddr = CVPixelBufferGetBaseAddress(cvPixBuf);
	memcpy(bmData, baseAddr, fSize.y * fSize.z);
	CVPixelBufferUnlockBaseAddress(cvPixBuf, kCVPixelBufferLock_ReadOnly);
	CVPixelBufferRelease(cvPixBuf);
	return time;
}
- (void)showFPSs:(id)userInfo {
	camFPSDgt.doubleValue = cameraFPS;
	dspFPSDgt.doubleValue = projectionView? projectionView.fps : 0.;
}
- (void)cameraTask:(id)userInfo {
	NSUInteger cameraTime = 0;
	@try { for (;;) { @autoreleasepool {
		NSData *data;
		NSUInteger time = [self getRealTimeImage];
		if (cameraTime > 0) cameraFPS += (1e6 / (time - cameraTime) - cameraFPS) * .05;
		cameraTime = time;
		MyState state = stateStep;
		switch (state) {
			case StateFadeIn: case StateNoDelay:
			[self drawProjectionView:realtimeImage];
			break;
			case StateDelayed:
			data = [realtimeImage
				TIFFRepresentationUsingCompression:NSTIFFCompressionLZW factor:.5];
			[frameQueueLock lock];
			[frameQueue addObject:[FrameData.alloc initWithData:data time:time]];
			storageSize += data.length;
			if (storageSize > storageLimit && tmOffsetAfterLimit == 0)
				tmOffsetAfterLimit = time - playbackTime;
			[frameQueueLock unlockWithCondition:FrameQueueReady];
			default: break;
		}
		[cameraMonitor drawImage:realtimeImage];
		if (state == StateFadeIn) {
			opacity = fmin(1., (cameraTime - fadeInOutStartTime) / 1e6 / params.fadeInTime);
			[(ProgressText *)stateTexts[state] setProgression:opacity];
			if (opacity >= 1.) [self setStateStep:state + 1];
		}
	}}} @catch (id _) { [NSApp terminate:nil]; }
}
- (void)emptyFrameQueue {
	[frameQueueLock lock];
	[frameQueue removeAllObjects];
	storageSize = tmOffsetAfterLimit = 0;
	[frameQueueLock unlockWithCondition:FrameQueueEmpty];
	in_main_thread(^{ draw_memory_size(self->storageTxt, 0); });
}
- (void)showDelayedFrame:(id)userInfo {
	[self emptyFrameQueue];
	while (stateStep == StateDelayed) {
		NSUInteger now = current_time_us();
		@autoreleasepool {
			[frameQueueLock lockWhenCondition:FrameQueueReady];
			NSData *data = nil;
			NSUInteger timeToDraw = now;
			do {
				playbackTime = frameQueue[0].time;
				data = frameQueue[0].data;
				storageSize -= data.length;
				[frameQueue removeObjectAtIndex:0];
				timeToDraw = (tmOffsetAfterLimit == 0)? timeOffset +
					(NSUInteger)((playbackTime - timeOffset) / params.delayRatio) :
					playbackTime + tmOffsetAfterLimit;
			} while (now > timeToDraw && frameQueue.count > 0);
			NSUInteger waitingTime = (now > timeToDraw)? 0 : timeToDraw - now;
			[frameQueueLock unlockWithCondition:
				(frameQueue.count > 0)? FrameQueueReady : FrameQueueEmpty];
			if (waitingTime > 0) usleep((useconds_t)waitingTime);
			[self drawProjectionView:[NSBitmapImageRep.alloc initWithData:data]];
		}
	}
	rainFPS = projectionView.fps;
	[self emptyFrameQueue];
}
- (void)showRainyFrame:(id)userInfo {
	NSUInteger displayTime = 0;
	while (is_rainy(stateStep)) {
		NSInteger now = current_time_us(), waitingTime = (NSInteger)(1e6 / rainFPS);
		if (displayTime > 0) waitingTime -= now - displayTime;
		displayTime = now;
		if (waitingTime > 0) {
			usleep((useconds_t)waitingTime);
			displayTime += waitingTime;
		}
		[self drawProjectionView:nil];
	}
}
- (void)drawTimeAndStorage:(NSTimer *)theTimer {
	if (stateStep == StateDelayed) {
		NSUInteger time = current_time_us();
		draw_time(elapsedTxt, time - timeOffset);
		draw_time(playbackTxt, playbackTime - timeOffset);
		draw_time(delayTxt, time - playbackTime);
		draw_memory_size(storageTxt, storageSize);
	} else {
		for (NSTextField *txt in @[elapsedTxt, playbackTxt, delayTxt, storageTxt])
			txt.textColor = NSColor.disabledControlTextColor;
		[theTimer invalidate];
	}
}
static NSString *keyProjectorName = @"ProjectorName";
static NSScreen *projection_screen(NSPopUpButton *popUp) {
	NSString *scrName = popUp?
		popUp.titleOfSelectedItem : [UserDefaults stringForKey:keyProjectorName];
	if (scrName != nil) for (NSScreen *scr in NSScreen.screens)
		if ([scrName isEqualToString:scr.localizedName]) return scr;
	return NSScreen.screens.lastObject;
}
static void show_screen_size(NSTextField *szTx, NSScreen *screen) {
	NSSize sz = screen.frame.size;
	szTx.stringValue = [NSString stringWithFormat:@"%.0f x %.0f", sz.width, sz.height];
}
static void setup_screen_popup(NSPopUpButton *popUp, NSTextField *szTx, NSView *prjView) {
	[popUp removeAllItems];
	for (NSScreen *scr in NSScreen.screens)
		[popUp addItemWithTitle:scr.localizedName];
	NSScreen *screen = prjView? prjView.window.screen : projection_screen(nil);
	[popUp selectItemWithTitle:screen.localizedName];
	show_screen_size(szTx, screen);
}
- (void)setProjectorPopUp:(NSPopUpButton *)popUp sizeText:(NSTextField *)szTx {
	prjPopUp = popUp;
	prjSizeTxt = szTx;
	setup_screen_popup(popUp, szTx, projectionView);
}
- (void)chooseProjector:(id)sender {
	if (NSScreen.screens.count <= 1) return;
	NSScreen *screen = projection_screen(prjPopUp);
	show_screen_size(prjSizeTxt, screen);
	if (fullScreenWindow && fullScreenWindow.screen != screen)
		[fullScreenWindow setFrame:screen.frame display:YES];
	[UserDefaults setObject:prjPopUp.titleOfSelectedItem forKey:keyProjectorName];
}
- (void)screensReconfig:(id)info {
	if (prjPopUp) setup_screen_popup(prjPopUp, prjSizeTxt, projectionView);
}
- (void)reviseStateTexts {
	NSInteger n = 0;
	CGFloat w = 0., gap;
	for (NSInteger i = 0; i < N_STATES; i ++) {
		[stateTexts[i] sizeToFit];
		w += stateTexts[i].frame.size.width;
		n ++;
	}
	NSRect frame = stateText.frame;
	frame.origin.x = resultMonitor.frame.origin.x;
	gap = (NSMaxX(cameraMonitor.frame) - frame.origin.x - w) / n;
	for (NSInteger i = 0; i < N_STATES; i ++) {
		frame.size.width = stateTexts[i].frame.size.width + gap;
		stateTexts[i].frame = frame;
		frame.origin.x += frame.size.width;
	}
}
- (void)initiate {
	CGFloat originY = stateText.frame.origin.y;
	stateTexts = NSMutableArray.new;
	for (NSTextField *item in mainWindow.contentView.subviews) {
		if ([item isKindOfClass:NSTextField.class]
		 && item.frame.origin.y == originY) [stateTexts addObject:item];
	}
	[stateTexts sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
		CGFloat a = ((NSView *)obj1).frame.origin.x, b = ((NSView *)obj2).frame.origin.x;
		return (a < b)? NSOrderedAscending :
			(a > b)? NSOrderedDescending : NSOrderedSame;
	}];
	[self reviseStateTexts];
	[resultMonitor setProjectionView:nil];
//
	if (!(myCamera = MyCamera.new)) [NSApp terminate:nil];
	layerFrames = NSMutableArray.new;
	frameQueue = NSMutableArray.new;
	storageSize = 0;
	cameraFPS = 30.;
	rainFPS = 25.;
//
	NSString *format = [NSBundle.mainBundle.resourcePath
		stringByAppendingString:@"/GSS%04ld.jpg"];
	for (NSInteger i = 0; i < N_LAYER_FRAMES; i ++) {
		NSString *path = [NSString stringWithFormat:format, i];
		NSData *data = [NSData dataWithContentsOfFile:path];
		if (data) [layerFrames addObject:data];
	}
	if (layerFrames.count == 0) err_msg(format, YES);
	layerBrightness = BrightnessWindowFilter.new;
	bloom = [CIFilter bloomFilter];
	screenBlend = [CIFilter screenBlendModeFilter];
	brightness = BrightnessFilter.new;
	contrast = ContrastAndBrightness.new;
	[contrast setDefaults];
	[layerBrightness setDefaults];
//
	[Preferences loadDefaultsTo:&params];
//
	[self restart:nil];
	NSUInteger memSize = NSProcessInfo.processInfo.physicalMemory / 2;
	storageLimit = (memSize > MAX_STORAGE_LIMIT)? MAX_STORAGE_LIMIT : memSize;
	draw_memory_size(strgMaxTxt, storageLimit);
	frameQueueLock = [NSConditionLock.alloc initWithCondition:FrameQueueEmpty];
	[NSThread detachNewThreadSelector:@selector(cameraTask:)
		toTarget:self withObject:nil];
	[NSTimer scheduledTimerWithTimeInterval:.2 target:self
		selector:@selector(showFPSs:) userInfo:nil repeats:YES];
	[NSNotificationCenter.defaultCenter
		addObserver:self selector:@selector(screensReconfig:)
		name:NSApplicationDidChangeScreenParametersNotification object:nil];
	[mainWindow makeKeyAndOrderFront:nil];
}
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	check_camera_usage_authorization(^{ [self initiate]; });
}
- (void)applicationWillTerminate:(NSNotification *)aNotification {
	[oscReceiver closeSocketIfOpen];
}
- (void)preferenceChanged:(PrefPrmTag)tag {
	switch (tag) {
		case TagProjectionWidth:
		[projectionView reviseCorners:params.projectionWidth / 100.]; break;
		case TagBloomRadius:
		[bloom setValue:@(params.bloomRadius) forKey:@"inputRadius"]; break;
		case TagBrightnessCutLow:
		[layerBrightness setValue:@(params.brightnessWindowLow) forKey:@"inputLowerLimit"]; break;
		case TagBrightnessCutHigh:
		[layerBrightness setValue:@(params.brightnessWindowHigh) forKey:@"inputUpperLimit"];
		default: break;
	}
}
static void move_window_to_screen(NSWindow *window, NSScreen *screen) {
	NSRect orgScrFrm = window.screen.frame, newScrFrm = screen.frame,
		winFrm = window.frame;
	[window setFrameOrigin:(NSPoint){
		fmax(NSMinX(newScrFrm), fmin(NSMaxX(newScrFrm) - winFrm.size.width, 
			(NSMidX(winFrm) - NSMinX(orgScrFrm)) / orgScrFrm.size.width
				* newScrFrm.size.width + newScrFrm.origin.x - winFrm.size.width / 2.)),
		fmax(NSMinY(newScrFrm), fmin(NSMaxY(newScrFrm) - winFrm.size.height,
			(NSMidY(winFrm) - NSMinY(orgScrFrm)) / orgScrFrm.size.height
				* newScrFrm.size.height + newScrFrm.origin.y - winFrm.size.height / 2.))}];
}
- (void)setupProjectionView {
	NSScreen *screen = projection_screen(prjPopUp);
	NSRect scrFrame = screen.frame;
	projectionView = [ProjectionView.alloc
		initWithFrame:(NSRect){{0, 0}, scrFrame.size }
		monitor:resultMonitor widthRate:params.projectionWidth / 100.];
	fullScreenWindow = [NSWindow.alloc initWithContentRect:scrFrame
		styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered
		defer:NO screen:screen];
	fullScreenWindow.backgroundColor = NSColor.blackColor;
	fullScreenWindow.contentView = projectionView;
	fullScreenWindow.frameOrigin = scrFrame.origin;
	fullScreenWindow.level = NSStatusWindowLevel;
	projectionView.menu = fullScrCtxMenu;
	[fullScreenWindow orderFront:nil];
	[resultMonitor setProjectionView:projectionView];
	mainWindow.nextResponder = fullScreenWindow;
	fullScreenWindow.delegate = projectionView;
	fullScreenWindow.acceptsMouseMovedEvents = YES;
	NSScreen *altScreen = nil;
	for (NSScreen *scr in NSScreen.screens)
		if (![scr isEqualTo:screen]) { altScreen = scr; break; }
	if (altScreen) {
		if ([mainWindow.screen isEqualTo:screen])
			move_window_to_screen(mainWindow, altScreen);
		if (thePreference && [thePreference.window.screen isEqualTo:screen])
			move_window_to_screen(thePreference.window, altScreen);
	}
}
- (void)disposeProjectionView {
	[projectionView windowWillClose:[NSNotification
		notificationWithName:NSWindowWillCloseNotification object:fullScreenWindow]];
	[fullScreenWindow orderOut:nil];
	projectionView = nil;
	fullScreenWindow = nil;
	[resultMonitor setProjectionView:nil];
}
- (void)startBlack:(id)info {
	opacity = 0.;
	[self drawProjectionView:nil];
}
- (void)startDelay {
	deterioration = 0.;
	playbackTime = timeOffset = current_time_us();
	for (NSTextField *txt in @[elapsedTxt, playbackTxt, delayTxt, storageTxt])
		txt.textColor = NSColor.controlTextColor;
	[NSTimer scheduledTimerWithTimeInterval:.2
		target:self selector:@selector(drawTimeAndStorage:) userInfo:nil repeats:YES];
	[NSThread detachNewThreadSelector:@selector(showDelayedFrame:)
		toTarget:self withObject:nil];
}
- (MyState)nextState {
	return (stateStep + 1) % N_STATES;
}
- (MyState)prevState {
	return (stateStep + N_STATES - 1) % N_STATES;
}
- (void)adjustOperationButtons {
	if (cameraBtn.state == NSControlStateValueOff) {
		nextBtn.enabled = !needs_camera([self nextState]);
		backBtn.enabled = !needs_camera([self prevState]);
	} else nextBtn.enabled = backBtn.enabled = YES;
}
- (void)setStateStep:(MyState)step {
	if (stateStep == step) return;
	in_main_thread(^{[self setStateStep0:step];});
}
- (void)setStateStep0:(MyState)step {
	MyState prevStep = stateStep;
	stateStep = step;
	if ([stateTexts[prevStep] isMemberOfClass:ProgressText.class])
		[(ProgressText *)stateTexts[prevStep] setProgression:0.];
	stateTexts[prevStep].textColor = NSColor.disabledControlTextColor;
	stateTexts[prevStep].drawsBackground = NO;
	stateTexts[step].textColor = NSColor.controlTextColor;
	stateTexts[step].drawsBackground = YES;
	restartBtn.enabled = (step > 0);
	if (prevStep == StateProjectionOff) [self setupProjectionView];
	switch (step) {
		case StateProjectionOff: [self disposeProjectionView]; break;
		case StateBlackAtBeginning: case StateBlackAtEnd:
			[self performSelector:@selector(startBlack:) withObject:nil afterDelay:0.];
			break;
		case StateFadeIn: opacity = 0.; break;
		case StateDelayed: [self startDelay]; break;
		default: opacity = 1.;
	}
	if (is_fading(step)) fadeInOutStartTime = current_time_us();
	if (is_rainy(step) && !is_rainy(prevStep))
		[NSThread detachNewThreadSelector:@selector(showRainyFrame:)
			toTarget:self withObject:nil];
	cameraBtn.enabled = !needs_camera(step);
	[self adjustOperationButtons];
}
- (void)enableOperations:(BOOL)enable {
	if (!enable) [self setStateStep:0];
	in_main_thread(^{
		self->backBtn.enabled = self->nextBtn.enabled =
			self->cameraBtn.enabled = enable;
		self->cameraMonitor.message = enable? nil : @"No Camera";
	});
}
//
- (IBAction)preferences:(id)sender {
	[Preferences openPanelWithCamera:myCamera];
	NSWindow *prefWindow = thePreference.window;
	if (fullScreenWindow && [fullScreenWindow.screen isEqualTo:prefWindow.screen]
		&& ![fullScreenWindow.screen isEqualTo:mainWindow.screen])
		move_window_to_screen(prefWindow, mainWindow.screen);
}
- (IBAction)resetDefaults:(id)sender {
	[Preferences removeDefaults:&params];
}
- (IBAction)goNext:(id)sender {
	if (nextBtn.enabled) [self setStateStep:[self nextState]];
}
- (IBAction)goBack:(id)sender {
	if (backBtn.enabled) [self setStateStep:[self prevState]];
}
- (IBAction)restart:(id)sender {
	[self setStateStep:0];
}
- (IBAction)toggleCamera:(id)sender {
	if (!cameraBtn.enabled) return;
	if (sender != cameraBtn) cameraBtn.state = !cameraBtn.state;
	BOOL cameraOn = (cameraBtn.state == NSControlStateValueOn);
	[myCamera startStop:cameraOn];
	[self adjustOperationButtons];
	cameraMonitor.message = cameraOn? nil : @"Camera Off";
	cameraMonitor.needsDisplay = YES;
}
- (MyState)currentState { return stateStep; }
- (BOOL)cameraState { return cameraBtn.state == NSControlStateValueOn; }
- (void)cameraOn { if (!cameraBtn.state) [self toggleCamera:nil]; }
- (void)cameraOff { if (cameraBtn.state) [self toggleCamera:nil]; }
- (int)buttonState {
	return cameraBtn.enabled |
		(restartBtn.enabled << 1) |
		(backBtn.enabled << 2) |
		(nextBtn.enabled << 3);
}
//
- (BOOL)validateMenuItem:(NSMenuItem *)item {
	SEL action = item.action;
	if (action == @selector(restart:)) return stateStep > 0;
	else if (action == @selector(goNext:)) return nextBtn.enabled;
	else if (action == @selector(goBack:)) return backBtn.enabled;
	else if (action == @selector(toggleCamera:)) return cameraBtn.enabled;
	return YES;
}
- (void)windowWillClose:(NSNotification *)notification {
	if (notification.object == mainWindow) [NSApp terminate:nil];
}
@end
