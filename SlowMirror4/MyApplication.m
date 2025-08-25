//
//  MyApplication.m
//  SlowMirror3
//
//  Created by Tatsuo Unemi on 09/10/18.
//  Copyright 2009 Tatsuo Unemi. All rights reserved.
//

#import "MyApplication.h"
#import <sys/sysctl.h>

#define CAMERA_FPS 25
#define N_LAYER_FRAMES 360
#define MAX_FRAMES (25 * 60 * 10)
#define DELAYED_FPS (CAMERA_FPS * params.delayRatio)
#define MAX_CONTRAST params.maxContrast
#define PROGRESS_UNIT(p, fps) ((params.p > 0.)? 1. / fps / params.p : 1.)
#define DETERIORATION_UNIT PROGRESS_UNIT(deteriorationTime, DELAYED_FPS)
#define FADEIN_UNIT PROGRESS_UNIT(fadeInTime, CAMERA_FPS)
#define CAMERA_FADEOUT_UNIT PROGRESS_UNIT(cameraFadeOutTime, DELAYED_FPS)
#define RAIN_FADEOUT_UNIT PROGRESS_UNIT(rainFadeOutTime, DELAYED_FPS)
//
//extern unsigned char *srcData;
//extern int SrcRowBytes, Width, Height;
//extern BOOL sg_task(void);

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
unsigned long current_time_ms(void) {
	static unsigned long startTime = 0;
	struct timeval tv;
	gettimeofday(&tv, NULL);
	if (startTime == 0) startTime = tv.tv_sec;
	return (tv.tv_sec - startTime) * 1000 + tv.tv_usec / 1000;
}
static void draw_time(NSTextField *txt, unsigned long time) {
	unsigned long minutes = time / 60000L;
	float sec = (time - minutes * 60000L) / 1000.;
	[txt setStringValue:[NSString stringWithFormat:@"%02ld:%05.2f", minutes, sec]];
}
static void draw_memory_size(NSTextField *txt, unsigned long size) {
	if (size < 1024) txt.integerValue = size;
	else {
		char unitCh[] = "KMGTP", *pu;
		for (pu = unitCh; pu[0]; pu ++, size /= 1024)
		if (size < 1024 * 1024) {
			float sz = size / 1024.;
			[txt setStringValue:[NSString stringWithFormat:[NSString
				stringWithFormat:@"%%.%df %%cB", 3 - (int)log10f(sz)], sz, pu[0]]];
			break;
		}
	}
}
static BOOL should_keep_recording(MyState step) {
	return step >= StateDelayed && step <= StateCameraFadeOut;
}
static BOOL should_keep_rainy(MyState step) {
	return step >= StateDelayed && step <= StateFadeOut;
}

@interface MyApplication () {
	IBOutlet NSWindow *mainWindow;
	IBOutlet NSTextField *stateText;
	IBOutlet NSTextField *elapsedTxt, *playbackTxt, *delayTxt, *storageTxt;
	IBOutlet NSButton *nextBtn, *backBtn, *restartBtn;
	IBOutlet CameraMonitorView *cameraMonitor;
	IBOutlet ResultMonitorView *resultMonitor;
	ProjectionView *projectionView;
	NSWindow *fullScreenWindow;
	NSMutableArray<NSTextField *> *stateTexts;
	NSBitmapImageRep *realtimeImage;
	NSConditionLock *frameQueueLock;
	NSLock *stateLock, *drawPrjLock;
	NSMutableArray<NSData *> *frameQueue, *layerFrames;
	NSMutableArray<NSNumber *> *frameTime;
	MyState stateStep;
	NSInteger layerFrameIndex;
	unsigned long timeOffset, playbackTime, storageSize;
	CGFloat alphaValue, opacity, deterioration;
	CIImage *lastDelayedImage;
	CIFilter *bloom, *screenBlend;
	ContrastAndBrightness *contrast;
	BrightnessFilter *brightness;
	BrightnessWindowFilter *layerBrightness;
	PrefParams params;
	MyCamera *myCamera;
}
@end

@implementation MyApplication
- (void)setProgression:(float)value {
	[stateLock lock];
	[(ProgressText *)stateTexts[stateStep] setProgression:value];
	[stateLock unlock];
}
- (CGFloat)fadingValue:(CGFloat)value {
	return powf(value, powf(10., params.fadingGamma));
}
- (void)fadeOut:(float)unit {
	opacity -= unit;
	[self setProgression:1. - opacity];
	if (opacity <= 0.) { opacity = 0.; [self setStateStep:stateStep + 1]; }
}
- (void)drawProjectionView:(NSBitmapImageRep *)cameraImage {
	[drawPrjLock lock];
	if (should_keep_rainy(stateStep)) {
		CIImage *imageC, *imageM;
		if (stateStep == StateDelayed && !cameraImage) return;
		NSMutableSet *workObjects = [[NSMutableSet alloc] initWithCapacity:10];
		if (cameraImage) {
			[workObjects addObject:cameraImage];
			imageC = [CIImage imageWithCGImage:[cameraImage CGImage]];
			[workObjects addObject:imageC];
			if (params.bloomRadius > 0.) {
				[bloom setValue:imageC forKey:@"inputImage"];
				[bloom setValue:[NSNumber numberWithFloat:
					params.bloomRadius] forKey:@"inputRadius"];
				[bloom setValue:[NSNumber numberWithFloat:
					deterioration] forKey:@"inputIntensity"];
				imageC = [bloom valueForKey:@"outputImage"];
				[workObjects addObject:imageC];
			}
			lastDelayedImage = imageC;
//			if (lastDelayedImage) [lastDelayedImage release];
//			[(lastDelayedImage = imageC) retain];
		}
		NSBitmapImageRep *layerImage = [[NSBitmapImageRep alloc]
			initWithData:layerFrames[layerFrameIndex]];
		[workObjects addObject:layerImage];
//		[layerImage autorelease];
		layerFrameIndex = (layerFrameIndex + 1) % N_LAYER_FRAMES;
		if ((deterioration += DETERIORATION_UNIT) > 1.)
			deterioration = 1.;
		imageM = [CIImage imageWithCGImage:[layerImage CGImage]];
		[workObjects addObject:imageM];
		[layerBrightness setValue:imageM forKey:@"inputImage"];
		[layerBrightness setValue:[NSNumber numberWithFloat:deterioration]
			forKey:@"inputBias"];
		imageM = [layerBrightness valueForKey:@"outputImage"];
		[workObjects addObject:imageM];
		switch (stateStep) {
			case StateFadeOut:
			[contrast setValue:[NSNumber numberWithFloat:[self fadingValue:opacity]]
				forKey:@"inputOpacity"]; break;
			case StateOnlyRain:
			[contrast setValue:[NSNumber numberWithFloat:1.f] forKey:@"inputOpacity"];
			break;
			default:
			if (stateStep == StateCameraFadeOut) {
				[brightness setValue:lastDelayedImage forKey:@"inputImage"];
				[brightness setValue:[NSNumber numberWithFloat:[self fadingValue:opacity]]
					forKey:@"inputBrightness"];
				imageC = [brightness valueForKey:@"outputImage"];
				[workObjects addObject:imageC];
			} else imageC = lastDelayedImage;
			[screenBlend setValue:imageM forKey:@"inputImage"];
			[screenBlend setValue:imageC forKey:@"inputBackgroundImage"];
			imageM = [screenBlend valueForKey:@"outputImage"];
			[workObjects addObject:imageM];
			[contrast setValue:[NSNumber numberWithFloat:1.f] forKey:@"inputOpacity"];
		}
		[contrast setValue:imageM forKey:@"inputImage"];
		[contrast setValue:[NSNumber numberWithFloat:
			deterioration * MAX_CONTRAST] forKey:@"inputContrast"];
		imageM = [contrast valueForKey:@"outputImage"];
		[workObjects addObject:imageM];
		[resultMonitor drawImage:imageM objects:workObjects];
		if (projectionView) [projectionView drawImage:imageM objects:workObjects];
//		[workObjects release];
		switch (stateStep) {
			case StateCameraFadeOut: [self fadeOut:CAMERA_FADEOUT_UNIT]; break;
			case StateFadeOut: [self fadeOut:RAIN_FADEOUT_UNIT];
			default: break;
		}
	} else {
		CGFloat x = [self fadingValue:opacity];
		[resultMonitor drawImage:cameraImage opacity:x];
		if (projectionView) [projectionView drawImage:cameraImage opacity:x];
	}
	[drawPrjLock unlock];
}
- (void)getRealTimeImage {
	CVPixelBufferRef cvPixBuf = [myCamera CVPixelBuffer];
	if (cvPixBuf == NULL) return;
	simd_uint3 fSize = {
		(uint)CVPixelBufferGetWidth(cvPixBuf),
		(uint)CVPixelBufferGetHeight(cvPixBuf),
		(uint)CVPixelBufferGetBytesPerRow(cvPixBuf) };
	OSType pxFmt = CVPixelBufferGetPixelFormatType(cvPixBuf);
	if (pxFmt != kCVPixelFormatType_OneComponent32Float)
		err_msg(@"Camera image is not in a grayscale floating point number format.", YES);
	if (realtimeImage == nil ||
		fSize.x != realtimeImage.pixelsWide || fSize.y != realtimeImage.pixelsHigh) {
		NSBitmapImageRep *bm = [NSBitmapImageRep.alloc initWithBitmapDataPlanes:NULL
			pixelsWide:fSize.x pixelsHigh:fSize.y
			bitsPerSample:32 samplesPerPixel:1 hasAlpha:NO isPlanar:NO
			colorSpaceName:NSCalibratedWhiteColorSpace
			bitmapFormat:NSBitmapFormatFloatingPointSamples
			bytesPerRow:fSize.x * 4 bitsPerPixel:32];
		if (bm != nil) realtimeImage = bm;
		else err_msg(@"Could not make a bitmap for camera image.", YES);
	}
	float *bmData = (float *)realtimeImage.bitmapData;
	CVPixelBufferLockBaseAddress(cvPixBuf, kCVPixelBufferLock_ReadOnly);
	unsigned char *baseAddr = CVPixelBufferGetBaseAddress(cvPixBuf);
	memcpy(bmData, baseAddr, fSize.y * fSize.z);
	CVPixelBufferUnlockBaseAddress(cvPixBuf, kCVPixelBufferLock_ReadOnly);
	CVPixelBufferRelease(cvPixBuf);
}
- (void)setResultViewAlpha:(CGFloat)alpha {
	NSWindow *fullScrWin = fullScreenWindow;
	NSView *resultView = resultMonitor;
	in_main_thread( ^{
		if (fullScrWin) fullScrWin.alphaValue = alpha;
		resultView.alphaValue = alpha;
	} );
}
- (void)sgTask:(id)userInfo {
	@try {
	for (;;) {
		unsigned long interval = 1000000 / CAMERA_FPS;
		unsigned long time = current_time_ms();
		NSData *data;
		@autoreleasepool {
		[self getRealTimeImage];
		switch (stateStep) {
			case StateProjectionFadeIn:
			[self drawProjectionView:params.shouldSkipBlack?
				realtimeImage : nil]; break;
			case StateBlackAtBeginning: case StateBlackAtEnd:
			[self drawProjectionView:nil]; break;
			case StateFadeIn: case StateNoDelay:
			[self drawProjectionView:realtimeImage];
			break;
			case StateDelayed:
			data = [realtimeImage
				TIFFRepresentationUsingCompression:NSTIFFCompressionLZW factor:.5];
			[frameQueueLock lock];
			[frameQueue addObject:data];
			[frameTime addObject:@(time)];
			if (frameQueue.count > MAX_FRAMES) {
				[frameQueue removeObjectAtIndex:0];
				[frameTime removeObjectAtIndex:0];
			}
			storageSize += [data length];
			[frameQueueLock unlockWithCondition:FrameQueueReady];
			default: break;
		}
		[cameraMonitor drawImage:realtimeImage opacity:1.];
		switch (stateStep) {
			case StateFadeIn:
			opacity += FADEIN_UNIT;
			[self setProgression:opacity];
			if (opacity >= 1.) { opacity = 1.; [self setStateStep:stateStep + 1]; }
			break;
			case StateProjectionFadeIn:
			if (fullScreenWindow) {
				BOOL shouldGoNext = NO;
				alphaValue += FADEIN_UNIT;
				[self setProgression:alphaValue];
				if (alphaValue >= 1.) { alphaValue = 1.; shouldGoNext = YES; }
				[self setResultViewAlpha:[self fadingValue:alphaValue]];
				if (shouldGoNext) [self setStateStep:
					(stateStep == StateProjectionFadeIn && params.shouldSkipBlack)?
					StateNoDelay : (stateStep + 1) % N_STATES];
			}
			default: break;
		}}
		
		time = (current_time_ms() - time) * 1000;
		if (interval > time) usleep((useconds_t)(interval - time));
	}} @catch (id _) { [NSApp terminate:nil]; }
}
- (void)showDelayedFrame:(id)userInfo {
	while (should_keep_rainy(stateStep)) {
		unsigned long interval = 1000000 / DELAYED_FPS, time;
		@autoreleasepool {
			if (stateStep == StateDelayed ||
				(!params.shouldFreezeBeforeFadeOut && frameQueue.count > 0 &&
				(stateStep == StateFrozen || stateStep == StateCameraFadeOut))) {
				[frameQueueLock lockWhenCondition:FrameQueueReady];
				time = current_time_ms();
				playbackTime = frameTime[0].integerValue;
				NSData *data = frameQueue[0];
				storageSize -= [data length];
				NSBitmapImageRep *bm = [[NSBitmapImageRep alloc] initWithData:data];
				[frameQueue removeObjectAtIndex:0];
				[frameTime removeObjectAtIndex:0];
				[frameQueueLock unlockWithCondition:
					(frameQueue.count > 0)? FrameQueueReady : FrameQueueEmpty];
				[self drawProjectionView:bm];
			} else {
				time = current_time_ms();
				[self drawProjectionView:nil];
			}
		}
		time = (current_time_ms() - time) * 1000;
		if (interval > time) usleep((useconds_t)(interval - time));
	}
}
- (void)drawTimeAndStorage:(NSTimer *)theTimer {
	if (should_keep_recording(stateStep)) {
		unsigned long time = current_time_ms();
		draw_time(elapsedTxt, time - timeOffset);
		draw_time(playbackTxt, playbackTime - timeOffset);
		draw_time(delayTxt, time - playbackTime);
		draw_memory_size(storageTxt, storageSize);
	} else {
		[elapsedTxt setTextColor:[NSColor disabledControlTextColor]];
		[playbackTxt setTextColor:[NSColor disabledControlTextColor]];
		[delayTxt setTextColor:[NSColor disabledControlTextColor]];
		[storageTxt setTextColor:[NSColor disabledControlTextColor]];
		[theTimer invalidate];
	}
}
- (void)awakeFromNib {
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
	[resultMonitor setProjectionOn:NO];
//
	if (!(myCamera = MyCamera.new)) [NSApp terminate:nil];
	layerFrames = NSMutableArray.new;
	frameQueue = NSMutableArray.new;
	frameTime = NSMutableArray.new;
	storageSize = 0;
//
	NSString *format = [NSBundle.mainBundle.resourcePath
		stringByAppendingString:@"/GSS%04ld.jpg"];
	for (NSInteger i = 0, k = 0; i < 999 && k < N_LAYER_FRAMES; i ++) {
		NSString *path = [NSString stringWithFormat:format, i];
		NSData *data = [NSData dataWithContentsOfFile:path];
		if (data) [layerFrames addObject:data];
	}
	if (layerFrames.count == 0) { error_msg(format, 0); [NSApp terminate:nil]; }
	layerBrightness = BrightnessWindowFilter.new;
	bloom = [CIFilter filterWithName:@"CIBloom"];
	screenBlend = [CIFilter filterWithName:@"CIScreenBlendMode"];
	brightness = BrightnessFilter.new;
	contrast = ContrastAndBrightness.new;
	[contrast setDefaults];
	[layerBrightness setDefaults];
//
	[Preferences loadDefaultsTo:&params];
//
//	if (!start_camera()) [NSApp terminate:nil];
	[self restart:nil];
	frameQueueLock = [NSConditionLock.alloc initWithCondition:FrameQueueEmpty];
	stateLock = NSLock.new;
	drawPrjLock = NSLock.new;
	[NSThread detachNewThreadSelector:@selector(sgTask:)
		toTarget:self withObject:nil];
}
- (void)preferenceChanged:(NSInteger)index {
	switch (index) {
		case TagBloomRadius: [bloom setValue:[NSNumber numberWithFloat:
			params.bloomRadius] forKey:@"inputRadius"]; break;
		case TagBrightnessCutLow: [layerBrightness setValue:
			[NSNumber numberWithFloat:params.brightnessWindowLow]
			forKey:@"inputLowerLimit"]; break;
		case TagBrightnessCutHigh: [layerBrightness setValue:
			[NSNumber numberWithFloat:params.brightnessWindowHigh]
			forKey:@"inputUpperLimit"];
	}
}
- (void)reviseStateTexts {
	NSInteger n = 0;
	CGFloat w = 0., gap;
	for (NSInteger i = StateBlackAtBeginning; i <= StateFadeIn; i ++)
		[stateTexts[i] setHidden:params.shouldSkipBlack];
	stateTexts[StateFrozen].stringValue =
		params.shouldFreezeBeforeFadeOut? @"Freeze" : @"Stop Recording";
	for (NSInteger i = 0; i < N_STATES; i ++)
	if (!stateTexts[i].isHidden) {
		[stateTexts[i] sizeToFit];
		w += stateTexts[i].frame.size.width;
		n ++;
	}
	NSRect frame = stateText.frame;
	frame.origin.x = resultMonitor.frame.origin.x;
	gap = (NSMaxX(cameraMonitor.frame) - frame.origin.x - w) / n;
	for (NSInteger i = 0; i < N_STATES; i ++) if (!stateTexts[i].isHidden) {
		frame.size.width = stateTexts[i].frame.size.width + gap;
		stateTexts[i].frame = frame;
		frame.origin.x += frame.size.width;
	}
}
- (void)setupProjectionView {
	NSArray *screens = [NSScreen screens];
	NSScreen *screen = screens.lastObject;
	NSRect scrFrame = screen.frame;
	if ([screens count] < 2) {
		scrFrame.size.width /= 2.;
		scrFrame.size.height /= 2.;
	}
	projectionView = [ProjectionView.alloc
		initWithFrame:(NSRect){{0, 0}, scrFrame.size }];
	fullScreenWindow = [NSWindow.alloc initWithContentRect:scrFrame
		styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered
		defer:NO screen:screen];
	fullScreenWindow.backgroundColor = NSColor.blackColor;
	fullScreenWindow.contentView = projectionView;
	alphaValue = (stateStep == StateProjectionFadeIn)? FADEIN_UNIT : 1.;
	CGFloat alpha = [self fadingValue:alphaValue];
	fullScreenWindow.alphaValue = alpha;
	fullScreenWindow.frameOrigin = scrFrame.origin;
	if ([screens count] < 2)
		[fullScreenWindow orderWindow:NSWindowBelow relativeTo:mainWindow.windowNumber];
	else {
		fullScreenWindow.level = NSStatusWindowLevel;
		[fullScreenWindow orderFront:nil];
	}
	[resultMonitor setProjectionOn:YES];
	[resultMonitor drawImage:nil opacity:0.];
	resultMonitor.alphaValue = alpha;
}
- (void)disposeProjectionView {
	[fullScreenWindow orderOut:nil];
	projectionView = nil;
	fullScreenWindow = nil;
	[resultMonitor setProjectionOn:NO];
}
- (void)startRenderingThread {
	[NSThread detachNewThreadSelector:@selector(showDelayedFrame:)
		toTarget:self withObject:nil];
}
- (void)startDelay {
	playbackTime = timeOffset = current_time_ms();
	[elapsedTxt setTextColor:NSColor.controlTextColor];
	[playbackTxt setTextColor:NSColor.controlTextColor];
	[delayTxt setTextColor:NSColor.controlTextColor];
	[storageTxt setTextColor:NSColor.controlTextColor];
	[NSTimer scheduledTimerWithTimeInterval:.2
		target:self selector:@selector(drawTimeAndStorage:) userInfo:nil repeats:YES];
}
- (void)emptyFrameQueue {
	[frameQueueLock lock];
	[frameQueue removeAllObjects];
	[frameTime removeAllObjects];
	storageSize = 0;
	[frameQueueLock unlockWithCondition:FrameQueueEmpty];
}
- (void)setStateStep:(MyState)step {
	if (stateStep == step) return;
	int prevStep = stateStep;
	[stateLock lock];
	stateStep = step;
	if ([stateTexts[prevStep] isMemberOfClass:ProgressText.class])
		[(ProgressText *)stateTexts[prevStep] setProgression:0.];
	NSTextField *prevTxt = stateTexts[prevStep], *nowTxt = stateTexts[step];
	NSButton *rstBtn = restartBtn;
	in_main_thread( ^{
		prevTxt.textColor = NSColor.disabledControlTextColor;
		prevTxt.drawsBackground = NO;
		nowTxt.textColor = NSColor.controlTextColor;
		nowTxt.drawsBackground = YES;
		rstBtn.enabled = (step > 0);
	} );
	if (prevStep == StateProjectionOff) [self setupProjectionView];
	switch (step) {
		case StateProjectionOff:
		[self disposeProjectionView]; break;
		case StateBlackAtBeginning: case StateBlackAtEnd:
		opacity = 0.; break;
		case StateProjectionFadeIn:
		opacity = params.shouldSkipBlack? 1. : 0.;
		alphaValue = FADEIN_UNIT; break;
		case StateFadeIn:
		opacity = FADEIN_UNIT; break;
		case StateDelayed:
		if (prevStep == StateNoDelay) deterioration = 0.;
		default: opacity = 1.;
	}
	if (prevStep == StateProjectionFadeIn)
		[self setResultViewAlpha:1.];
	if (should_keep_recording(step)) {
		if (!should_keep_recording(prevStep)) [self startDelay];
	} else if (should_keep_recording(prevStep)) [self emptyFrameQueue];
	if (should_keep_rainy(step) && !should_keep_rainy(prevStep))
		[self startRenderingThread];
	[stateLock unlock];
}
//
- (IBAction)preferences:(id)sender {
	[Preferences openPanelFor:&params myCamera:myCamera];
}
- (IBAction)goNext:(id)sender {
	[self setStateStep:
		(stateStep == StateProjectionFadeIn && params.shouldSkipBlack)?
		StateNoDelay : (stateStep + 1) % N_STATES];
}
- (IBAction)goBack:(id)sender {
	[self setStateStep:
		(stateStep == StateNoDelay && params.shouldSkipBlack)?
		StateProjectionFadeIn : (stateStep + N_STATES - 1) % N_STATES];
}
- (IBAction)restart:(id)sender {
	[self setStateStep:0];
}
//
- (BOOL)validateMenuItem:(NSMenuItem *)item {
	SEL action = [item action];
	if (action == @selector(restart:))
		return stateStep > 0;
	return YES;
}
- (void)windowWillClose:(NSNotification *)notification {
	if ([notification object] == mainWindow) [NSApp terminate:nil];
}
//
- (NSNumber *)stateStep {
	return [NSNumber numberWithInt:stateStep];
}
- (void)handleGoNextCommand:(NSScriptCommand *)command {
	[self goNext:nil];
}
- (void)handleGoBackCommand:(NSScriptCommand *)command {
	[self goBack:nil];
}
- (void)handleRestartCommand:(NSScriptCommand *)command {
	[self setStateStep:0];
}
@end
