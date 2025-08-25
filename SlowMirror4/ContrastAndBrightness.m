//
//  ContrastAndBrightness.m
//
//  Created by Tatsuo Unemi on 09/10/18.
//  Copyright Tatsuo Unemi 2009. All rights reserved.
//

#import "ContrastAndBrightness.h"
#import "AppDelegate.h"
@import CoreImage.CIKernel;
@import CoreImage.CISampler;

static CIKernel *get_ci_kernel(NSString *funcName) {
	static NSData *MTLLibData = nil;
	if (MTLLibData == nil) {
		NSString *path = [NSBundle.mainBundle pathForResource:@"default" ofType:@"metallib"];
		if (path == nil) err_msg(@"Could not find a default Metal library.", YES);
		NSData *data = [NSData dataWithContentsOfFile:path];
		if (data == nil) err_msg(@"Could not read the default Metal library.", YES);
		MTLLibData = data;
	}
	NSError *error;
	CIKernel *ciKernel = [CIKernel kernelWithFunctionName:funcName
		fromMetalLibraryData:MTLLibData error:&error];
	if (ciKernel == nil) err_msg(error, YES);
	return ciKernel;
}
@implementation BrightnessWindowFilter
static CIKernel *_BrightnessWindowFilter = nil;
- (id)init {
	if(_BrightnessWindowFilter == nil)
		_BrightnessWindowFilter = get_ci_kernel(@"BrightnessWindowFilter");
	return [super init];
}
- (NSDictionary *)customAttributes {
	return @{@"inputLowerLimit":
		@{kCIAttributeType: kCIAttributeTypeScalar,
		kCIAttributeMin:@(0.), kCIAttributeMax:@(1.), kCIAttributeDefault:@(.1)},
		@"inputUpperLimit":
		@{kCIAttributeType: kCIAttributeTypeScalar,
		kCIAttributeMin:@(0.), kCIAttributeMax:@(1.), kCIAttributeDefault:@(.9)},
		@"inputBias":
		@{kCIAttributeType: kCIAttributeTypeScalar,
		kCIAttributeMin:@(0.), kCIAttributeMax:@(1.), kCIAttributeDefault:@(1.)}};
}
- (CIImage *)outputImage {
	CISampler *src = [CISampler samplerWithImage:inputImage];
    return [self apply:_BrightnessWindowFilter,
		src, inputLowerLimit, inputUpperLimit, inputBias, nil];
}
@end

@implementation BrightnessFilter
static CIKernel *_BrightnessFilter = nil;
- (id)init {
	if(_BrightnessFilter == nil)
		_BrightnessFilter = get_ci_kernel(@"BrightnessFilter");
	return [super init];
}
- (NSDictionary *)customAttributes {
	return @{@"inputBrightness":
		@{kCIAttributeType: kCIAttributeTypeScalar,
		kCIAttributeMin:@(0.), kCIAttributeMax:@(1.), kCIAttributeDefault:@(1.)}};
}
- (CIImage *)outputImage {
	CISampler *src = [CISampler samplerWithImage:inputImage];
    return [self apply:_BrightnessFilter,
		src, inputBrightness, nil];
}
@end

@implementation ContrastAndBrightness
static CIKernel *_ContrastAndBrightness = nil;
- (id)init {
	if(_ContrastAndBrightness == nil)
		_ContrastAndBrightness = get_ci_kernel(@"ContrastAndBrightness");
	return [super init];
}
- (NSDictionary *)customAttributes {
	return @{@"inputContrast":
		@{kCIAttributeType: kCIAttributeTypeScalar,
		kCIAttributeMin: @(-2.), kCIAttributeMax:@(2.),
		kCIAttributeDefault: @(0.), kCIAttributeIdentity: @(0.)},
		@"inputOpacity":
		@{kCIAttributeType: kCIAttributeTypeScalar,
		kCIAttributeMin: @(0.), kCIAttributeMax:@(1.),
		kCIAttributeDefault: @(1.), kCIAttributeIdentity: @(1.)}};
}
- (CIImage *)outputImage {
	CISampler *src = [CISampler samplerWithImage:inputImage];
    return [self apply:_ContrastAndBrightness,
		src, inputContrast, inputOpacity, nil];
}
@end
