/*
 * GLVertexBuffer_stubs.cpp — Stub implementations of VertexBufferGL and
 * IndexBufferGL for iOS builds where OpenGL is not available.
 *
 * These classes are referenced by CGO.cpp and CGOGL.cpp even on Metal-only
 * builds. The stubs provide linkable symbols without actual GL calls.
 */

#ifdef _PYMOL_NO_OPENGL

#include "GLVertexBuffer.h"

// VertexBufferGL stubs

VertexBufferGL::VertexBufferGL(VertexBufferLayout layout,
    MemoryUsageProperty property)
    : m_layout(layout), m_memProperty(property) {}

void VertexBufferGL::bind() const {}
void VertexBufferGL::bind(GLuint, int) {}
void VertexBufferGL::unbind() {}
void VertexBufferGL::maskAttributes(std::vector<GLint>) {}
void VertexBufferGL::maskAttribute(GLint) {}

std::vector<std::uint64_t> VertexBufferGL::getBufferIDs() const { return {}; }
std::vector<BufferAndOffsets> VertexBufferGL::getBufferOffsets() const { return {}; }

void VertexBufferGL::copyFrom(const BufferAndOffsets&, pymol::span<const std::byte>) {}

bool VertexBufferGL::bufferData(BufferDataDesc&& desc) {
  // Retain layout/stride for the Metal renderer (mirrors GLVertexBuffer.cpp).
  m_cpuDesc = std::move(desc);
  m_cpuStride = m_cpuDesc.stride.value_or(0);
  return true;
}

bool VertexBufferGL::bufferData(BufferDataDesc&& desc, const void* data, size_t len) {
  // Retain interleaved CPU copy + stride for the Metal renderer
  // (mirrors the CPU-retain path in GLVertexBuffer.cpp:328-345).
  m_layout = VertexBufferLayout::Interleaved;
  m_cpuDesc = std::move(desc);
  m_cpuStride = m_cpuDesc.stride.value_or(0);
  if (data && len > 0) {
    m_cpuData.assign(static_cast<const std::byte*>(data),
                     static_cast<const std::byte*>(data) + len);
  }
  // data_ptrs are not valid after this call
  for (auto& d : m_cpuDesc.descs) {
    d.data_ptr = nullptr;
  }
  return true;
}

void VertexBufferGL::bufferSubData(size_t, size_t, void*, size_t) {}
void VertexBufferGL::bufferReplaceData(std::size_t, pymol::span<const std::byte>) {}

// IndexBufferGL stubs

void IndexBufferGL::bind() const {}
void IndexBufferGL::unbind() {}
GLenum IndexBufferGL::bufferType() const { return 0; }

void IndexBufferGL::copyFrom(pymol::span<const std::uint32_t> data) {
  // Retain CPU copy for Metal renderer
  m_cpuData.assign(
      reinterpret_cast<const std::byte*>(data.data()),
      reinterpret_cast<const std::byte*>(data.data()) + data.size() * sizeof(std::uint32_t));
}

std::uint64_t IndexBufferGL::getBufferID() const { return 0; }

void IndexBufferGL::bufferSubData(std::size_t, pymol::span<const std::byte>) {}

#endif /* _PYMOL_NO_OPENGL */
