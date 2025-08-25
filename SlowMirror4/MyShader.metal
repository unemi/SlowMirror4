//
// MyShader.metal
// SlowMirror4
//
// Created by Tatsuo Unemi on 2025/08/12
//
#include <CoreImage/CoreImage.h>
#include <metal_stdlib>

extern "C" {
    namespace coreimage {
        float4 BrightnessFilter(sampler src, float brightness) {
			return src.sample(src.coord()) *
				float4(brightness, brightness, brightness, 1.);
		}
		float4 BrightnessWindowFilter(sampler src,
			float lower, float upper, float bias) {
			float a = src.sample(src.coord()).r;
			float b = (a - lower) / (upper - lower);
			b = ((b < 0.)? 0. : (b > 1.)? 1. : b) * bias;
			return float4(b, b, b, 1.);
		}
		float foo(float x, float a) {
			return (x < .5)?
				pow(x * 2., a) * .5 :
				1. - pow((1. - x) * 2., a) * .5;
		}
		float4 ContrastAndBrightness(sampler src,
			float contrast, float opacity) {
			float a = pow(10., contrast);
			float4 c = src.sample(src.coord());
			c.xyz = float3(foo(c.x, a), foo(c.y, a), foo(c.z, a))
				* opacity;
			return c;
		}
    }
}
