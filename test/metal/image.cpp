#include "image.h"
#include "stb_image.h"
#include <string>

namespace el {

    
uint32_t getBytesPerPixel(PixelFormat format)
{
    switch (format)
    {
    case PixelFormat::PixelFormatR8Unorm:
    case PixelFormat::PixelFormatA8Unorm:
        return 1;
    case PixelFormat::PixelFormatRGB8Unorm:
        return 3;
    case PixelFormat::PixelFormatRGBA8Unorm:
        return 4;
    }
    return 0;
}

ImageDataPtr ImageData::load_memory(const char* bytes, int len)
{
    stbi_set_flip_vertically_on_load(true);

    int width = 0, height = 0, components = 0;
    
    auto imagedata = (char*)stbi_load_from_memory((const stbi_uc*)bytes, len, &width, &height, &components, 4);

    if (!imagedata) return nullptr;

    components = 4;
    
    // 1-byte aligment image
    const size_t length = width * height * components;

    PixelFormat format = PixelFormat::PixelFormatInvalid;
    switch (components)
    {
    case 1: format = PixelFormat::PixelFormatR8Unorm; break;
    case 2: format = PixelFormat::PixelFormatRG8Unorm; break;
    case 3: format = PixelFormat::PixelFormatRGB8Unorm; break;
    case 4: format = PixelFormat::PixelFormatRGBA8Unorm; break;
    }

    auto container = std::make_shared<ImageData>();
    container->format = format;
    container->stream = std::vector<char>(imagedata, imagedata + length);
    container->width = (int32_t)width;
    container->height = (int32_t)height;

    stbi_image_free(imagedata);

    return container;
}

ImageDataPtr ImageData::load(const std::string& filename)
{
    stbi_set_flip_vertically_on_load(true);

    int width = 0, height = 0, components = 0;
    auto imagedata = (char*)stbi_load(filename.c_str(), &width, &height, &components, 4);
    if (!imagedata) return nullptr;

    components = 4;
    
    // 1-byte aligment image
    const size_t length = width * height * components;

    PixelFormat format = PixelFormat::PixelFormatInvalid;
    switch (components)
    {
    case 1: format = PixelFormat::PixelFormatR8Unorm; break;
    case 2: format = PixelFormat::PixelFormatRG8Unorm; break;
    case 3: format = PixelFormat::PixelFormatRGB8Unorm; break;
    case 4: format = PixelFormat::PixelFormatRGBA8Unorm; break;
    }

    auto container = std::make_shared<ImageData>();
    container->format = format;
    container->stream = std::vector<char>(imagedata, imagedata + length);
    container->width = (int32_t)width;
    container->height = (int32_t)height;

    stbi_image_free(imagedata);

    return container;
}

uint32_t ImageData::getBytesPerRow() const
{
    return width * getBytesPerPixel(format);
}
    
} // namespace el
