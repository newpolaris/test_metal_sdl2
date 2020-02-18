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
    packed_float2 position;
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
    data.clipSpacePosition = float4(vertexArray[vID].position, 0, 1);
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
    [objcSource release];
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
    if (_stage != nullptr) {
        buffer_pool::release_buffer(_stage);
    }
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

class BufferDescriptor
{
public:
    
    using Callback = void(*)(void* buffer, size_t size, void* user);
    
    BufferDescriptor() noexcept = default;
    
    ~BufferDescriptor() noexcept {
        if (callback) {
            callback(buffer, size, user);
        }
    }
    
    BufferDescriptor(const BufferDescriptor& rhs) = default;
    BufferDescriptor& operator=(const BufferDescriptor& rhs) = delete;
    
    BufferDescriptor(BufferDescriptor&& rhs) noexcept
    : buffer(rhs.buffer), size(rhs.size), callback(rhs.callback), user(rhs.user) {
        rhs.buffer = nullptr;
        rhs.callback = nullptr;
    }
    
    BufferDescriptor& operator=(BufferDescriptor&& rhs) noexcept {
         if (this != &rhs) {
             buffer = rhs.buffer;
             size = rhs.size;
             callback = rhs.callback;
             user = rhs.user;
             rhs.buffer = nullptr;
             rhs.callback = nullptr;
         }
         return *this;
     }


     BufferDescriptor(void const* buffer, size_t size,
             Callback callback = nullptr, void* user = nullptr) noexcept
                 : buffer(const_cast<void*>(buffer)), size(size), callback(callback), user(user) {
     }

    void setCallback(Callback callback, void* user = nullptr) noexcept {
        this->callback = callback;
        this->user = user;
    }

    //! Returns whether a release callback is set
    bool hasCallback() const noexcept { return callback != nullptr; }

    //! Returns the currently set release callback function
    Callback getCallback() const noexcept {
        return callback;
    }

    //! Returns the user opaque pointer associated to this BufferDescriptor
    void* getUser() const noexcept {
        return user;
    }

    //! CPU mempry-buffer virtual address
    void* buffer = nullptr;

    //! CPU memory-buffer size in bytes
    size_t size = 0;

private:
    // callback when the buffer is consumed.
    Callback callback = nullptr;
    void* user = nullptr;
};

class VertexBuffer
{
public:
    
};

std::mutex mPurgeLock;
std::vector<BufferDescriptor> mBufferToPurge;

void scheduleDestroySlow(BufferDescriptor&& buffer) noexcept {
    std::lock_guard<std::mutex> lock(mPurgeLock);
    mBufferToPurge.push_back(std::move(buffer));
}

void purge() noexcept {
    std::vector<BufferDescriptor> buffersToPurge;
    
    std::unique_lock<std::mutex> lock(mPurgeLock);
    std::swap(buffersToPurge, mBufferToPurge);
}

void scheduleDestroy(BufferDescriptor&& buffer) noexcept
{
    if (buffer.hasCallback()) {
        scheduleDestroySlow(std::move(buffer));
    }
}

void setBuffer(BufferDescriptor&& buffer)
{
    scheduleDestroy(std::move(buffer));
}

void populate_vertex_data(void* data, size_t size_in_bytes)
{
    void* vertex_data = malloc(size_in_bytes);
    memcpy(vertex_data, data, size_in_bytes);
    
    setBuffer(BufferDescriptor(vertex_data, size_in_bytes,
                     [](void* buffer, size_t size, void* user) {
        free(buffer);
    }, /* user = */ nullptr));
}

namespace {
    const int max_frac = 10000;
    int num_frac = 10000;
}

template <typename StateType>
struct StateTracker
{
    void invalidate() noexcept { mStateDirty = true; }

    void updateState(const StateType& newState) noexcept {
        if (mCurrentState != newState) {
            mCurrentState = newState;
            mStateDirty = true;
        }
    }
    
    bool stateChanged() noexcept {
        bool ret = mStateDirty;
        mStateDirty = false;
        return ret;
    }
    
    const StateType& getState() const {
        return mCurrentState;
    }
    
    bool mStateDirty = true;
    StateType mCurrentState = {};
};

struct PipelineState {
    id<MTLFunction> vertexFunction = nil;
    id<MTLFunction> fragmentFunction = nil;
    
    bool operator==(const PipelineState& rhs) const noexcept {
        return vertexFunction == rhs.vertexFunction
            && fragmentFunction == rhs.fragmentFunction;
    }
    
    bool operator!=(const PipelineState& rhs) const noexcept {
        return !operator==(rhs);
    }
};

using CullModeStateTracker = StateTracker<MTLCullMode>;
using PipelineStateTracker = StateTracker<PipelineState>;

struct DepthStencilState {
    MTLCompareFunction compareFunction = MTLCompareFunctionNever;
    bool depthWriteEnabled = false;
};

namespace {
    id<MTLRenderCommandEncoder> encoder;
    id<MTLDevice> gpu;
    CAMetalLayer * swapchain;
    id<MTLCommandBuffer> command_buffer;
    id<MTLCommandQueue> command_queue;
    id<MTLTexture> texture;
    id<MTLFunction> vertexFunction;
    id<MTLFunction> fragmentFunction;
    id<MTLRenderPipelineState> pipeline_state;

    CullModeStateTracker cullModeState;
    PipelineStateTracker pipelineState;
}

struct Vertex {
    float position[2];
    float coord[2];
};

static const uint32_t kInFlightCommandBuffers = 3;
dispatch_semaphore_t m_InflightSemaphore = dispatch_semaphore_create(kInFlightCommandBuffers);

void render_background_texture()
{
    dispatch_semaphore_wait(m_InflightSemaphore, DISPATCH_TIME_FOREVER);

    pipelineState.invalidate();
    cullModeState.invalidate();
    
    Vertex fulltriangle[] = {
        { {-1, -1}, {0, 0} },
        { { 3, -1}, {2, 0} },
        { {-1,  3}, {0, 2} },
    };

    id<MTLCommandBuffer> command_buffer = [command_queue commandBuffer];

    [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> command) {
        m_resource_tracker.clear_resouce(command);
    }];
    
    MTLClearColor color = MTLClearColorMake(0, 0, 0, 1);
    id<CAMetalDrawable> surface = [swapchain nextDrawable];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].clearColor = color;
    pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].texture = surface.texture;

    encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];

    std::vector<char> vertices(num_frac*sizeof(float)*24);
    auto* data = vertices.data();
    for (int i = 0; i < num_frac; ++i)
    {
        float sx = -1.f + 2.f / num_frac * i;
        float ex = -1.f + 2.f / num_frac * (i + 1);
        float tsx = 0.f + 1.f / num_frac * i;
        float tex = 0.f + 1.f / num_frac * (i + 1);

        float subvertex[] = {
           sx, -1.0, tsx, 0.0,
           ex, -1.0, tex, 0.0,
           sx, 1.0, tsx, 1.0,

           sx, 1.0, tsx, 1.0,
           ex, -1.0, tex, 0.0,
           ex, 1.0, tex, 1.0,
        };
        memcpy(data + i * sizeof(float)*24, subvertex, sizeof(subvertex));
    }
    
    size_t size = vertices.size();
    metal_buffer vertex_buffer(gpu, size);
    vertex_buffer.copy_into_buffer(data, size);
    id<MTLBuffer> gpu_buffer = vertex_buffer.get_gpu_buffer(command_buffer);
    [encoder setVertexBuffer:gpu_buffer offset:0 atIndex:0];

    NSError *error;

    
    for (int i = 0; i < num_frac; i++) {
        PipelineState pipelineState {
            .vertexFunction = vertexFunction,
            .fragmentFunction = fragmentFunction,
        };
        ::pipelineState.updateState(pipelineState);
        if (::pipelineState.stateChanged()) {
            MTLRenderPipelineDescriptor *pipelineDesc = [MTLRenderPipelineDescriptor new];
            pipelineDesc.vertexFunction = vertexFunction;
            pipelineDesc.fragmentFunction = fragmentFunction;
            pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pipeline_state = [gpu newRenderPipelineStateWithDescriptor:pipelineDesc
                                                                        error:&error];

            [encoder setRenderPipelineState:pipeline_state];
        }
       
        [encoder setFragmentTexture:texture atIndex:0];
        
        MTLCullMode cullMode = MTLCullModeNone;
        cullModeState.updateState(cullMode);
        if (cullModeState.stateChanged()) {
            [encoder setCullMode:cullMode];
        }
        
        [encoder setVertexBuffer:gpu_buffer offset:i*24*sizeof(float) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }
    
    [encoder endEncoding];
    
    [command_buffer presentDrawable:surface];

    // dispatch the command buffer
    __block dispatch_semaphore_t dispatchSemaphore = m_InflightSemaphore;

    [command_buffer addCompletedHandler:^(id <MTLCommandBuffer> cmdb) {
        dispatch_semaphore_signal(dispatchSemaphore);
    }];
    [command_buffer commit];
    
    // while flushCommandBuffer (main thread)
    purge();
    // and execute commandQueue.flush();

    // endFrame - second thread
    buffer_pool::gc();
}

int main(int argc, char *args[])
{
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
    SDL_InitSubSystem(SDL_INIT_VIDEO);
    SDL_Window *window = SDL_CreateWindow("SDL Metal", -1, -1, 1280, 960, SDL_WINDOW_ALLOW_HIGHDPI);
    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    swapchain = (__bridge CAMetalLayer *)SDL_RenderGetMetalLayer(renderer);
    
    gpu = swapchain.device;
    command_queue = [gpu newCommandQueue];
    SDL_DestroyRenderer(renderer);
    
    NSError* error = nil;
    
    vertexFunction = createFunction(gpu, vertex_shader_src);
    fragmentFunction = createFunction(gpu, fragment_shader_src);

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
    
    texture = [gpu newTextureWithDescriptor:texDesc];
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:bytesPerRow];


    bool quit = false;
    SDL_Event e;

    while (!quit) {
        while (SDL_PollEvent(&e) != 0) {
            switch (e.type) {
                case SDL_QUIT: quit = true; break;
            }
        }
        
        @autoreleasepool {
            render_background_texture();
        }
    }
    
    terminate(command_queue);
    
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
