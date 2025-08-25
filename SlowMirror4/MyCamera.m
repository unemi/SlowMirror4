//
//  MyCamera.m
//  SlowMirror4
//
//  Created by Tatsuo Unemi on 2025/08/10.
//

#import "MyCamera.h"
#import "AppDelegate.h"
#import "Preferences.h"
@import simd;

static NSString *keyCameraName = @"CameraName", *keyCamFrameSize = @"CameraFrameSize";
enum { FrameNone, FrameReady };

void check_camera_usage_authorization(void (^block)(void)) {
	@try {
		switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
			case AVAuthorizationStatusAuthorized: block(); break;
			case AVAuthorizationStatusRestricted: @throw @"restricted";
			case AVAuthorizationStatusDenied: @throw @"denied";
			case AVAuthorizationStatusNotDetermined:
			[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:
				^(BOOL granted) { in_main_thread(^{
					if (granted) block(); else [NSApp terminate:nil]; }); }];
		}
	} @catch (NSString *str) {
		MyAssert(0, @"Camera usage in this application is %@."
			@" Check the privacy settings in System Preferences"
			@" if you want to use a camera device.", str)
	}
}

@interface MyCamera () {
	AVCaptureDeviceDiscoverySession *camSearch;
	AVCaptureSession *ses;
	AVCaptureDevice *camera;
	AVCaptureVideoDataOutput *vDataOut;
	NSPopUpButton *cameraPopUp, *camSizePopUp;
	CVPixelBufferRef frameCVPixBuf;
	NSConditionLock *lock;
	NSUInteger frameTime;
}
@end

@implementation MyCamera
// AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output
	didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
	fromConnection:(AVCaptureConnection *)connection {
	NSUInteger time = current_time_us();
	CVPixelBufferRef cvPixBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
	if (cvPixBuf == NULL) return;
	[lock lock];
	if (frameCVPixBuf) CVPixelBufferRelease(frameCVPixBuf);
	CVPixelBufferRetain((frameCVPixBuf = cvPixBuf));
	frameTime = time;
	[lock unlockWithCondition:FrameReady];
}
- (CVPixelBufferRef)CVPixelBuffer:(NSUInteger *)timeP {
	[lock lockWhenCondition:FrameReady];
	CVPixelBufferRef result = frameCVPixBuf;
	frameCVPixBuf = NULL;
	*timeP = frameTime;
	[lock unlockWithCondition:FrameNone];
	return result;
}
static CMVideoDimensions size_from_menu_item(NSMenuItem *mnItem) {
	CMVideoDimensions size;
	sscanf(mnItem.title.UTF8String, "%d x %d", &size.width, &size.height);
	return size;
}
static CMVideoDimensions size_of_camera_frame(AVCaptureDevice *cam) {
	return CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription);
}
- (void)setupCamSizePopUp:(CMVideoDimensions)dm {
	NSString *titleToBeSelected = nil;
	NSArray<AVCaptureDeviceFormat *> *fms = camera.formats;
	NSInteger nFormats = fms.count;
	CMVideoDimensions activeDm = size_of_camera_frame(camera), dms[nFormats];
	[camSizePopUp removeAllItems];
	for (NSInteger i = 0; i < nFormats; i ++) dms[i] =
		CMVideoFormatDescriptionGetDimensions(fms[i].formatDescription);
	qsort_b(dms, nFormats, sizeof(CMVideoDimensions), ^(const void *p, const void *q) {
		CMVideoDimensions a = *((CMVideoDimensions *)p), b = *((CMVideoDimensions *)q);
		return (a.width < b.width)? -1 : (a.width > b.width)? 1 :
			(a.height < b.height)? -1 : (a.height > b.height)? 1 : 0;
	});
	for (NSInteger i = 0; i < nFormats; i ++) {
		CMVideoDimensions dm = dms[i];
		NSString *title = [NSString stringWithFormat:@"%d x %d", dm.width, dm.height];
		[camSizePopUp addItemWithTitle:title];
		if (dm.width == activeDm.width && dm.height == activeDm.height)
			titleToBeSelected = title;
	}
	if (titleToBeSelected) [camSizePopUp selectItemWithTitle:titleToBeSelected];
}
- (void)adaptToVideoDimensions:(CMVideoDimensions)dimen {
	vDataOut.videoSettings = @{
		(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_OneComponent8),
		(id)kCVPixelBufferWidthKey:@(dimen.width),
		(id)kCVPixelBufferHeightKey:@(dimen.height)};
}
- (void)setupCamera:(AVCaptureDevice *)cam {
	NSError *error;
	AVCaptureDeviceInput *devIn = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&error];
	MyWarning(devIn, @"Cannot make a video device input. %@", error.localizedDescription);
	if (devIn == nil) return;
	AVCaptureDeviceInput *orgDevIn = nil;
	for (AVCaptureDeviceInput *input in ses.inputs)
		if ([input.device hasMediaType:AVMediaTypeVideo]) { orgDevIn = input; break; }
	if (orgDevIn != nil) [ses removeInput:orgDevIn];
	BOOL canAddIt = [ses canAddInput:devIn];
	MyWarning(canAddIt, @"Cannot add input.", nil)
	if (canAddIt) {
		[ses addInput:devIn];
		camera = cam;
		NSArray<NSNumber *> *dfltDim = [UserDefaults arrayForKey:keyCamFrameSize];
		CMVideoDimensions dimen;
		if (dfltDim) {
			dimen.width = dfltDim[0].intValue;
			dimen.height = dfltDim[1].intValue;
		} else dimen = size_of_camera_frame(camera);
		[self adaptToVideoDimensions:dimen];
		if (camSizePopUp) [self setupCamSizePopUp:dimen];
	} else if (orgDevIn != nil) [ses addInput:orgDevIn];
}
- (AVCaptureDevice *)cameraFromName:(NSString *)name {
	for (AVCaptureDevice *cam in camSearch.devices)
		if ([name isEqualToString:cam.localizedName]) return cam;
	return nil;
}
- (void)setupDefaultCamera {
	NSString *camName = [UserDefaults objectForKey:keyCameraName];
	AVCaptureDevice *camDev = camSearch.devices[0];
	if (camName != nil) {
		AVCaptureDevice *camDev2 = [self cameraFromName:camName];
		if (camDev2 != nil) camDev = camDev2;
	}
	[self setupCamera:camDev];
}
- (void)startStop:(BOOL)start {
	if (ses.running == start || camera == nil) return;
	else if (start) [ses startRunning];
	else [ses stopRunning];
}
- (instancetype)init {
	if (!(self = [super init])) return nil;
	camSearch = [AVCaptureDeviceDiscoverySession
		discoverySessionWithDeviceTypes:
			@[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeExternal]
		mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
	ses = AVCaptureSession.new;
	[camSearch addObserver:self forKeyPath:@"devices"
		options:NSKeyValueObservingOptionOld context:nil];

	AVCaptureSessionPreset preset = AVCaptureSessionPreset1920x1080;
	MyAssert([ses canSetSessionPreset:preset], @"Cannot set session preset as %@.", preset);
	ses.sessionPreset = preset;
	vDataOut = AVCaptureVideoDataOutput.new;
	MyAssert([ses canAddOutput:vDataOut], @"Cannot add output.",nil);
	[ses addOutput:vDataOut];
	[vDataOut setSampleBufferDelegate:self queue:
		dispatch_queue_create("My capturing", DISPATCH_QUEUE_SERIAL)];

	lock = NSConditionLock.new;
	if (camSearch.devices.count > 0) {
		[self setupDefaultCamera];
		[ses startRunning];
	} else [(AppDelegate *)NSApp.delegate enableOperations:NO];
	return self;
}
- (void)makeCameraListForPreference {
	[cameraPopUp removeAllItems];
	NSArray<AVCaptureDevice *> *camList = camSearch.devices;
	if ((cameraPopUp.enabled = camList.count > 0))
		for (AVCaptureDevice *dev in camList)
			[cameraPopUp addItemWithTitle:dev.localizedName];
	[cameraPopUp selectItemWithTitle:camera.localizedName];
}
- (void)setCameraPopUp:(NSPopUpButton *)camPopUp sizePopUp:(NSPopUpButton *)sizePopUp {
	cameraPopUp = camPopUp;
	camSizePopUp = sizePopUp;
	[self makeCameraListForPreference];
	[self setupCamSizePopUp:size_of_camera_frame(camera)];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object 
	change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
	if (object != camSearch) return;
	NSArray<AVCaptureDevice *> *devs = camSearch.devices,
		*oldDevs = change[NSKeyValueChangeOldKey];
	if (devs.count == 0) {
		camera = nil;
		[ses stopRunning];
		[(AppDelegate *)NSApp.delegate enableOperations:NO];
	} else if (oldDevs.count == 0) {
		[self setupDefaultCamera];
		[ses startRunning];
		[(AppDelegate *)NSApp.delegate enableOperations:YES];
	} else if (devs.count > oldDevs.count) {
		NSString *camName = [UserDefaults stringForKey:keyCameraName];
		if (![camName isEqualToString:camera.localizedName]) {
			AVCaptureDevice *newCam = nil;
			for (AVCaptureDevice *cam in devs)
				if (![oldDevs containsObject:cam]) { newCam = cam; break; }
			if ([camName isEqualToString:newCam.localizedName])
				[self setupCamera:newCam];
		}
	} else if (![devs containsObject:camera]) [self setupDefaultCamera];
	if (cameraPopUp != nil) [self makeCameraListForPreference];
}
- (void)chooseCamera:(NSPopUpButton *)camPopUp {
	NSString *camName = camPopUp.titleOfSelectedItem;
	AVCaptureDevice *camDev = [self cameraFromName:camName];
	if (camDev == nil) return;
	[self setupCamera:camDev];
	[UserDefaults setObject:camName forKey:keyCameraName];
}
- (void)chooseCamSize:(NSPopUpButton *)sizePopUp {
	CMVideoDimensions dm = size_from_menu_item(sizePopUp.selectedItem);
	[self adaptToVideoDimensions:dm];
	[UserDefaults setObject:@[@(dm.width), @(dm.height)] forKey:keyCamFrameSize];
}
@end
