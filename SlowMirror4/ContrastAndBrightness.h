//
//  ContrastAndBrightness.h
//
//  Created by Tatsuo Unemi on 09/10/18.
//  Copyright Tatsuo Unemi 2009. All rights reserved.

@import CoreImage.CIFilter;

@interface BrightnessWindowFilter : CIFilter
{
    CIImage *inputImage;
	NSNumber *inputLowerLimit;
	NSNumber *inputUpperLimit;
	NSNumber *inputBias;
}
@end

@interface BrightnessFilter : CIFilter
{
    CIImage *inputImage;
	NSNumber *inputBrightness;
}
@end

@interface ContrastAndBrightness : CIFilter
{
    CIImage *inputImage;
	NSNumber *inputContrast;
	NSNumber *inputOpacity;
}
@end
