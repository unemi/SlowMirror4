//
//  MyView.m
//  SlowMirror3
//
//  Created by Tatsuo Unemi on 09/10/18.
//  Copyright 2009 Tatsuo Unemi. All rights reserved.
//

#import "MyView.h"
#import "AppDelegate.h"
#define MARK_RADIUS 15.

@import simd;
@import CoreImage.CIFilterBuiltins;

@implementation MonitorView
- (BOOL)drawMessage {
	if (_message == nil) return NO;
	NSRect dstRct = self.bounds;
	NSDictionary *attr = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont labelFontOfSize:32.f], NSFontAttributeName, nil];
	NSSize size = [_message sizeWithAttributes:attr];
	[_message drawAtPoint:(NSPoint){
		dstRct.origin.x + (dstRct.size.width - size.width) / 2.,
		dstRct.origin.y + (dstRct.size.height - size.height) / 2. }
		withAttributes:attr];
	return YES;
}
@end

@implementation CameraMonitorView
- (void)drawRect:(NSRect)rect {
	if ([super drawMessage]) return;
	if (bitmapImage) {
		NSRect dstRct = self.bounds;
		NSSize srcSz = bitmapImage.size;
		if (srcSz.width < dstRct.size.width * srcSz.height / dstRct.size.height) {
			CGFloat w = srcSz.width * dstRct.size.height / srcSz.height;
			dstRct.origin.x += (dstRct.size.width - w) / 2.;
			dstRct.size.width = w;
		}
		[bitmapImage drawInRect:dstRct fromRect:(NSRect){NSZeroPoint, srcSz}
			operation:NSCompositingOperationCopy fraction:1. respectFlipped:NO hints:nil];
	}
}
- (void)drawImage:(NSBitmapImageRep *)image {
	in_main_thread( ^{ self->bitmapImage = image; self.needsDisplay = YES; });
}
@end

static NSString *keyCorners = @"Corners";
typedef struct {
	CGPoint topLeft, topRight, bottomRight, bottomLeft;
} Corners;
static NSString *actionNames[] = {
	@"Move Area", @"Top Left", @"Top Right", @"Bottom Right", @"Bottom Left"
};
@implementation ProjectionView {
	ResultMonitorView *monitorView;
	CGFloat widthRate, opacity;
	CIFilter<CIPerspectiveTransform> *filter;
	CIImage *ciImage;
	NSBitmapImageRep *bitmap, *outBitmap;
	NSConditionLock *bitmapLock;
	NSThread *bitmapThread;
	Corners corners, orgPoints;
	NSTimer *scrollUndoTimer;
	BOOL areaAdjustModeOn;
	NSInteger cornerID;
	AdjstMsgWindow *msgWin;
	NSBezierPath *areaPath;
	NSUndoManager *undoManager;
	NSUInteger drawTime;
}
- (instancetype)initWithFrame:(NSRect)frame
	monitor:(ResultMonitorView *)mntView widthRate:(CGFloat)wRate {
	if (!(self = [super initWithFrame:frame])) return nil;
	monitorView = mntView;
	widthRate = wRate;
	undoManager = ((AppDelegate *)NSApp.delegate).undoManager;
	filter = [CIFilter perspectiveTransformFilter];
	bitmapLock = NSConditionLock.new;
	cornerID = -2;
	NSArray<NSNumber *> *cnArray = [UserDefaults objectForKey:keyCorners];
	if (cnArray) {
		union { Corners *c; CGFloat *f; simd_double2 *s; } cf = {.c = &corners};
		union { NSRect r; simd_double4 s; } vR = {.r = self.bounds};
		simd_double2 shift = vR.s.xy + vR.s.zw / 2.;
		for (NSInteger i = 0; i < 8; i ++) cf.f[i] = cnArray[i].doubleValue;
		for (NSInteger i = 0; i < 4; i ++) cf.s[i] += shift;
		[self reviseAreaPathAndFilterParams];
	} else [self resetArea:nil];
	return self;
}
- (NSRect)clipRect:(NSRect)rct {
	CGFloat aspectRatio = 16./9. * widthRate;
	if (rct.size.width > rct.size.height * aspectRatio) {
		rct.origin.x += (rct.size.width - rct.size.height * aspectRatio) / 2.;
		rct.size.width = rct.size.height * aspectRatio;
	}
	return rct;
}
- (void)renderThread:(id)userInfo {
	NSThread *thisThread = bitmapThread = NSThread.currentThread;
	for (;;) @autoreleasepool {
		[bitmapLock lockWhenCondition:1];
		CIImage *ciImg = ciImage;
		ciImage = nil;
		[bitmapLock unlockWithCondition:0];
		if (thisThread.cancelled) break;
		if (ciImg == nil) continue;
		NSBitmapImageRep *bm = [NSBitmapImageRep.alloc initWithCIImage:
			[ciImg imageByCroppingToRect:(CGRect){0., 0., DFLT_SCR_WIDTH, DFLT_SCR_HEIGHT}]];
		in_main_thread( ^{
			self->bitmap = bm;
			self->opacity = 1.;
			self.needsDisplay = YES; });
	}
}
- (void)cancelRenderThreadIfNeeded {
	if (bitmapThread == nil || bitmapThread.cancelled) return;
	[bitmapThread cancel];
	[bitmapLock lock];
	[bitmapLock unlockWithCondition:1];
	bitmapThread = nil;
}
- (void)setCIImage:(CIImage *)image {
	if (!bitmapThread || bitmapThread.cancelled)
		 [NSThread detachNewThreadSelector:
			@selector(renderThread:) toTarget:self withObject:nil];
	[bitmapLock lock];
	ciImage = image;
	[bitmapLock unlockWithCondition:1];
}
- (void)setBitmapImage:(NSBitmapImageRep *)image opacity:(CGFloat)op {
	[self cancelRenderThreadIfNeeded];
	in_main_thread( ^{
		self->bitmap = image;
		self->opacity = op;
		self.needsDisplay = YES; });
}
//- (void) windowDidChangeScreen:(NSNotification *) notification {
//	NSLog(@"windowDidChangeScreen");
//}
- (void)windowWillClose:(NSNotification *)notification {
	NSWindow *window = notification.object;
	if (window == self.window) {
		union { Corners c; simd_double2 s[4]; CGFloat f[8]; } cf = {.c = corners};
		union { NSRect r; simd_double4 s; } vR = {.r = self.bounds};
		simd_double2 shift = vR.s.xy + vR.s.zw / 2.;
		for (NSInteger i = 0; i < 4; i ++) cf.s[i] -= shift;
		NSNumber *nums[8];
		for (NSInteger i = 0; i < 8; i ++) nums[i] = @(cf.f[i]);
		[UserDefaults setObject:[NSArray arrayWithObjects:nums count:8] forKey:keyCorners];
		[self cancelRenderThreadIfNeeded];
		if (msgWin) [msgWin.window close];
	} else if (msgWin && window == msgWin.window) msgWin = nil;
}
- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)window {
	return undoManager;
}
- (void)reviseAreaPathAndFilterParams {
	areaPath = NSBezierPath.new;
	[areaPath moveToPoint:corners.topLeft];
	[areaPath lineToPoint:corners.topRight];
	[areaPath lineToPoint:corners.bottomRight];
	[areaPath lineToPoint:corners.bottomLeft];
	[areaPath closePath];
	filter.topLeft = corners.topLeft;
	filter.topRight = corners.topRight;
	filter.bottomLeft = corners.bottomLeft;
	filter.bottomRight = corners.bottomRight;
}
- (void)setFrameSize:(NSSize)newSize {
	NSSize orgSize = self.frame.size;
	if (NSEqualSizes(newSize, orgSize)) return;
	NSAffineTransform *mx = NSAffineTransform.new;
	CGFloat scale = newSize.height / orgSize.height;
	[mx scaleBy:scale];
	[mx translateXBy:(newSize.width / scale - orgSize.width) / 2. yBy:0.];
	union { Corners *c; NSPoint *p; } cp = {.c = &corners};
	for (NSInteger i = 0; i < 4; i ++)
		cp.p[i] = [mx transformPoint:cp.p[i]];
	[self reviseAreaPathAndFilterParams];
	[super setFrameSize:newSize];
}
static simd_double2 cross_point(
	simd_double2 tl, simd_double2 tr, simd_double2 bl, simd_double2 br) {
	simd_double2 dt = tr - tl, db = br - bl;
	CGFloat gv = dt.y * db.x - db.y * dt.x;
	return (fabs(gv) < 1e-6)? (simd_double2){NAN, NAN} :	// parallel
		(dt.yx * db * tl - db.yx * dt * bl
			- dt * db * (tl.yx - bl.yx)) / (simd_double2){gv, -gv};
}
- (void)reviseCorners:(CGFloat)newRate {
	union { Corners *c;
		struct { simd_double2 tl, tr, br, bl; } *s; } cs = {.c = &corners};
	simd_double2 cp = cross_point(cs.s->tl, cs.s->tr, cs.s->bl, cs.s->br);
	CGFloat r = (1. - newRate / widthRate) / 2.;
	if (isnan(cp.x)) {
		simd_double2 d = (cs.s->tr - cs.s->tl) * r;
		cs.s->tl += d; cs.s->tr -= d;
		d = (cs.s->br - cs.s->bl) * r;
		cs.s->bl += d; cs.s->br -= d;
	} else {
		CGFloat d = exp(log(simd_distance(cs.s->tr, cp) / simd_distance(cs.s->tl, cp)) * r);
		cs.s->tl = (cs.s->tl - cp) * d + cp;
		cs.s->tr = (cs.s->tr - cp) / d + cp;
		d = exp(log(simd_distance(cs.s->br, cp) / simd_distance(cs.s->bl, cp)) * r);
		cs.s->bl = (cs.s->bl - cp) * d + cp;
		cs.s->br = (cs.s->br - cp) / d + cp;
	}
//	simd_double2 dt = cs.s->tr - cs.s->tl, db = cs.s->br - cs.s->bl;
//	CGFloat gv = dt.y * db.x - db.y * dt.x, r = (1. - newRate / widthRate) / 2.;
//	if (fabs(gv) < 1e-6) {	// parallel
//		simd_double2 d = dt * r;
//		cs.s->tl += d; cs.s->tr -= d;
//		d = db * r;
//		cs.s->bl += d; cs.s->br -= d;
//	} else {
//		simd_double2 p = (dt.yx * db * cs.s->tl - db.yx * dt * cs.s->bl
//			- dt * db * (cs.s->tl.yx - cs.s->bl.yx)) / (simd_double2){gv, -gv};
//		CGFloat d = exp(log(simd_distance(cs.s->tr, p) / simd_distance(cs.s->tl, p)) * r);
//		cs.s->tl = (cs.s->tl - p) * d + p;
//		cs.s->tr = (cs.s->tr - p) / d + p;
//		d = exp(log(simd_distance(cs.s->br, p) / simd_distance(cs.s->bl, p)) * r);
//		cs.s->bl = (cs.s->bl - p) * d + p;
//		cs.s->br = (cs.s->br - p) / d + p;
//	}
	widthRate = newRate;
	[self reviseAreaPathAndFilterParams];
	self.needsDisplay = YES;
}
- (void)checkMousePoitionForAdjustment {
	NSPoint pt = [self.window convertPointFromScreen:NSEvent.mouseLocation];
	cornerID = -2;
	union { Corners *c; simd_double2 *p; } cp = {.c = &corners};
	simd_double2 mp = {pt.x, pt.y};
	for (NSInteger i = 0; i < 4; i ++)
		if (simd_distance(cp.p[i], mp) < MARK_RADIUS)
			{ cornerID = i; break; }
	if (cornerID < 0 && [areaPath containsPoint:pt]) cornerID = -1;
	NSCursor *newCursor = [self cursorForCorner];
	if (newCursor != NSCursor.currentCursor) [newCursor set];
}
- (void)registarUndoWithNewValue:(Corners)newValue oldValue:(Corners)oldValue {
	if (memcmp(&newValue, &oldValue, sizeof(Corners)) == 0) return;
	corners = newValue;
	[self reviseAreaPathAndFilterParams];
	if (areaAdjustModeOn) [self checkMousePoitionForAdjustment];
	self.needsDisplay = YES;
	[undoManager registerUndoWithTarget:self handler:^(id target) {
		[self registarUndoWithNewValue:oldValue oldValue:newValue];
	}];
}
- (IBAction)resetArea:(id)sender {
	Corners newValue, oldValue = corners;
	NSRect dstRect = [self clipRect:self.bounds];
	newValue.topLeft.x = newValue.bottomLeft.x = NSMinX(dstRect);
	newValue.topRight.x = newValue.bottomRight.x = NSMaxX(dstRect);
	newValue.topLeft.y = newValue.topRight.y = NSMaxY(dstRect);
	newValue.bottomLeft.y = newValue.bottomRight.y = NSMinY(dstRect);
	if (memcmp(&newValue, &oldValue, sizeof(Corners)) != 0) {
		if (sender != nil) {
			[self registarUndoWithNewValue:newValue oldValue:oldValue];
			[undoManager setActionName:[(NSMenuItem *)sender title]];
		} else { corners = newValue; [self reviseAreaPathAndFilterParams]; }
	} 
}
- (IBAction)adjustArea:(NSMenuItem *)item {
	if ((areaAdjustModeOn = !areaAdjustModeOn)) {
		msgWin = [AdjstMsgWindow.alloc initWithWindowNibName:@"AdjstMsgWindow"];
		NSRect scrFrm = self.window.frame;
		NSSize winSz = msgWin.window.frame.size;
		[msgWin.window setFrameOrigin:(NSPoint){
			(scrFrm.size.width - winSz.width) / 2. + scrFrm.origin.x,
			(scrFrm.size.height - winSz.height) / 2. + scrFrm.origin.y}];
		msgWin.window.delegate = self;
		msgWin.window.level = self.window.level + 1;
		[msgWin showWindow:nil];
	} else if (msgWin) [msgWin.window close];
	[self updateTrackingAreas];
	self.needsDisplay = YES;
}
- (void)drawImageInRect:(NSRect)rect {
	if (bitmap) [bitmap drawInRect:rect fromRect:
		[self clipRect:(NSRect){NSZeroPoint, bitmap.size}]
		operation:NSCompositingOperationSourceOver
		fraction:opacity respectFlipped:NO hints:nil];
}
static NSRect mark_rect(CGPoint center) {
	return (NSRect){center.x - MARK_RADIUS, center.y - MARK_RADIUS,
		MARK_RADIUS*2, MARK_RADIUS*2};
}
- (void)drawRect:(NSRect)rect {
	NSRect viewRect = self.bounds;
	NSBitmapImageRep *bmImg = bitmap;
	if (bmImg) {
		NSUInteger now = current_time_us(), timeSpan = now - drawTime;
		if (timeSpan < 500000L) _fps += (1e6 / timeSpan - _fps) * .05;
		drawTime = now;
		filter.inputImage = [[CIImage.alloc initWithBitmapImageRep:bmImg]
			imageByCroppingToRect:[self clipRect:(NSRect){NSZeroPoint, bmImg.size}]];
		[filter.outputImage drawInRect:viewRect fromRect:viewRect
			operation:NSCompositingOperationSourceOver fraction:opacity];
	} else _fps = 0.;
	if (areaAdjustModeOn) {
		[NSColor.cyanColor setStroke];
		[areaPath stroke];
		NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:mark_rect(corners.topLeft)];
		[path appendBezierPathWithOvalInRect:mark_rect(corners.topRight)];
		[path appendBezierPathWithOvalInRect:mark_rect(corners.bottomLeft)];
		[path appendBezierPathWithOvalInRect:mark_rect(corners.bottomRight)];
		[[NSColor colorWithSRGBRed:1. green:1. blue:0. alpha:.667] setFill];
		[path fill];
//		if (NSPointInRect(crossPt, viewRect)) {
//			[NSColor.magentaColor set];
//			[[NSBezierPath bezierPathWithOvalInRect:(NSRect){
//				crossPt.x - 10, crossPt.y - 10, 20, 20}] fill];
//			path = NSBezierPath.new;
//			[path moveToPoint:corners.topRight];
//			[path lineToPoint:crossPt];
//			[path lineToPoint:corners.bottomRight];
//			[path stroke];
//		}
	}
	monitorView.needsDisplay = YES;
}
- (void)updateTrackingAreas {
	for (NSTrackingArea *ta in self.trackingAreas)
		[self removeTrackingArea:ta];
	if (areaAdjustModeOn) [self addTrackingArea:[NSTrackingArea.alloc initWithRect:self.bounds
		options:NSTrackingMouseMoved | NSTrackingActiveInActiveApp
		owner:self userInfo:nil]];
	[super updateTrackingAreas];
}
- (NSCursor *)cursorForCorner {
	return (cornerID < -1)? NSCursor.arrowCursor :
		(cornerID < 0)? NSCursor.openHandCursor : NSCursor.pointingHandCursor;
}
- (void)mouseMoved:(NSEvent *)event {
	[self checkMousePoitionForAdjustment];
}
- (void)mouseDown:(NSEvent *)event {
	orgPoints = corners;
	if (cornerID > -2) [NSCursor.closedHandCursor set];
	[super mouseDown:event];
}
- (void)mouseUp:(NSEvent *)event {
	[super mouseUp:event];
	if (cornerID <= -2) return;
	[[self cursorForCorner] set];
	[self registarUndoWithNewValue:corners oldValue:orgPoints];
	[undoManager setActionName:actionNames[cornerID + 1]];
}
static BOOL is_line_cross(simd_double2 p1, simd_double2 p2, CGPoint a, CGPoint b) {
// check whether a and b are in the opposite sides of the line specified by p1 and p2.
	simd_double2 pD = p2 - p1;
	CGFloat aD, bD;
	if (fabs(pD.x) > fabs(pD.y)) {
		aD = (a.x - p1.x) * pD.y / pD.x + p1.y - a.y;
		bD = (b.x - p1.x) * pD.y / pD.x + p1.y - b.y;
	} else {
		aD = (a.y - p1.y) * pD.x / pD.y + p1.x - a.x;
		bD = (b.y - p1.y) * pD.x / pD.y + p1.x - b.x;
	}
	return (aD * bD <= 0);
} 
- (void)mouseDragged:(NSEvent *)event {
	if (areaAdjustModeOn) {
		union { Corners *c; simd_double2 *p; CGPoint *pt; } cp = {.c = &corners};
		if (cornerID >= 0) {
			NSPoint orgPt = cp.pt[cornerID],
				newPt = [self.window convertPointFromScreen:NSEvent.mouseLocation];
			static NSInteger testIdxs[] = {1, 3, 1, 2, 2, 3};
			for (NSInteger i = 0; i < 6; i += 2)
				if (is_line_cross(cp.p[(cornerID + testIdxs[i]) % 4],
					cp.p[(cornerID + testIdxs[i + 1]) % 4], orgPt, newPt))
				return;
			simd_double2 pt = {newPt.x, newPt.y};
			for (NSInteger i = 0; i < 3; i ++)
				if (simd_distance(pt, cp.p[(cornerID + i + 1) % 4]) < MARK_RADIUS*2.) return;
			cp.pt[cornerID] = newPt;
//	union { Corners *c;
//		struct { simd_double2 tl, tr, br, bl; } *s; } cs = {.c = &corners};
//	simd_double2 dt = cs.s->tr - cs.s->tl, db = cs.s->br - cs.s->bl;
//	CGFloat gv = dt.y * db.x - db.y * dt.x;
//	if (fabs(gv) > 1e-6) {
//		simd_double2 p = (dt.yx * db * cs.s->tl - db.yx * dt * cs.s->bl
//			- dt * db * (cs.s->tl.yx - cs.s->bl.yx)) / (simd_double2){gv, -gv};
//		crossPt = (NSPoint){p.x, p.y};
//	}
			[self reviseAreaPathAndFilterParams];
			self.needsDisplay = YES;
		} else if (cornerID == -1) for (NSInteger i = 0; i < 4; i ++) {
			cp.p[i].x += event.deltaX;
			cp.p[i].y -= event.deltaY;
			[self reviseAreaPathAndFilterParams];
			self.needsDisplay = YES;
		}
	} else [super mouseDragged:event];
}
- (void)scrollWheel:(NSEvent *)event {
	if (areaAdjustModeOn) {
		if (event.scrollingDeltaY == 0.) return;
		if (scrollUndoTimer) [scrollUndoTimer invalidate];
		else orgPoints = corners;
		union { Corners *c; simd_double2 *s; } cs = {.c = &corners};
		CGFloat r = pow(.98, event.scrollingDeltaY);
		simd_double2 c = {0, 0};
		for (NSInteger i = 0; i < 4; i ++) c += cs.s[i];
		c /= 4.;
		for (NSInteger i = 0; i < 4; i ++)
			cs.s[i] = (cs.s[i] - c) * r + c;
		[self reviseAreaPathAndFilterParams];
		self.needsDisplay = YES;
		Corners newCn = corners, orgCn = orgPoints;
		scrollUndoTimer = [NSTimer scheduledTimerWithTimeInterval:.5 repeats:NO
			block:^(NSTimer * _Nonnull timer) {
			self->scrollUndoTimer = nil;
			[self registarUndoWithNewValue:newCn oldValue:orgCn];
			[self->undoManager setActionName:@"Scale"];
		}];
	} else [super scrollWheel:event];
}
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
	if (menuItem.action == @selector(adjustArea:))
		menuItem.state = areaAdjustModeOn;
	return YES;
}
@end

@implementation AdjstMsgWindow
- (IBAction)ok:(id)sender {
	[self.window close];
}
- (IBAction)done:(id)sender {
	[(ProjectionView *)self.window.delegate adjustArea:nil];
}
@end

@implementation ResultMonitorView {
	ProjectionView *projectionView;
}
- (void)drawRect:(NSRect)rect {
	if ([super drawMessage]) return;
	[NSColor.blackColor setFill];
	[NSBezierPath fillRect:self.bounds];
	if (projectionView)
		[projectionView drawImageInRect:[projectionView clipRect:self.bounds]];
}
- (void)setProjectionView:(ProjectionView *)view {
	super.message = view? nil : @"Projection Off";
	projectionView = view;
	if (view == nil) self.needsDisplay = YES;
}
@end

@implementation ProgressText {
	CGFloat progression;
}
- (void)drawRect:(NSRect)rect {
	if (progression > 1e-6) {
		NSRect bar = self.bounds;
		if (progression < 1.) {
			NSRect rest = bar;
			bar.size.width *= progression;
			rest.size.width -= bar.size.width;
			rest.origin.x += bar.size.width;
			[NSColor.controlAccentColor setFill];
			[NSBezierPath fillRect:rest];
		}
		[NSColor.controlBackgroundColor setFill];
		[NSBezierPath fillRect:bar];
	}
	[super drawRect:rect];
}
- (void)setProgression:(CGFloat)value {
	progression = value;
	in_main_thread( ^{ self.needsDisplay = YES; });
}
@end
