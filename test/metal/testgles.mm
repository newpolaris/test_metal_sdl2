/*
  Copyright (C) 1997-2019 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely.
*/
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <map>
#include <unordered_set>
#include <mutex>
#include <set>
#include <functional>

#include "image.h"

#include "SDL_test_common.h"

#if defined(__IPHONEOS__) || defined(__ANDROID__)
#define HAVE_OPENGLES
#endif

#include "resources.h"

//
// cc sdl-metal-example.m -framework SDL2 -framework Metal -framework QuartzCore
//
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

const char vertex_shader_src[] = R"""(
#include <metal_stdlib>
using namespace metal;

typedef struct
{
    packed_float4 position;
    packed_float2 texcoord;
} vertex_t;

typedef struct
{
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;

vertex RasterizerData main0(
                            const device vertex_t* vertexArray [[buffer(0)]],
                            unsigned int vID[[vertex_id]])
{
    RasterizerData data;
    data.clipSpacePosition = vertexArray[vID].position;
    data.textureCoordinate = vertexArray[vID].texcoord;
    return data;
}
)""";
    
const char fragment_shader_src[] = R"""(
#include <metal_stdlib>
using namespace metal;

typedef struct
{
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;

fragment half4 main0(
                     RasterizerData in [[stage_in]],
                     texture2d<half> colorTexture [[texture(0)]])
{
    constexpr sampler textureSampler (mag_filter::nearest,
                                      min_filter::nearest);
    // Sample the texture to obtain a color
    const half4 colorSample = colorTexture.sample(textureSampler, in.textureCoordinate);
    
    // We return the color of the texture
    return colorSample;
}
)""";
    

id<MTLFunction> createFunction(id<MTLDevice> gpu, const char* source)
{
    NSString* objcSource = [NSString stringWithCString:source
                                              encoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id<MTLLibrary> library = [gpu newLibraryWithSource:objcSource options:nil error:&error];
    id<MTLFunction> function = [library newFunctionWithName:@"main0"];
    [library release];
    return function;
}
    
#if _WIN32
extern "C" __declspec(dllimport) void __stdcall OutputDebugStringA(const char* _str);
#else
#   if defined(__OBJC__)
#       import <Foundation/NSObjCRuntime.h>
#   else
#       include <CoreFoundation/CFString.h>
        extern "C" void NSLog(CFStringRef _format, ...);
#   endif
#endif

void debug_output(const char* message);
void trace(const char* format, ...);

void trace(const char* format, ...)
{
    const int kLength = 1024;
    char buffer[kLength + 1] = {0,};
    
    va_list argList;
    va_start(argList, format);
    int len = vsnprintf(buffer, kLength, format, argList);
    va_end(argList);
    if (len > kLength)
        len = kLength;
    buffer[len] = '\0';

    debug_output(buffer);
}

void debug_output(const char* message)
{
#if _WIN32
    OutputDebugStringA(message);
#else
#   if defined(__OBJC__)
    NSLog(@"%s", message);
#   else
    NSLog(CFSTR("%s"), message);
#   endif
#endif
}

// TODO:
// https://developer.apple.com/documentation/metal/copying_data_to_a_private_resource?language=objc

namespace buffer_pool {

    // From filament's buffer managing
    struct stage_t
    {
        id<MTLBuffer> buffer;
        size_t length = 0;
        mutable uint64_t last_accessed = 0;
        mutable int reference_count = 1;
    };

    std::mutex m_mutex;
    const uint64_t time_before_eviction = 10;
    uint64_t m_current_frames = 0;
    std::multimap<size_t, stage_t const*> m_free_stages;
    std::unordered_set<stage_t const*> m_used_stages;

    stage_t const* aquire_buffer(id<MTLDevice> device, size_t num_bytes)
    {
        std::lock_guard<std::mutex> lock(m_mutex);

        auto iter = m_free_stages.lower_bound(num_bytes);
        if (iter != m_free_stages.end())
        {
            auto stage = iter->second;
            m_free_stages.erase(iter);
            m_used_stages.insert(stage);
            stage->reference_count = 1;
            return stage;
        }
        
        id<MTLBuffer> buffer = [device newBufferWithLength:num_bytes options:MTLResourceStorageModeShared];
        stage_t* stage = new stage_t({
            .buffer = buffer,
            .length = num_bytes,
            .last_accessed = m_current_frames,
            .reference_count = 1,
        });
        m_used_stages.insert(stage);
        
        return stage;
    }

    void retain_buffer(stage_t const* stage)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        
        stage->reference_count++;
    }

    void release_buffer(stage_t const* stage)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        
        stage->reference_count--;
        if (stage->reference_count > 0)
            return;
        auto iter = m_used_stages.find(stage);
        assert(iter != m_used_stages.end());
        
        stage->last_accessed = m_current_frames;

        m_used_stages.erase(iter);
        m_free_stages.insert({stage->length, stage});
    }

    void gc()
    {
        std::lock_guard<std::mutex> lock(m_mutex);

        m_current_frames++;
        
        const uint64_t eviction_time = m_current_frames - time_before_eviction;
        decltype(m_free_stages) stages;
        stages.swap(m_free_stages);
        
        for (auto stage : stages)
        {
            if (stage.second->last_accessed < eviction_time) {
                [stage.second->buffer release];
                delete stage.second;
            }
            else
            {
                m_free_stages.insert(stage);
            }
        }
    }

    void reset()
    {
        std::lock_guard<std::mutex> lock(m_mutex);

        assert(m_used_stages.empty());
        for (auto stage : m_free_stages) {
            [stage.second->buffer release];
            delete stage.second;
        }
        m_free_stages.clear();
    }

} // namespace buffer_pool

struct resource_tracker_t
{
    using command_buffer_t = void*;
    using resource_t = const void*;
    using deleter_t = std::function<void(resource_t)>;
    
    bool track_resource(command_buffer_t buffer, resource_t stage, deleter_t deleter);
    void clear_resouce(command_buffer_t buffer);
    
    struct entry_t
    {
        resource_t resource;
        deleter_t deleter;
        
        bool operator<(const entry_t& other) const
        {
            return resource < other.resource;
        }
    };
    
    using resource_set_t = std::set<entry_t>;
    std::map<command_buffer_t, resource_set_t> _resources;
} m_resource_tracker;

bool resource_tracker_t::track_resource(command_buffer_t buffer, resource_t stage, deleter_t deleter)
{
    auto found = _resources.find(buffer);
    if (found == _resources.end())
    {
        resource_set_t& resource_set = _resources[buffer] = {};
        resource_set.insert({ stage, deleter });
        return true;
    }
    
    resource_set_t& resource_set = found->second;
    auto inserted = resource_set.insert({ stage, deleter });
    return inserted.second;
}

void resource_tracker_t::clear_resouce(command_buffer_t buffer)
{
    auto found = _resources.find(buffer);
    if (found == _resources.end()) {
        return;
    }

    for (const auto& resource : found->second) {
        resource.deleter(resource.resource);
    }
    _resources.erase(found);
}

struct metal_buffer final
{
    metal_buffer(id<MTLDevice> device, uint32_t size);
    ~metal_buffer();
    
    void copy_into_buffer(void* src, size_t size);
    id<MTLBuffer> get_gpu_buffer(id<MTLCommandBuffer> command);

    id<MTLDevice> _device = nil;
    buffer_pool::stage_t const* _stage = nullptr;
    uint32_t _size = 0;
};

metal_buffer::metal_buffer(id<MTLDevice> device, uint32_t size) :
    _device(device),
    _size(size)
{
}

metal_buffer::~metal_buffer()
{
    buffer_pool::release_buffer(_stage);
    _stage = nil;
    _device = nil;
}

void metal_buffer::copy_into_buffer(void* src, size_t size)
{
    assert(size <= _size);
    
    // We're about to acquire a new buffer to hold the new contents. If we previously had obtained a
    // buffer we release it, decrementing its reference count, as we no longer needs it.
    if (_stage != nullptr)
        buffer_pool::release_buffer(_stage);

    _stage = buffer_pool::aquire_buffer(_device, size);
    if (_stage != nullptr) {
        void* data = _stage->buffer.contents;
        memcpy(data, src, size);
    }
}

id<MTLBuffer> metal_buffer::get_gpu_buffer(id<MTLCommandBuffer> command)
{
    if (_stage == nullptr) {
        _stage = buffer_pool::aquire_buffer(_device, _size);
    }
    auto deleter = [](const void* resource) {
        auto stage = reinterpret_cast<buffer_pool::stage_t const*>(resource);
        buffer_pool::release_buffer(stage);
    };
    if (m_resource_tracker.track_resource((__bridge void*)command, _stage, deleter)) {
        buffer_pool::retain_buffer(_stage);
    }
    
    return _stage->buffer;
}

void terminate(id<MTLCommandQueue> command_queue)
{
    // Wait for all frames to finish by submitting and waiting on a dummy command buffer.
    // This must be done before calling bufferPool->reset() to ensure no buffers are in flight.
    id<MTLCommandBuffer> oneOffBuffer = [command_queue commandBuffer];
    [oneOffBuffer commit];
    [oneOffBuffer waitUntilCompleted];
    
    buffer_pool::reset();
    [command_queue release];
}

int main(int argc, char *args[])
{
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
    SDL_InitSubSystem(SDL_INIT_VIDEO);
    SDL_Window *window = SDL_CreateWindow("SDL Metal", -1, -1, 640, 480, SDL_WINDOW_ALLOW_HIGHDPI);
    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
    const CAMetalLayer *swapchain = (__bridge CAMetalLayer *)SDL_RenderGetMetalLayer(renderer);
    const id<MTLDevice> gpu = swapchain.device;
    const id<MTLCommandQueue> queue = [gpu newCommandQueue];
    SDL_DestroyRenderer(renderer);

    MTLClearColor color = MTLClearColorMake(0, 0, 0, 1);
    NSError* error = nil;
    
    id<MTLFunction> vertexFunction = createFunction(gpu, vertex_shader_src);
    id<MTLFunction> fragmentFunction = createFunction(gpu, fragment_shader_src);

    MTLRenderPipelineDescriptor *pipelineDesc = [MTLRenderPipelineDescriptor new];
    pipelineDesc.vertexFunction = vertexFunction;
    pipelineDesc.fragmentFunction = fragmentFunction;
    pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline_state = [gpu newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
    
    el::ImageDataPtr miku;
    miku = el::ImageData::load_memory(miku_image_binray, miku_image_len);
    assert(miku != nullptr);
    
    const auto width = miku->width;
    const auto height = miku->height;
    const uint32_t bytesPerRow = miku->getBytesPerRow();
    auto data = miku->data();
    
    MTLTextureDescriptor *texDesc = nil;
    texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                 width:width
                                                                height:height
                                                             mipmapped:NO];
    id<MTLTexture> texture = [gpu newTextureWithDescriptor:texDesc];
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:bytesPerRow];
    
    struct Vertex {
        float position[4];
        float coord[2];
    };
    Vertex fulltriangle[] = {
        { {-1, -1, 0, 1}, {0, 0} },
        { { 3, -1, 0, 1}, {2, 0} },
        { {-1,  3, 0, 1}, {0, 2} },
    };
    
    id<MTLBuffer> vertex_buffer = [gpu newBufferWithBytes:fulltriangle
                                                   length:sizeof(fulltriangle)
                                                  options:MTLResourceOptionCPUCacheModeDefault];
    
    static const uint32_t kInFlightCommandBuffers = 3;

    dispatch_semaphore_t m_InflightSemaphore = dispatch_semaphore_create(kInFlightCommandBuffers);

    bool quit = false;
    SDL_Event e;

    while (!quit) {
        while (SDL_PollEvent(&e) != 0) {
            switch (e.type) {
                case SDL_QUIT: quit = true; break;
            }
        }
        
        @autoreleasepool {
            
#if 0
            void* vbFilamentData = malloc(nVbBytes);
            memcpy(vbFilamentData, vbImguiData, nVbBytes);
            mVertexBuffers[bufferIndex]->setBufferAt(*mEngine, 0,
                    VertexBuffer::BufferDescriptor(vbFilamentData, nVbBytes,
                        [](void* buffer, size_t size, void* user) {
                            free(buffer);
                        }, /* user = */ nullptr));
#endif
            
            dispatch_semaphore_wait(m_InflightSemaphore, DISPATCH_TIME_FOREVER);

            id<MTLCommandBuffer> buffer = [queue commandBuffer];

            [buffer addCompletedHandler:^(id<MTLCommandBuffer> command) {
                m_resource_tracker.clear_resouce(command);
            }];
            
            id<CAMetalDrawable> surface = [swapchain nextDrawable];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].clearColor = color;
            pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].texture = surface.texture;

            size_t size = sizeof(fulltriangle);
            metal_buffer vertex_buffer(gpu, size);
            vertex_buffer.copy_into_buffer(fulltriangle, size);
            id<MTLBuffer> gpu_buffer = vertex_buffer.get_gpu_buffer(buffer);
            id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
            [encoder setRenderPipelineState:pipeline_state];
            [encoder setFragmentTexture:texture atIndex:0];
            [encoder setVertexBuffer:gpu_buffer offset:0 atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];
            [buffer presentDrawable:surface];
            
            // dispatch the command buffer
            __block dispatch_semaphore_t dispatchSemaphore = m_InflightSemaphore;

            [buffer addCompletedHandler:^(id <MTLCommandBuffer> cmdb) {
                dispatch_semaphore_signal(dispatchSemaphore);
            }];
            [buffer commit];
        }
    }
    
    terminate(queue);
    
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
