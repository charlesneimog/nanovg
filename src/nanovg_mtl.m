// Copyright (c) 2017 Ollix
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// ---
// Author: olliwang@ollix.com (Olli Wang)

#include <math.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>

#include "nanovg_mtl.h"
#import <Metal/Metal.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#endif
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#include <TargetConditionals.h>

#include "nanovg.h"

#if TARGET_OS_SIMULATOR
#  include "mnvg_bitcode/simulator.h"
#elif TARGET_OS_IOS
#  include "mnvg_bitcode/ios.h"
#elif TARGET_OS_OSX
#  include "mnvg_bitcode/macos.h"
#elif TARGET_OS_TV
#  include "mnvg_bitcode/tvos.h"
#else
#  define MNVG_INVALID_TARGET
#endif

#define MNVG_GET_CONTEXT(ctx) (__bridge MNVGcontext*)(*(void**)ctx)

typedef enum MNVGvertexInputIndex {
    MNVG_VERTEX_INPUT_INDEX_VERTICES = 0,
    MNVG_VERTEX_INPUT_INDEX_VIEW_SIZE = 1,
} MNVGvertexInputIndex;

enum MNVGcallType {
    MNVG_NONE = 0,
    MNVG_FILL,
    MNVG_CONVEXFILL,
    MNVG_STROKE,
    MNVG_TRIANGLES,
};

const MTLBlendFactor MNVGBlendFactors[12] = {
    0,
    MTLBlendFactorZero,
    MTLBlendFactorOne,
    MTLBlendFactorSourceColor,
    MTLBlendFactorOneMinusSourceColor,
    MTLBlendFactorDestinationColor,
    MTLBlendFactorOneMinusDestinationColor,
    MTLBlendFactorSourceAlpha,
    MTLBlendFactorOneMinusSourceAlpha,
    MTLBlendFactorDestinationAlpha,
    MTLBlendFactorOneMinusDestinationAlpha,
    MTLBlendFactorSourceAlphaSaturated
};

struct MNVGblend {
    MTLBlendFactor srcRGB;
    MTLBlendFactor dstRGB;
    MTLBlendFactor srcAlpha;
    MTLBlendFactor dstAlpha;
};
typedef struct MNVGblend MNVGblend;

struct MNVGcall {
    int type;
    int image;
    int pathOffset;
    int pathCount;
    int triangleOffset;
    int triangleCount;
    int indexOffset;
    int indexCount;
    int strokeOffset;
    int strokeCount;
    int uniformOffset;
    MNVGblend blendFunc;
};
typedef struct MNVGcall MNVGcall;

struct MNVGfragUniforms {
    int type;
    int innerCol;
    int outerCol;
    int dashCol;
    float scissorMat[6];
    float paintMat[6];
    vector_float2 scissorExt;
    vector_float2 extent;
    float radius;
    float feather;
    float strokeMult;
    float scissorRadius;
    float offset;
    float lineLength;
    int stateData;
};

typedef struct MNVGfragUniforms MNVGfragUniforms;


struct MNVGrenderData {
    atomic_int image;
    MNVGcall* calls;
    atomic_int ccalls;
    atomic_int ncalls;
    uint32_t* indexes;
    atomic_int cindexes;
    atomic_int nindexes;
    struct NVGvertex* verts;
    atomic_int cverts;
    atomic_int nverts;
    unsigned char* uniforms;
    atomic_int cuniforms;
    atomic_int nuniforms;
};
typedef struct MNVGrenderData MNVGrenderData;

__attribute__((objc_direct_members))
@interface MNVGtexture : NSObject {
@public
    int id;
    int type;
    int flags;
    id<MTLTexture> tex;
    id<MTLSamplerState> sampler;
    bool valid;
}
@end

__attribute__((objc_direct_members))
@interface MNVGbuffers : NSObject

@property (nonatomic, strong) id<MTLCommandBuffer> commandBuffer;
@property (nonatomic, strong) id<MTLBuffer> viewSizeBuffer;
@property (nonatomic, strong) id<MTLTexture> stencilTexture;
@property (nonatomic, strong) id<MTLBuffer> indexBuffer;
@property (nonatomic, strong) id<MTLBuffer> vertBuffer;
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;
@property (nonatomic, assign) atomic_int isBusy;
@property (nonatomic, assign) MNVGrenderData* renderData;
@end

__attribute__((objc_direct_members))
@interface MNVGcontext : NSObject

@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) CAMetalLayer* metalLayer;
@property (nonatomic, strong) id <MTLRenderCommandEncoder> renderEncoder;

@property (nonatomic, assign) int fragSize;
@property (nonatomic, assign) int indexSize;
@property (nonatomic, assign) int flags;
@property (nonatomic, assign) vector_uint2 viewPortSize;
@property (nonatomic, assign) MTLClearColor clearColor;
@property (nonatomic, assign) BOOL clearBufferOnFlush;
@property (nonatomic, assign) int lastUniformOffset;
@property (nonatomic, assign) int lastBoundTexture;
@property (nonatomic, weak)   id<MTLTexture> lastColorTexture;
// Textures
@property (nonatomic, strong) NSMutableArray<MNVGtexture*>* textures;
@property int textureId;

// Per frame buffers
@property (nonatomic, assign) MNVGbuffers* buffers;
@property (nonatomic, strong) NSMutableArray* cbuffers;
@property (nonatomic, assign) int maxBuffers;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;

// Cached states.
@property (nonatomic, assign) MNVGblend* blendFunc;
@property (nonatomic, strong) id<MTLDepthStencilState> defaultStencilState;
@property (nonatomic, strong) id<MTLDepthStencilState> fillShapeStencilState;
@property (nonatomic, strong) id<MTLDepthStencilState>
fillAntiAliasStencilState;
@property (nonatomic, strong) id<MTLDepthStencilState> fillStencilState;
@property (nonatomic, strong) id<MTLDepthStencilState> strokeShapeStencilState;
@property (nonatomic, strong) id<MTLDepthStencilState>
strokeAntiAliasStencilState;
@property (nonatomic, strong) id<MTLDepthStencilState> strokeClearStencilState;
@property (nonatomic, strong) id<MTLFunction> fragmentFunction;
@property (nonatomic, strong) id<MTLFunction> vertexFunction;
@property MTLPixelFormat piplelinePixelFormat;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLRenderPipelineState>
stencilOnlyPipelineState;
@property (nonatomic, strong) id<MTLSamplerState> pseudoSampler;
@property (nonatomic, strong) id<MTLTexture> pseudoTexture;
@property (nonatomic, strong) MTLVertexDescriptor* vertexDescriptor;

- (MNVGtexture*)allocTexture;

- (void)convexFill:(MNVGcall*)call;

-(void)fill:(MNVGcall*)call;

- (MNVGtexture*)findTexture:(int)id;

- (void)renderCancel;

- (int)renderCreate;

- (void)renderDelete;

- (int)renderDeleteTexture:(int)image;

- (int)renderCreateTextureWithType:(int)type
                             width:(int)width
                            height:(int)height
                        imageFlags:(int)imageFlags
                              data:(const unsigned char*)data;

- (void)renderFillWithPaint:(NVGpaint*)paint
         compositeOperation:(NVGcompositeOperationState)compositeOperation
                    scissor:(NVGscissor*)scissor
                     fringe:(float)fringe
                     bounds:(const float*)bounds
                      paths:(const NVGpath*)paths
                     npaths:(int)npaths;

- (void)renderFlush:(MTLScissorRect)scissorRect;

- (int)renderGetTextureSizeForImage:(int)image
                              width:(int*)width
                             height:(int*)height;

- (void)blitTextureToScreen:(MNVGtexture*)mnvgTexture;

- (void)renderStrokeWithPaint:(NVGpaint*)paint
           compositeOperation:(NVGcompositeOperationState)compositeOperation
                      scissor:(NVGscissor*)scissor
                       fringe:(float)fringe
                  strokeWidth:(float)strokeWidth
                    lineStyle:(int)lineStyle
                   lineLength:(float)lineLength
                        paths:(const NVGpath*)paths
                       npaths:(int)npaths;

- (void)renderTrianglesWithPaint:(NVGpaint*) paint
              compositeOperation:(NVGcompositeOperationState)compositeOperation
                         scissor:(NVGscissor*)scissor
                           verts:(const NVGvertex*)verts
                          nverts:(int)nverts
                          fringe:(float)fringe
                            text:(int)text;

- (int)renderUpdateTextureWithImage:(int)image
                                  x:(int)x
                                  y:(int)y
                              width:(int)width
                             height:(int)height
                               data:(const unsigned char*)data;

- (void)renderViewportWithWidth:(float)width
                         height:(float)height
               devicePixelRatio:(float)devicePixelRatio;

- (void)stroke:(MNVGcall*)call;

- (void)triangles:(MNVGcall*)call;

- (void)updateRenderPipelineStatesForBlend:(MNVGblend*)blend
                               pixelFormat:(MTLPixelFormat)pixelFormat;

@end

// Keeps the weak reference to the currently binded framebuffer.
MNVGframebuffer* s_framebuffer = NULL;

const MTLResourceOptions kMetalBufferOptions = (MTLResourceCPUCacheModeWriteCombined | MTLResourceStorageModeShared);

#if TARGET_OS_SIMULATOR
const MTLPixelFormat kStencilFormat = MTLPixelFormatDepth32Float_Stencil8;
#else
const MTLPixelFormat kStencilFormat = MTLPixelFormatStencil8;
#endif  // TARGET_OS_SIMULATOR

typedef enum {
    PACK_LINE_STYLE,
    PACK_TEX_TYPE,
    PACK_REVERSE,
    PACK_FLAG_TYPE,
    PACK_OBJECT_STYLE
} PackType;

static int nvg__packStateDataUniform(PackType packType, int value) {
    switch (packType) {
        case PACK_OBJECT_STYLE:
            return (value & 0x01) << 12;
        case PACK_FLAG_TYPE:
            return (value & 0x03) << 10;
        case PACK_LINE_STYLE:
            return (value & 0x03) << 8;
        case PACK_TEX_TYPE:
            return (value & 0x07) << 5;
        case PACK_REVERSE:
            return value & 0x01;
        default:
            return 0;
    }
}

static int nvg__maxi(int a, int b) { return a > b ? a : b; }

static int nvg__maxVertCount(const NVGpath* paths, int npaths,
                                int* indexCount, int* strokeCount) {
    int count = 0;
    if (indexCount != NULL) *indexCount = 0;
    if (strokeCount != NULL) *strokeCount = 0;
    NVGpath* path = (NVGpath*)&paths[0];
    for (int i = npaths; i--; ++path) {
        const int nfill = path->nfill;
        if (nfill > 2) {
            count += nfill;
            if (indexCount != NULL)
                *indexCount += (nfill - 2) * 3;
        }
        if (path->nstroke > 0) {
            const int nstroke = path->nstroke + 2;
            count += nstroke;
            if (strokeCount != NULL) *strokeCount += nstroke;
        }
    }
    return count;
}

void nvg__renderCancel(void* uptr) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    [mtl renderCancel];
}

int nvg__renderCreateTexture(void* uptr, int type, int width,
                                       int height, int imageFlags,
                                       const unsigned char* data) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    return [mtl renderCreateTextureWithType:type
                                      width:width
                                     height:height
                                 imageFlags:imageFlags
                                       data:data];
}

int nvg__renderCreate(void* uptr) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    return [mtl renderCreate];
}

void nvg__renderDelete(void* uptr) {
    MNVGcontext* mtl = (__bridge_transfer MNVGcontext*)uptr;
    [mtl renderDelete];
}

int nvg__renderDeleteTexture(void* uptr, int image) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    return [mtl renderDeleteTexture:image];
}

void nvg__renderFill(void* uptr, NVGpaint* paint,
                               NVGcompositeOperationState compositeOperation,
                               NVGscissor* scissor, float fringe,
                               const float* bounds, const NVGpath* paths,
                               int npaths) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    [mtl renderFillWithPaint:paint
          compositeOperation:compositeOperation
                     scissor:scissor
                      fringe:fringe
                      bounds:bounds
                       paths:paths
                      npaths:npaths];
}

void nvg__renderFlush(void* uptr, NVGscissorBounds scissor) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    MTLScissorRect scissorRect = { .x = scissor.x, .y = scissor.y, .width = scissor.w, .height = scissor.h, };
    [mtl renderFlush: scissorRect];
}


int nvg__renderGetTextureSize(void* uptr, int image, int* w, int* h) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    return [mtl renderGetTextureSizeForImage:image width:w height:h];
}

void nvg__renderStroke(void* uptr, NVGpaint* paint,
                                 NVGcompositeOperationState compositeOperation,
                                 NVGscissor* scissor, float fringe,
                                 float strokeWidth, int lineStyle, float lineLength, const NVGpath* paths,
                                 int npaths) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    [mtl renderStrokeWithPaint:paint
            compositeOperation:compositeOperation
                       scissor:scissor
                        fringe:fringe
                   strokeWidth:strokeWidth
                     lineStyle:lineStyle
                    lineLength:lineLength
                         paths:paths
                        npaths:npaths];
}

void nvg__renderTriangles(
                                    void* uptr, NVGpaint* paint, NVGcompositeOperationState compositeOperation,
                                    NVGscissor* scissor, const NVGvertex* verts, int nverts, float fringe, int text) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    [mtl renderTrianglesWithPaint:paint
               compositeOperation:compositeOperation
                          scissor:scissor
                            verts:verts
                           nverts:nverts
                           fringe:fringe
                             text:text];
}

int nvg__renderUpdateTexture(void* uptr, int image, int x, int y,
                                       int w, int h,
                                       const unsigned char* data) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    return [mtl renderUpdateTextureWithImage:image
                                           x:x
                                           y:y
                                       width:w
                                      height:h
                                        data:data];
}

void nvg__renderViewport(void* uptr, float width, float height,
                                   float devicePixelRatio) {
    MNVGcontext* mtl = (__bridge MNVGcontext*)uptr;
    [mtl renderViewportWithWidth:width
                          height:height
                devicePixelRatio:devicePixelRatio];
}

#if TARGET_OS_IPHONE

void mnvgSetViewBounds(void* view, int width, int height) {
    [(CAMetalLayer*)[(__bridge UIView*)view layer] setDrawableSize:CGSizeMake(width, height)];
}

NVGcontext* mnvgCreateContext(void* view, int flags, int width, int height) {
    CAMetalLayer *metalLayer = (CAMetalLayer*)[(__bridge UIView*)view layer];
    id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
    if (!metalDevice) return NULL;

    MTLPixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm;

    [metalLayer setPixelFormat:pixelFormat];
    [metalLayer setDevice: metalDevice];
    [metalLayer setDrawableSize:CGSizeMake(width, height)];
    [metalLayer setFramebufferOnly:FALSE];
    return nvgCreateMTL((__bridge void*)metalLayer, flags);
}
#else
void mnvgSetViewBounds(void* view, int width, int height) {
    [(CAMetalLayer*)[(__bridge NSView*)view layer] setDrawableSize:CGSizeMake(width, height)];
}

NVGcontext* mnvgCreateContext(void* view, int flags, int width, int height) {
    CAMetalLayer *metalLayer = [CAMetalLayer new];
    id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
    if (!metalDevice) return NULL;

    MTLPixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm;

    ((__bridge NSView*) view).layer = metalLayer;
    [metalLayer setPixelFormat:pixelFormat];
    [metalLayer setDevice: metalDevice];
    [metalLayer setDrawableSize:CGSizeMake(width, height)];
    [metalLayer setPresentsWithTransaction:TRUE];
    [metalLayer setFramebufferOnly:FALSE];
    return nvgCreateMTL((__bridge void*)((__bridge NSView*) view).layer, flags);
}
#endif

NVGcontext* nvgCreateMTL(void* metalLayer, int flags) {
#ifdef MNVG_INVALID_TARGET
    printf("Metal is only supported on iOS, macOS, and tvOS.\n");
    return NULL;
#endif  // MNVG_INVALID_TARGET

    MNVGcontext* mtl = [MNVGcontext new];

    mtl.flags = flags;
#if __aarch64__ && !TARGET_OS_SIMULATOR
    mtl.fragSize = sizeof(MNVGfragUniforms);
#else
    mtl.fragSize = 256;
#endif
    mtl.lastUniformOffset = 0;
    mtl.lastBoundTexture = -1;
    mtl.indexSize = 4;  // MTLIndexTypeUInt32
    mtl.metalLayer = (__bridge CAMetalLayer*)metalLayer;

    NVGcontext* ctx = nvgCreateInternal((__bridge_retained void*)mtl);
    if (ctx == NULL) goto error;
    return ctx;

error:
    // 'mtl' is freed by nvgDeleteInternal.
    if (ctx != NULL) nvgDeleteInternal(ctx);
    return NULL;
}

static void nvg__vset(NVGvertex* vtx, float x, float y, float u, float v) {
    int16_t scaling_factor = 1 << 14;
    vtx->x = x;
    vtx->y = y;
    vtx->u = u * scaling_factor;
    vtx->v = v * scaling_factor;
}

void nvgDeleteMTL(NVGcontext* ctx) {
    nvgDeleteInternal(ctx);
}

void mnvgBindFramebuffer(MNVGframebuffer* framebuffer) {
    s_framebuffer = framebuffer;
}

MNVGframebuffer* mnvgCreateFramebuffer(NVGcontext* ctx, int width,
                                       int height, int imageFlags) {
    MNVGframebuffer* framebuffer = (MNVGframebuffer*)malloc(sizeof(MNVGframebuffer));
    if (framebuffer == NULL)
        return NULL;

    memset(framebuffer, 0, sizeof(MNVGframebuffer));
    framebuffer->image = nvgCreateImageRGBA(ctx, width, height,
                                            imageFlags | NVG_IMAGE_PREMULTIPLIED,
                                            NULL);
    
    framebuffer->ctx = ctx;
    return framebuffer;
}

void mnvgDeleteFramebuffer(MNVGframebuffer* framebuffer) {
    if (framebuffer == NULL) return;
    if (framebuffer->image > 0) {
        nvgDeleteImage(framebuffer->ctx, framebuffer->image);
    }
    free(framebuffer);
}

int mnvgBlitFramebuffer(NVGcontext* ctx, MNVGframebuffer* fb, int x, int y, int w, int h)
{
    MNVGcontext* mtl = MNVG_GET_CONTEXT(ctx);
    MNVGtexture* tex = [mtl findTexture:fb->image];
    [mtl blitTextureToScreen:tex];
    return 1;
}

void mnvgClearWithColor(NVGcontext* ctx, NVGcolor color) {
    
    MNVGcontext* mtl = MNVG_GET_CONTEXT(ctx);
    float alpha = (float)color.a;
    mtl.clearColor = MTLClearColorMake((float)color.r * alpha,
                                       (float)color.g * alpha,
                                       (float)color.b * alpha,
                                       (float)color.a);
    mtl.clearBufferOnFlush = YES;
}

void mnvgReadPixels(NVGcontext* ctx, MNVGframebuffer* fb, int x, int y, int width,
                    int height, void* data) {
  MNVGcontext* mtl = MNVG_GET_CONTEXT(ctx);

  MNVGtexture* tex = [mtl findTexture:fb->image];
  if (tex == nil) return;

  NSUInteger bytesPerRow;
  if (tex->type == NVG_TEXTURE_RGBA || tex->type == NVG_TEXTURE_ARGB) {
    bytesPerRow = width * 4;
  } else {
    bytesPerRow = width;
  }

  // Makes sure the command execution for the image has been done.
  for (MNVGbuffers* buffers in mtl.cbuffers) {
    if (buffers.isBusy && buffers.renderData && buffers.renderData->image == fb->image && buffers.commandBuffer) {
      id<MTLCommandBuffer> commandBuffer = buffers.commandBuffer;
      while(buffers.isBusy) usleep(10);
      break;
    }
  }

#if TARGET_OS_SIMULATOR
  CAMetalLayer* metalLayer = mtl.metalLayer;
  const NSUInteger kBufferSize = bytesPerRow * height;
  id<MTLBuffer> buffer = [metalLayer.device
      newBufferWithLength:kBufferSize
      options:MTLResourceStorageModeShared];

  id<MTLCommandBuffer> commandBuffer = [mtl.commandQueue commandBuffer];
  id<MTLBlitCommandEncoder> blitCommandEncoder = [commandBuffer
      blitCommandEncoder];
  [blitCommandEncoder copyFromTexture:tex->tex
      sourceSlice:0
      sourceLevel:0
      sourceOrigin:MTLOriginMake(x, y, 0)
      sourceSize:MTLSizeMake(width, height, 1)
      toBuffer:buffer
      destinationOffset:0
      destinationBytesPerRow:bytesPerRow
      destinationBytesPerImage:kBufferSize];

  [blitCommandEncoder endEncoding];
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  memcpy(data, [buffer contents], kBufferSize);
#else
  [tex->tex getBytes:data
         bytesPerRow:bytesPerRow
          fromRegion:MTLRegionMake2D(x, y, width, height)
         mipmapLevel:0];
#endif  // TARGET_OS_SIMULATOR
}

void* mnvgDevice(NVGcontext* ctx) {
    MNVGcontext* mtl = MNVG_GET_CONTEXT(ctx);
    return (__bridge void*)mtl.metalLayer.device;
}

@implementation MNVGbuffers
@end

@implementation MNVGcontext

- (MNVGcall*)allocCall {
    MNVGcall* ret = NULL;
    MNVGrenderData* renderData = _buffers.renderData;
    if (renderData->ncalls + 1 > renderData->ccalls) {
        MNVGcall* calls;
        int ccalls = nvg__maxi(renderData->ncalls + 1, 128) + renderData->ccalls / 2;
        calls = (MNVGcall*)realloc(renderData->calls, sizeof(MNVGcall) * ccalls);
        if (calls == NULL) return NULL;
        renderData->calls = calls;
        renderData->ccalls = ccalls;
    }
    ret = &renderData->calls[renderData->ncalls++];
    memset(ret, 0, sizeof(MNVGcall));
    return ret;
}

- (int)allocFragUniforms:(int)n {
    MNVGrenderData* renderData = _buffers.renderData;
    int ret = 0;
    if (renderData->nuniforms + n > renderData->cuniforms) {
        int cuniforms = nvg__maxi(renderData->nuniforms + n, 128) + renderData->cuniforms / 2;
        id<MTLBuffer> buffer = [_metalLayer.device
                                newBufferWithLength:(_fragSize * cuniforms)
                                options:kMetalBufferOptions];
        unsigned char* uniforms = [buffer contents];
        if (_buffers.uniformBuffer != nil) {
            memcpy(uniforms, renderData->uniforms,
                   _fragSize * renderData->nuniforms);
        }
        _buffers.uniformBuffer = buffer;
        renderData->uniforms = uniforms;
        renderData->cuniforms = cuniforms;
    }
    ret = renderData->nuniforms * _fragSize;
    renderData->nuniforms += n;
    return ret;
}

- (int)allocIndexes:(int)n {
    int ret = 0;
    MNVGrenderData* renderData = _buffers.renderData;
    if (renderData->nindexes + n > renderData->cindexes) {
        int cindexes = nvg__maxi(renderData->nindexes + n, 4096) + renderData->cindexes / 2;
        id<MTLBuffer> buffer = [_metalLayer.device
                                newBufferWithLength:(_indexSize * cindexes)
                                options:kMetalBufferOptions];
        uint32_t* indexes = [buffer contents];
        if (_buffers.indexBuffer != nil) {
            memcpy(indexes, renderData->indexes, _indexSize * renderData->nindexes);
        }
        _buffers.indexBuffer = buffer;
        renderData->indexes = indexes;
        renderData->cindexes = cindexes;
    }
    ret = renderData->nindexes;
    renderData->nindexes += n;
    return ret;
}

- (MNVGtexture*)allocTexture {
    MNVGtexture* tex = nil;

    for (MNVGtexture* texture in _textures) {
        if (texture->valid == 0) {
            tex = texture;
            break;
        }
    }
    if (tex == nil) {
        tex = [MNVGtexture new];
        [_textures addObject:tex];
        tex->id = ++_textureId;
    }
    tex->valid = true;
    return tex;
}

- (int)allocVerts:(int)n {
    MNVGrenderData* renderData = _buffers.renderData;
    int ret = 0;
    if (renderData->nverts + n > renderData->cverts) {
        int cverts = nvg__maxi(renderData->nverts + n, 4096) + renderData->cverts / 2;
        id<MTLBuffer> buffer = [_metalLayer.device
                                newBufferWithLength:(sizeof(NVGvertex) * cverts)
                                options:kMetalBufferOptions];
        NVGvertex* verts = [buffer contents];
        if (_buffers.vertBuffer != nil) {
            memcpy(verts, renderData->verts, sizeof(NVGvertex) * renderData->nverts);
        }
        _buffers.vertBuffer = buffer;
        renderData->verts = verts;
        renderData->cverts = cverts;
    }
    ret = renderData->nverts;
    renderData->nverts += n;
    return ret;
}

- (MNVGblend)blendCompositeOperation:(NVGcompositeOperationState)op {
    MNVGblend blend;
    if (op.srcRGB == 0 || op.dstRGB == 0 || op.srcAlpha == 0 || op.dstAlpha == 0)
    {
        blend.srcRGB = MTLBlendFactorOne;
        blend.dstRGB = MTLBlendFactorOneMinusSourceAlpha;
        blend.srcAlpha = MTLBlendFactorOne;
        blend.dstAlpha = MTLBlendFactorOneMinusSourceAlpha;
    }
    else {
        blend.srcRGB = MNVGBlendFactors[op.srcRGB];
        blend.dstRGB = MNVGBlendFactors[op.dstRGB];
        blend.srcAlpha = MNVGBlendFactors[op.srcAlpha];
        blend.dstAlpha = MNVGBlendFactors[op.dstAlpha];
    }

    return blend;
}

- (void)checkError:(NSError*)error withMessage:(const char*)message {
    if ((_flags & NVG_DEBUG) == 0) return;
    if (error) {
        printf("Error occurs after %s: %s\n",
               message, [[error localizedDescription] UTF8String]);
    }
}

- (int)convertPaintForFrag:(MNVGfragUniforms*)frag
                     paint:(NVGpaint*)paint
                   scissor:(NVGscissor*)scissor
                     width:(float)width
                    fringe:(float)fringe
                 lineStyle:(int)lineStyle
                lineLength:(float)lineLength
              lineReversed: (int)lineReversed {
    memset(frag, 0, sizeof(*frag));

    frag->type = paint->type;
    frag->innerCol = paint->innerColor.rgba32;
    frag->outerCol = paint->outerColor.rgba32;
    frag->dashCol = paint->dashColor.rgba32;
    frag->stateData = nvg__packStateDataUniform(PACK_LINE_STYLE, lineStyle);
    frag->radius = paint->radius;
    frag->feather = paint->feather;
    frag->extent = (vector_float2){paint->extent[0], paint->extent[1]};
    frag->strokeMult = (width * 0.5f + fringe * 0.5f) / fringe;
    frag->lineLength = lineLength;
    memcpy(frag->paintMat, paint->xform, 6 * sizeof(float));

    if (scissor->extent[0] < -0.5f || scissor->extent[1] < -0.5f) {
        memset(frag->scissorMat, 0, 6 * sizeof(float));
        frag->scissorExt.x = 1.0f;
        frag->scissorExt.y = 1.0f;
        frag->scissorRadius = 0.0f;
    } else {
        memcpy(frag->scissorMat, scissor->xform, 6 * sizeof(float));
        frag->scissorExt.x = scissor->extent[0];
        frag->scissorExt.y = scissor->extent[1];
        frag->scissorRadius = scissor->radius;
    }
    
    switch (paint->type) {
        case PAINT_TYPE_FILLIMG_ALPHA:
        case PAINT_TYPE_FILLIMG: {
            MNVGtexture* tex = [self findTexture:paint->image];
            if (tex == nil) return 0;
            if (tex->flags & NVG_IMAGE_FLIPY) {
                frag->stateData |= nvg__packStateDataUniform(PACK_REVERSE, true);
            }
            if (tex->type == NVG_TEXTURE_RGBA)
                frag->stateData |= nvg__packStateDataUniform(PACK_TEX_TYPE, (tex->flags & NVG_IMAGE_PREMULTIPLIED) ? 0 : 1);
            else if(tex->type == NVG_TEXTURE_ALPHA)
                frag->stateData |= nvg__packStateDataUniform(PACK_TEX_TYPE, 4);
            else if(tex->type == NVG_TEXTURE_ARGB)
                frag->stateData |= nvg__packStateDataUniform(PACK_TEX_TYPE, 3);
            else
                frag->stateData |= nvg__packStateDataUniform(PACK_TEX_TYPE, 2);
            
            break;
        }
        case PAINT_TYPE_OBJECT_RECT: {
            frag->stateData |= nvg__packStateDataUniform(PACK_FLAG_TYPE, paint->flag_type);
            frag->stateData |= nvg__packStateDataUniform(PACK_OBJECT_STYLE, paint->flag_outline);
            frag->dashCol = paint->dashColor.rgba32;
            break;
        }
        case PAINT_TYPE_DOUBLE_STROKE_GRAD_ACTIVITY:
        case PAINT_TYPE_DOUBLE_STROKE_ACTIVITY: {
            frag->offset = paint->offset;
            break;
        }
        default: break;
    }
    return 1;
}

- (void)convexFill:(MNVGcall*)call {
    const int kIndexBufferOffset = call->indexOffset * _indexSize;
    [self setUniforms:call->uniformOffset image:call->image];
    if (call->indexCount > 0) {
        [_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                   indexCount:call->indexCount
                                    indexType:MTLIndexTypeUInt32
                                  indexBuffer:_buffers.indexBuffer
                            indexBufferOffset:kIndexBufferOffset];
    }

    // Draw fringes
    if (call->strokeCount > 0) {
        [_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:call->strokeOffset
                           vertexCount:call->strokeCount];
    }
}

-(void)fill:(MNVGcall*)call {
    // Draws shapes.
    const int kIndexBufferOffset = call->indexOffset * _indexSize;
    [_renderEncoder setCullMode:MTLCullModeNone];
    [_renderEncoder setDepthStencilState:_fillShapeStencilState];
    [_renderEncoder setRenderPipelineState:_stencilOnlyPipelineState];
    if (call->indexCount > 0) {
        [_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                   indexCount:call->indexCount
                                    indexType:MTLIndexTypeUInt32
                                  indexBuffer:_buffers.indexBuffer
                            indexBufferOffset:kIndexBufferOffset];
    }

    // Restores states.
    [_renderEncoder setCullMode:MTLCullModeBack];
    [_renderEncoder setRenderPipelineState:_pipelineState];

    // Draws anti-aliased fragments.
    [self setUniforms:call->uniformOffset image:call->image];
    if (call->strokeCount > 0) { // anti-aliasing
        [_renderEncoder setDepthStencilState:_fillAntiAliasStencilState];
        [_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:call->strokeOffset
                           vertexCount:call->strokeCount];
    }

    // Draws fill.
    [_renderEncoder setDepthStencilState:_fillStencilState];
    [_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:call->triangleOffset
                       vertexCount:call->triangleCount];
    [_renderEncoder setDepthStencilState:_defaultStencilState];
}

- (MNVGtexture* __unsafe_unretained)findTexture:(int)id {
    if (id <= 0) return nil;
    return _textures[id - 1];
}

- (MNVGfragUniforms*)fragUniformAtIndex:(int)index {
    return (MNVGfragUniforms*)&_buffers.renderData->uniforms[index];
}

- (void)renderCancel {
    MNVGrenderData* renderData = _buffers.renderData;
    
    _buffers.isBusy = NO;
    if(renderData) {
        renderData->image = 0;
        renderData->nindexes = 0;
        renderData->nverts = 0;
        renderData->ncalls = 0;
        renderData->nuniforms = 0;
    }
    
    // terrible, but it fixes a crash when closing the MNVGContext
    // we need to be very sure that _semaphore has a value of at least 3
    dispatch_semaphore_signal(_semaphore);
    dispatch_semaphore_signal(_semaphore);
    dispatch_semaphore_signal(_semaphore);
}

- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithColorTexture:
(id<MTLTexture>)colorTexture {
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    if (descriptor == nil) {
        return nil;
    }

    descriptor.colorAttachments[0].clearColor = _clearColor;
    descriptor.colorAttachments[0].loadAction = _clearBufferOnFlush ? MTLLoadActionClear : MTLLoadActionLoad;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].texture = colorTexture;
    _clearBufferOnFlush = NO;

     descriptor.stencilAttachment.clearStencil = 0;
     descriptor.stencilAttachment.loadAction = MTLLoadActionClear;
     descriptor.stencilAttachment.storeAction = MTLStoreActionDontCare;
     descriptor.stencilAttachment.texture = _buffers.stencilTexture;

    id<MTLCommandBuffer> commandBuffer = _buffers.commandBuffer;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer
                                           renderCommandEncoderWithDescriptor:descriptor];

    [encoder setCullMode:MTLCullModeBack];
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setStencilReferenceValue:0];
    [encoder setViewport:(MTLViewport)
     {0.0, 0.0, _viewPortSize.x, _viewPortSize.y, 0.0, 1.0}];

    [encoder setVertexBuffer:_buffers.vertBuffer
                      offset:0
                     atIndex:MNVG_VERTEX_INPUT_INDEX_VERTICES];

    [encoder setVertexBuffer:_buffers.viewSizeBuffer
                      offset:0
                     atIndex:MNVG_VERTEX_INPUT_INDEX_VIEW_SIZE];

    [encoder setFragmentBuffer:_buffers.uniformBuffer offset:0 atIndex:0];

    return encoder;
}

- (int)renderCreate {
    if (_metalLayer.device == nil) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        _metalLayer.device = device;
    }

    // Loads shaders from pre-compiled metal library..
    NSError* error;
    id<MTLDevice> device = _metalLayer.device;
#ifdef MNVG_INVALID_TARGET
    id<MTLLibrary> library = nil;
    return 0;
#endif

    unsigned char* metal_library_bitcode;
    unsigned int metal_library_bitcode_len;
#if TARGET_OS_SIMULATOR
    metal_library_bitcode = mnvg_bitcode_simulator;
    metal_library_bitcode_len = mnvg_bitcode_simulator_len;
#elif TARGET_OS_IOS
    if (@available(iOS 8, *)) {
    } else {
        return 0;
    }
    metal_library_bitcode = mnvg_bitcode_ios;
    metal_library_bitcode_len = mnvg_bitcode_ios_len;
#elif TARGET_OS_OSX
    if (@available(macOS 10.11, *)) {
        metal_library_bitcode = mnvg_bitcode_macos;
        metal_library_bitcode_len = mnvg_bitcode_macos_len;
    } else {
        return 0;
    }
#elif TARGET_OS_TV
    metal_library_bitcode = mnvg_bitcode_tvos;
    metal_library_bitcode_len = mnvg_bitcode_tvos_len;
#endif

    dispatch_data_t data = dispatch_data_create(metal_library_bitcode,
                                                metal_library_bitcode_len,
                                                NULL,
                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<MTLLibrary> library = [device newLibraryWithData:data error:&error];

    [self checkError:error withMessage:"init library"];
    if (library == nil) {
        return 0;
    }

    _vertexFunction = [library newFunctionWithName:@"vertexShader"];
    _fragmentFunction = [library newFunctionWithName:@"fragmentShaderAA"];

    _commandQueue = [device newCommandQueue];

    // Initializes the number of available buffers.
    if (_flags & NVG_TRIPLE_BUFFER) {
        _maxBuffers = 3;
    } else if (_flags & NVG_DOUBLE_BUFFER) {
        _maxBuffers = 2;
    } else {
        _maxBuffers = 1;
    }
    _cbuffers = [NSMutableArray arrayWithCapacity:_maxBuffers];
    for (int i = _maxBuffers; i--;) {
        MNVGbuffers *buffer = [MNVGbuffers new];
        buffer.renderData = malloc(sizeof(MNVGrenderData));
        memset(buffer.renderData, 0, sizeof(MNVGrenderData));
        [_cbuffers addObject:buffer];
    }
    _clearBufferOnFlush = NO;
    _semaphore = dispatch_semaphore_create(_maxBuffers);

    // Initializes vertex descriptor.
    _vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    _vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2;
    _vertexDescriptor.attributes[0].bufferIndex = 0;
    _vertexDescriptor.attributes[0].offset = offsetof(NVGvertex, x);

    _vertexDescriptor.attributes[1].format = MTLVertexFormatShort4Normalized;
    _vertexDescriptor.attributes[1].bufferIndex = 0;
    _vertexDescriptor.attributes[1].offset = offsetof(NVGvertex, u);

    _vertexDescriptor.layouts[0].stride = sizeof(NVGvertex);
    _vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    // Initialzes textures.
    _textureId = 0;
    _textures = [NSMutableArray array];

    MTLSamplerDescriptor* samplerDescriptor = [MTLSamplerDescriptor new];
     _pseudoSampler = [_metalLayer.device
         newSamplerStateWithDescriptor:samplerDescriptor];

    // Initializes pseudo texture
    const int kPseudoTextureImage = [self
                                     renderCreateTextureWithType:NVG_TEXTURE_ALPHA
                                     width:1
                                     height:1
                                     imageFlags:0
                                     data:NULL];
    MNVGtexture* tex = [self findTexture:kPseudoTextureImage];
    _pseudoTexture = tex->tex;

    // Initializes default blend states.
    _blendFunc = malloc(sizeof(MNVGblend));
    _blendFunc->srcRGB = MTLBlendFactorOne;
    _blendFunc->dstRGB = MTLBlendFactorOneMinusSourceAlpha;
    _blendFunc->srcAlpha = MTLBlendFactorOne;
    _blendFunc->dstAlpha = MTLBlendFactorOneMinusSourceAlpha;

    // Initializes stencil states.
    MTLDepthStencilDescriptor* stencilDescriptor = [MTLDepthStencilDescriptor new];

    // Default stencil state.
    _defaultStencilState = [device
                            newDepthStencilStateWithDescriptor:stencilDescriptor];

    
    // Fill shape stencil.
    MTLStencilDescriptor* frontFaceStencilDescriptor = [MTLStencilDescriptor new];
    frontFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionAlways;
    frontFaceStencilDescriptor.depthStencilPassOperation = MTLStencilOperationIncrementWrap;

    MTLStencilDescriptor* backFaceStencilDescriptor = [MTLStencilDescriptor new];
    backFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionAlways;
    backFaceStencilDescriptor.depthStencilPassOperation = MTLStencilOperationDecrementWrap;

    stencilDescriptor.depthCompareFunction = MTLCompareFunctionAlways;
    stencilDescriptor.backFaceStencil = backFaceStencilDescriptor;
    stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
    _fillShapeStencilState = [device
                              newDepthStencilStateWithDescriptor:stencilDescriptor];

    // Fill anti-aliased stencil.
    frontFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionEqual;
    frontFaceStencilDescriptor.stencilFailureOperation = MTLStencilOperationKeep;
    frontFaceStencilDescriptor.depthFailureOperation = MTLStencilOperationKeep;
    frontFaceStencilDescriptor.depthStencilPassOperation = MTLStencilOperationZero;

    stencilDescriptor.backFaceStencil = nil;
    stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
    _fillAntiAliasStencilState = [device
                                  newDepthStencilStateWithDescriptor:stencilDescriptor];

    // Fill stencil.
    frontFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionNotEqual;
    frontFaceStencilDescriptor.stencilFailureOperation = MTLStencilOperationZero;
    frontFaceStencilDescriptor.depthFailureOperation = MTLStencilOperationZero;
    frontFaceStencilDescriptor.depthStencilPassOperation = MTLStencilOperationZero;

    stencilDescriptor.backFaceStencil = nil;
    stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
    _fillStencilState = [device
                         newDepthStencilStateWithDescriptor:stencilDescriptor];

    // Stroke shape stencil.
    frontFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionEqual;
    frontFaceStencilDescriptor.stencilFailureOperation = MTLStencilOperationKeep;
    frontFaceStencilDescriptor.depthFailureOperation = MTLStencilOperationKeep;
    frontFaceStencilDescriptor.depthStencilPassOperation = MTLStencilOperationIncrementClamp;

    stencilDescriptor.backFaceStencil = nil;
    stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
    _strokeShapeStencilState = [device
                                newDepthStencilStateWithDescriptor:stencilDescriptor];

    // Stroke anti-aliased stencil.
    frontFaceStencilDescriptor.depthStencilPassOperation = MTLStencilOperationKeep;

    stencilDescriptor.backFaceStencil = nil;
    stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
    _strokeAntiAliasStencilState = [device
                                    newDepthStencilStateWithDescriptor:stencilDescriptor];

    // Stroke clear stencil.
    frontFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionAlways;
    frontFaceStencilDescriptor.stencilFailureOperation = MTLStencilOperationZero;
    frontFaceStencilDescriptor.depthFailureOperation = MTLStencilOperationZero;
    frontFaceStencilDescriptor.depthStencilPassOperation = MTLStencilOperationZero;

    stencilDescriptor.backFaceStencil = nil;
    stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
    _strokeClearStencilState = [device
                                newDepthStencilStateWithDescriptor:stencilDescriptor];

    return 1;
}

- (int)renderCreateTextureWithType:(int)type
                             width:(int)width
                            height:(int)height
                        imageFlags:(int)imageFlags
                              data:(const unsigned char*)data {
    MNVGtexture* tex = [self allocTexture];

    if (tex == nil) return 0;

    MTLPixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm;
    if (type == NVG_TEXTURE_ALPHA) {
        pixelFormat = MTLPixelFormatR8Unorm;
    }

    tex->type = type;
    tex->flags = imageFlags;

    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor
                                               texture2DDescriptorWithPixelFormat:pixelFormat
                                               width:width
                                               height:height
                                               mipmapped:(imageFlags & NVG_IMAGE_GENERATE_MIPMAPS ? YES : NO)];
    textureDescriptor.usage = MTLTextureUsageShaderRead
    | MTLTextureUsageRenderTarget;
#if TARGET_OS_SIMULATOR
    textureDescriptor.storageMode = MTLStorageModePrivate;
#endif  // TARGET_OS_SIMULATOR
    tex->tex = [_metalLayer.device newTextureWithDescriptor:textureDescriptor];

    if (data != NULL) {
        NSUInteger bytesPerRow;
        if (tex->type == NVG_TEXTURE_RGBA || tex->type == NVG_TEXTURE_ARGB) {
            bytesPerRow = width * 4;
        } else {
            bytesPerRow = (width + 3) & ~3;
        }

        if (textureDescriptor.storageMode == MTLStorageModePrivate) {
            const NSUInteger kBufferSize = bytesPerRow * height;
            id<MTLBuffer> buffer = [_metalLayer.device
                                    newBufferWithLength:kBufferSize
                                    options:MTLResourceStorageModeShared];
            memcpy([buffer contents], data, kBufferSize);

            id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
            id<MTLBlitCommandEncoder> blitCommandEncoder = [commandBuffer
                                                            blitCommandEncoder];
            [blitCommandEncoder copyFromBuffer:buffer
                                  sourceOffset:0
                             sourceBytesPerRow:bytesPerRow
                           sourceBytesPerImage:kBufferSize
                                    sourceSize:MTLSizeMake(width, height, 1)
                                     toTexture:tex->tex
                              destinationSlice:0
                              destinationLevel:0
                             destinationOrigin:MTLOriginMake(0, 0, 0)];

            [blitCommandEncoder endEncoding];
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];
        } else {
            [tex->tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
                        mipmapLevel:0
                          withBytes:data
                        bytesPerRow:bytesPerRow];
        }

        if (imageFlags & NVG_IMAGE_GENERATE_MIPMAPS) {
            id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
            id<MTLBlitCommandEncoder> encoder = [commandBuffer blitCommandEncoder];
            [encoder generateMipmapsForTexture:tex->tex];
            [encoder endEncoding];
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];
        }
    }

    MTLSamplerDescriptor* samplerDescriptor = [MTLSamplerDescriptor new];
    if (imageFlags & NVG_IMAGE_NEAREST) {
        samplerDescriptor.minFilter = MTLSamplerMinMagFilterNearest;
        samplerDescriptor.magFilter = MTLSamplerMinMagFilterNearest;
        if (imageFlags & NVG_IMAGE_GENERATE_MIPMAPS)
            samplerDescriptor.mipFilter = MTLSamplerMipFilterNearest;
    } else {
        samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
        samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
        if (imageFlags & NVG_IMAGE_GENERATE_MIPMAPS)
            samplerDescriptor.mipFilter = MTLSamplerMipFilterLinear;
    }

    if (imageFlags & NVG_IMAGE_REPEATX) {
        samplerDescriptor.sAddressMode = MTLSamplerAddressModeRepeat;
    } else {
        samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    }

    if (imageFlags & NVG_IMAGE_REPEATY) {
        samplerDescriptor.tAddressMode = MTLSamplerAddressModeRepeat;
    } else {
        samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    }

    tex->sampler = [_metalLayer.device
                    newSamplerStateWithDescriptor:samplerDescriptor];

    return tex->id;
}

- (void)renderDelete {

    [self renderCancel];

    for (MNVGbuffers* buffers in _cbuffers) {
        buffers.commandBuffer = nil;
        buffers.viewSizeBuffer = nil;
        buffers.stencilTexture = nil;
        buffers.indexBuffer = nil;
        buffers.vertBuffer = nil;
        buffers.uniformBuffer = nil;
        free(buffers.renderData->calls);
    }

    for (MNVGtexture* texture in _textures) {
        texture->tex = nil;
        texture->sampler = nil;
    }

    free(_blendFunc);
    _commandQueue = nil;
    _renderEncoder = nil;
    _textures = nil;
    _cbuffers = nil;
    _defaultStencilState = nil;
    _fillShapeStencilState = nil;
    _fillAntiAliasStencilState = nil;
    _strokeShapeStencilState = nil;
    _strokeAntiAliasStencilState = nil;
    _strokeClearStencilState = nil;
    _fragmentFunction = nil;
    _vertexFunction = nil;
    _pipelineState = nil;
    _stencilOnlyPipelineState = nil;
    _pseudoTexture = nil;
    _vertexDescriptor = nil;
    _metalLayer.device = nil;
    _metalLayer = nil;
}

- (int)renderDeleteTexture:(int)image {
    if(image <= 0) return 0;
    MNVGtexture* texture = _textures[image-1];
    if(texture == nil) return 0;

    if (texture->tex != nil &&
        (texture->flags & NVG_IMAGE_NODELETE) == 0) {
        texture->tex = nil;
        texture->sampler = nil;
    }
    texture->valid = 0;
    texture->flags = 0;
    return 1;
}

- (void)renderFillWithPaint:(NVGpaint*)paint
         compositeOperation:(NVGcompositeOperationState)compositeOperation
                    scissor:(NVGscissor*)scissor
                     fringe:(float)fringe
                     bounds:(const float*)bounds
                      paths:(const NVGpath*)paths
                     npaths:(int)npaths {
    MNVGcall* call = [self allocCall];
    if (call == NULL) return;

    NVGvertex* quad;
    MNVGrenderData* renderData = _buffers.renderData;

    call->type = MNVG_FILL;
    call->triangleCount = 4;
    call->image = paint->image;
    call->blendFunc = [self blendCompositeOperation:compositeOperation];

    if (npaths == 1 && paths[0].convex) {
        call->type = MNVG_CONVEXFILL;
        call->triangleCount = 0;  // Bounding box fill quad not needed for convex fill
    }

    // Allocate vertices for all the paths.
    int indexCount, strokeCount = 0;
    int maxverts = nvg__maxVertCount(paths, npaths, &indexCount, &strokeCount)
    + call->triangleCount;
    int vertOffset = [self allocVerts:maxverts];
    if (vertOffset == -1) goto error;

    int indexOffset = [self allocIndexes:indexCount];
    if (indexOffset == -1) goto error;
    call->indexOffset = indexOffset;
    call->indexCount = indexCount;
    uint32_t* index = &renderData->indexes[indexOffset];

    int strokeVertOffset = vertOffset + (maxverts - strokeCount);
    call->strokeOffset = strokeVertOffset + 1;
    call->strokeCount = strokeCount - 2;
    NVGvertex* strokeVert = renderData->verts + strokeVertOffset;

    NVGpath* path = (NVGpath*)&paths[0];
    for (int i = npaths; i--; ++path) {
        if (path->nfill > 2) {
            memcpy(&renderData->verts[vertOffset], path->fill,
                   sizeof(NVGvertex) * path->nfill);

            int hubVertOffset = vertOffset++;
            for (int j = 2; j < path->nfill; j++) {
                *index++ = hubVertOffset;
                *index++ = vertOffset++;
                *index++ = vertOffset;
            }
            vertOffset++;
        }
        if (path->nstroke > 0) {
            *(strokeVert++) = *path->stroke;
            memcpy(strokeVert, path->stroke, sizeof(NVGvertex) * path->nstroke);
            strokeVert += path->nstroke;
            *(strokeVert++) = path->stroke[path->nstroke - 1];
        }
    }

    // Setup uniforms for draw calls
    if (call->type == MNVG_FILL) {
        // Quad
        call->triangleOffset = vertOffset;
        quad = &renderData->verts[call->triangleOffset];
        nvg__vset(&quad[0], bounds[2], bounds[3], 0.5f, 1.0f);
        nvg__vset(&quad[1], bounds[2], bounds[1], 0.5f, 1.0f);
        nvg__vset(&quad[2], bounds[0], bounds[3], 0.5f, 1.0f);
        nvg__vset(&quad[3], bounds[0], bounds[1], 0.5f, 1.0f);
    }

    // Fill shader
    call->uniformOffset = [self allocFragUniforms:1];
    if (call->uniformOffset == -1) goto error;
    [self convertPaintForFrag:[self fragUniformAtIndex:call->uniformOffset]
                        paint:paint
                      scissor:scissor
                        width:fringe
                       fringe:fringe
                    lineStyle:NVG_LINE_SOLID
                   lineLength:0.0f
                 lineReversed:0];
    return;

error:
    // We get here if call alloc was ok, but something else is not.
    // Roll back the last call to prevent drawing it.
    if (renderData->ncalls > 0) renderData->ncalls--;
}

- (void)renderFlush:(MTLScissorRect)scissorRect {
    // Cancelled if the drawable is invisible.
    if (_viewPortSize.x == 0 || _viewPortSize.y == 0) {
        [self renderCancel];
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLTexture> colorTexture = nil;
    vector_uint2 textureSize;
    _buffers.commandBuffer = commandBuffer;
    __block MNVGbuffers* buffers = _buffers;
    __weak MNVGcontext* weakSelf = self;
    __weak MNVGbuffers* weakBuffers = buffers;

    [commandBuffer enqueue];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        if(weakBuffers) {
            MNVGrenderData* renderData = [weakBuffers renderData];
            renderData->image = 0;
            renderData->nindexes = 0;
            renderData->nverts = 0;
            renderData->ncalls = 0;
            renderData->nuniforms = 0;
            [weakBuffers setIsBusy:NO];
            [weakBuffers setCommandBuffer:nil];
        }
        if(weakSelf) {
            dispatch_semaphore_signal([weakSelf semaphore]);
        }
    }];

    MNVGrenderData* renderData = _buffers.renderData;
    if (s_framebuffer == NULL ||
        MNVG_GET_CONTEXT(s_framebuffer->ctx) != (__bridge void*)self) {
        textureSize = _viewPortSize;
    } else {  // renders in framebuffer
        renderData->image = s_framebuffer->image;
        MNVGtexture* tex = [self findTexture:s_framebuffer->image];
        colorTexture = tex->tex;
        textureSize = (vector_uint2){(uint)colorTexture.width,
            (uint)colorTexture.height};
    }
    if (textureSize.x == 0 || textureSize.y == 0) return;
    [self updateStencilTextureToSize:&textureSize];

    id<CAMetalDrawable> drawable = nil;
    if (colorTexture == nil) {
        drawable = _metalLayer.nextDrawable;
        colorTexture = drawable.texture;
    }
    
    scissorRect.x = MAX(0, scissorRect.x);
    scissorRect.y = MAX(0, scissorRect.y);
    scissorRect.width = MIN(textureSize.x, scissorRect.width);
    scissorRect.height = MIN(textureSize.y, scissorRect.height);

    _renderEncoder = [self renderCommandEncoderWithColorTexture:colorTexture];
    [_renderEncoder setScissorRect: scissorRect];
    
    [self updateRenderPipelineStatesForBlend:_blendFunc
                                 pixelFormat:colorTexture.pixelFormat];
    if(_pipelineState != nil) [_renderEncoder setRenderPipelineState:_pipelineState];
    if (_renderEncoder == nil) return;
    _lastUniformOffset = 0;


    MNVGcall* call = &renderData->calls[0];
    for (int i = renderData->ncalls; i--; ++call) {
        MNVGblend* blend = &call->blendFunc;
        [self updateRenderPipelineStatesForBlend:blend
                                     pixelFormat:colorTexture.pixelFormat];
        if (call->type == MNVG_FILL)
            [self fill:call];
        else if (call->type == MNVG_CONVEXFILL)
            [self convexFill:call];
        else if (call->type == MNVG_STROKE)
            [self stroke:call];
        else if (call->type == MNVG_TRIANGLES)
            [self triangles:call];
    }

    [_renderEncoder endEncoding];
    _renderEncoder = nil;

    if (drawable && !_metalLayer.presentsWithTransaction) {
        [_buffers.commandBuffer presentDrawable:drawable];
    }

    [_buffers.commandBuffer commit];

    if (drawable && _metalLayer.presentsWithTransaction) {
        [_buffers.commandBuffer waitUntilScheduled];
        [drawable present];
    }
    
    _lastBoundTexture = -1;
}

- (int)renderGetTextureSizeForImage:(int)image
                              width:(int*)width
                             height:(int*)height {
    MNVGtexture* tex = [self findTexture:image];
    if (tex == nil) return 0;
    *width = (int)tex->tex.width;
    *height = (int)tex->tex.height;
    return 1;
}

- (void)blitTextureToScreen:(MNVGtexture *)mnvgTexture
{
    // Create a blit command encoder
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];

    id<CAMetalDrawable> drawable = nil;
    drawable = _metalLayer.nextDrawable;
    
    // Get the texture from the drawable (the screen or render target)
    id<MTLTexture> drawableTexture = drawable.texture;

    // Blit the texture onto the drawable texture
    [blitEncoder copyFromTexture:mnvgTexture->tex
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(mnvgTexture->tex.width, mnvgTexture->tex.height, 1)
                       toTexture:drawableTexture
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(0, 0, 0)];

    // End encoding
    [blitEncoder endEncoding];
    
    if (drawable && _metalLayer.presentsWithTransaction) {
        [commandBuffer commit];
        [commandBuffer waitUntilScheduled];
        [drawable present];
    }
    else if(drawable) {
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
}


- (void)renderStrokeWithPaint:(NVGpaint*)paint
           compositeOperation:(NVGcompositeOperationState)compositeOperation
                      scissor:(NVGscissor*)scissor
                       fringe:(float)fringe
                  strokeWidth:(float)strokeWidth
                    lineStyle: (int)lineStyle
                   lineLength: (float)lineLength
                        paths:(const NVGpath*)paths
                       npaths:(int)npaths
{
    MNVGcall* call = [self allocCall];

    if (call == NULL) return;

    MNVGrenderData* renderData = _buffers.renderData;
    call->type = MNVG_STROKE;
    call->image = paint->image;
    call->blendFunc = [self blendCompositeOperation:compositeOperation];

    // Allocate vertices for all the paths.
    int strokeCount = 0;
    int maxverts = nvg__maxVertCount(paths, npaths, NULL, &strokeCount);
    int offset = [self allocVerts:maxverts];
    if (offset == -1) goto error;

    call->strokeOffset = offset + 1;
    call->strokeCount = strokeCount - 2;
    NVGvertex* strokeVert = renderData->verts + offset;

    NVGpath* path = (NVGpath*)&paths[0];
    int lineReversed = 0;
    for (int i = npaths; i--; ++path) {
        if (path->nstroke > 0) {
            lineReversed = path->reversed;
            memcpy(strokeVert, path->stroke, sizeof(NVGvertex));
            ++strokeVert;
            memcpy(strokeVert, path->stroke, sizeof(NVGvertex) * path->nstroke);
            strokeVert += path->nstroke;
            memcpy(strokeVert, path->stroke + path->nstroke - 1, sizeof(NVGvertex));
            ++strokeVert;
        }
    }

    // Fill shader
    call->uniformOffset = [self allocFragUniforms:1];
    if (call->uniformOffset == -1) goto error;
    [self convertPaintForFrag:[self fragUniformAtIndex:call->uniformOffset]
                        paint:paint
                      scissor:scissor
                        width:strokeWidth
                       fringe:fringe
                    lineStyle:lineStyle
                   lineLength:lineLength
                 lineReversed:lineReversed];

    return;

error:
    // We get here if call alloc was ok, but something else is not.
    // Roll back the last call to prevent drawing it.
    if (renderData->ncalls > 0) renderData->ncalls--;
}

- (void)renderTrianglesWithPaint:(NVGpaint*) paint
              compositeOperation:(NVGcompositeOperationState)compositeOperation
                         scissor:(NVGscissor*)scissor
                           verts:(const NVGvertex*)verts
                          nverts:(int)nverts
                          fringe:(float)fringe
                            text:(int)text {
    MNVGcall* call = [self allocCall];
    MNVGfragUniforms* frag;

    if (call == NULL) return;

    MNVGrenderData* renderData = _buffers.renderData;
    call->type = MNVG_TRIANGLES;
    call->image = paint->image;
    call->blendFunc = [self blendCompositeOperation:compositeOperation];

    // Allocate vertices for all the paths.
    call->triangleOffset = [self allocVerts:nverts];
    if (call->triangleOffset == -1) goto error;
    call->triangleCount = nverts;

    memcpy(&renderData->verts[call->triangleOffset], verts,
           sizeof(NVGvertex) * nverts);

    // Fill shader
    call->uniformOffset = [self allocFragUniforms:1];
    if (call->uniformOffset == -1) goto error;
    frag = [self fragUniformAtIndex:call->uniformOffset];
    [self convertPaintForFrag:frag
                        paint:paint
                      scissor:scissor
                        width:1.0f
                       fringe:fringe
                    lineStyle:NVG_LINE_SOLID
                   lineLength:0.0f
                 lineReversed:0];

    if(text) {
        frag->type = PAINT_TYPE_IMG;
        frag->stateData = nvg__packStateDataUniform(PACK_TEX_TYPE, 2);
    }

    return;

error:
    // We get here if call alloc was ok, but something else is not.
    // Roll back the last call to prevent drawing it.
    if (renderData->ncalls > 0) renderData->ncalls--;
}

- (int)renderUpdateTextureWithImage:(int)image
                                  x:(int)x
                                  y:(int)y
                              width:(int)width
                             height:(int)height
                               data:(const unsigned char*)data {
    MNVGtexture* tex = [self findTexture:image];

    if (tex == nil) return 0;

    unsigned char* bytes;
    NSUInteger bytesPerRow;
    if (tex->type == NVG_TEXTURE_RGBA || tex->type == NVG_TEXTURE_ARGB) {
        bytesPerRow = tex->tex.width * 4;
        bytes = (unsigned char*)data + y * bytesPerRow + x * 4;
    } else {
        bytesPerRow = tex->tex.width;
        bytes = (unsigned char*)data + y * bytesPerRow + x;
    }

#if TARGET_OS_SIMULATOR
    const NSUInteger kBufferSize = bytesPerRow * height;
    id<MTLBuffer> buffer = [_metalLayer.device
                            newBufferWithLength:kBufferSize
                            options:MTLResourceStorageModeShared];
    memcpy([buffer contents], bytes, kBufferSize);

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blitCommandEncoder = [commandBuffer
                                                    blitCommandEncoder];
    [blitCommandEncoder copyFromBuffer:buffer
                          sourceOffset:0
                     sourceBytesPerRow:bytesPerRow
                   sourceBytesPerImage:kBufferSize
                            sourceSize:MTLSizeMake(width, height, 1)
                             toTexture:tex->tex
                      destinationSlice:0
                      destinationLevel:0
                     destinationOrigin:MTLOriginMake(x, y, 0)];

    [blitCommandEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
#else
    id<MTLTexture> texture = tex->tex;
    [texture replaceRegion:MTLRegionMake2D(x, y, width, height)
               mipmapLevel:0
                 withBytes:bytes
               bytesPerRow:bytesPerRow];
#endif

    return 1;
}

- (void)renderViewportWithWidth:(float)width
                         height:(float)height
               devicePixelRatio:(float)devicePixelRatio {
    _viewPortSize = (vector_uint2){width * devicePixelRatio,
        height * devicePixelRatio};

    dispatch_semaphore_wait(_semaphore, DISPATCH_TIME_FOREVER);
    for (MNVGbuffers* buffers in _cbuffers) {
        if (!buffers.isBusy) {
            buffers.isBusy = YES;
            _buffers = buffers;
            break;
        }
    }

    // Initializes view size buffer for vertex function.
    if (_buffers.viewSizeBuffer == nil) {
        _buffers.viewSizeBuffer = [_metalLayer.device
                                   newBufferWithLength:sizeof(vector_float2)
                                   options:kMetalBufferOptions];
    }
    float* viewSize = (float*)[_buffers.viewSizeBuffer contents];
    viewSize[0] = width;
    viewSize[1] = height;
}

- (void)setUniforms:(int)uniformOffset image:(int)image {
    if(_lastUniformOffset != uniformOffset) {
        [_renderEncoder setFragmentBufferOffset:uniformOffset atIndex:0];
        _lastUniformOffset = uniformOffset;
    }

    if ( _lastBoundTexture != image) {
        MNVGtexture* tex = image ? [self findTexture:image] : nil;
        [_renderEncoder setFragmentTexture:(tex != nil ? tex->tex : _pseudoTexture) atIndex:0];
        [_renderEncoder setFragmentSamplerState:(tex != nil ? tex->sampler : _pseudoSampler) atIndex:0];
        _lastBoundTexture = image;
    }
}

- (void)stroke:(MNVGcall*)call {
    if (call->strokeCount <= 0) {
        return;
    }

    // Draws strokes.
    [self setUniforms:call->uniformOffset image:call->image];
    [_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:call->strokeOffset
                       vertexCount:call->strokeCount];
}

- (void)triangles:(MNVGcall*)call {
    [self setUniforms:call->uniformOffset image:call->image];
    [_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                       vertexStart:call->triangleOffset
                       vertexCount:call->triangleCount];
}

- (void)updateRenderPipelineStatesForBlend:(MNVGblend*)blend
                               pixelFormat:(MTLPixelFormat)pixelFormat
{
    if (_pipelineState != nil &&
        _stencilOnlyPipelineState != nil &&
        _piplelinePixelFormat == pixelFormat &&
        _blendFunc->srcRGB == blend->srcRGB &&
        _blendFunc->dstRGB == blend->dstRGB &&
        _blendFunc->srcAlpha == blend->srcAlpha &&
        _blendFunc->dstAlpha == blend->dstAlpha) {
        return;
    }

    MTLRenderPipelineDescriptor* pipelineStateDescriptor = [MTLRenderPipelineDescriptor new];

    MTLRenderPipelineColorAttachmentDescriptor* colorAttachmentDescriptor = pipelineStateDescriptor.colorAttachments[0];
    colorAttachmentDescriptor.pixelFormat = pixelFormat;
    pipelineStateDescriptor.stencilAttachmentPixelFormat = kStencilFormat;
    pipelineStateDescriptor.fragmentFunction = _fragmentFunction;
    pipelineStateDescriptor.vertexFunction = _vertexFunction;
    pipelineStateDescriptor.vertexDescriptor = _vertexDescriptor;

    // Sets blending states.
    colorAttachmentDescriptor.blendingEnabled = YES;
    colorAttachmentDescriptor.sourceRGBBlendFactor = blend->srcRGB;
    colorAttachmentDescriptor.sourceAlphaBlendFactor = blend->srcAlpha;
    colorAttachmentDescriptor.destinationRGBBlendFactor = blend->dstRGB;
    colorAttachmentDescriptor.destinationAlphaBlendFactor = blend->dstAlpha;
    _blendFunc->srcRGB = blend->srcRGB;
    _blendFunc->dstRGB = blend->dstRGB;
    _blendFunc->srcAlpha = blend->srcAlpha;
    _blendFunc->dstAlpha = blend->dstAlpha;

    NSError* error;
    _pipelineState = [_metalLayer.device
                      newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                      error:&error];
    [self checkError:error withMessage:"init pipeline state"];

    pipelineStateDescriptor.fragmentFunction = nil;
    colorAttachmentDescriptor.writeMask = MTLColorWriteMaskNone;
    _stencilOnlyPipelineState = [_metalLayer.device
                                 newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                 error:&error];
    [self checkError:error withMessage:"init pipeline stencil only state"];

    _piplelinePixelFormat = pixelFormat;
    [_renderEncoder setRenderPipelineState:_pipelineState];
}

// Re-creates stencil texture whenever the specified size is bigger.
- (void)updateStencilTextureToSize:(vector_uint2*)size {
    if (_buffers.stencilTexture != nil &&
        (_buffers.stencilTexture.width < size->x ||
         _buffers.stencilTexture.height < size->y)) {
        _buffers.stencilTexture = nil;
    }
    if (_buffers.stencilTexture == nil) {
        MTLTextureDescriptor* stencilTextureDescriptor = [MTLTextureDescriptor
                                                          texture2DDescriptorWithPixelFormat:kStencilFormat
                                                          width:size->x
                                                          height:size->y
                                                          mipmapped:NO];
        stencilTextureDescriptor.usage = MTLTextureUsageRenderTarget;
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR || TARGET_OS_MACCATALYST
        stencilTextureDescriptor.storageMode = MTLStorageModePrivate;
#endif  // TARGET_OS_OSX || TARGET_OS_SIMULATOR || TARGET_OS_MACCATALYST
        _buffers.stencilTexture = [_metalLayer.device
                                   newTextureWithDescriptor:stencilTextureDescriptor];
    }
}

@end

@implementation MNVGtexture
@end
