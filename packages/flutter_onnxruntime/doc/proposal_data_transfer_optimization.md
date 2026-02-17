# Tensor Data Transfer Optimization

## 1. Problem Statement

Users have reported significant performance issues when retrieving tensor values from the native side (iOS/Android/Linux/Windows) to the Dart side via method channels. This bottleneck particularly impacts real-time inference scenarios where:

- Output tensors need to be processed immediately after inference
- Applications require low latency for responsive user experiences
- Large tensors (e.g., image processing, video frames) are being transferred frequently

The current implementation is efficient during inference (only tensor IDs are passed), but becomes a critical bottleneck when users call `asList()` or `asFlattenedList()` to retrieve the actual tensor data.

## 2. Current Implementation Analysis

### Architecture Overview

The plugin uses a **reference-based architecture**:

1. **Input Creation**: Tensors are created in native memory and assigned unique IDs
2. **Inference**: Only tensor metadata (ID, dataType, shape) is passed through method channels
3. **Output Retrieval**: Actual tensor data is fetched on-demand via `getOrtValueData` method

### Data Flow for Tensor Retrieval

#### Dart Side (`lib/src/ort_value.dart:142-159`)

```dart
Future<List<dynamic>> asList() async {
  final data = await _channel.invokeMethod('getOrtValueData', {'id': id});
  List<dynamic> dataList1d = List<dynamic>.from(data['data']);
  return _reshapeList(dataList1d, shape);
}
```

The Dart code:
- Calls native method `getOrtValueData` with tensor ID
- Receives data as a generic `List<dynamic>`
- Performs additional reshaping operations

#### iOS Implementation (`ios/Classes/FlutterOnnxruntimePlugin.swift:793-848`)

```swift
// Extract tensor data
let dataPtr = try tensor.tensorData()
let floatPtr = dataPtr.bytes.bindMemory(to: Float.self, capacity: elementCount)
let floatBuffer = UnsafeBufferPointer(start: floatPtr, count: elementCount)
data = Array(floatBuffer)  // COPY #1: Native buffer → Swift Array

// Return via method channel
let resultMap: [String: Any] = ["data": data, ...]
result(resultMap)  // COPY #2: Swift Array → Method Channel → Dart List
```

**Memory Copies**: 2 complete copies of tensor data

#### Android Implementation (`android/src/main/kotlin/FlutterOnnxruntimePlugin.kt:1020-1024`)

```kotlin
val floatArray = FloatArray(flatSize)
tensor.floatBuffer.get(floatArray)  // COPY #1: FloatBuffer → FloatArray
val dataList = floatArray.toList()  // COPY #2: FloatArray → Kotlin List

val resultMap = mapOf(
    "data" to dataList,  // COPY #3: Kotlin List → Method Channel → Dart List
    ...
)
result.success(resultMap)
```

**Memory Copies**: 3 complete copies of tensor data

#### Linux/Windows Implementation (`linux/src/tensor_manager.cc:209-218`)

```cpp
float *tensor_data = tensor->GetTensorMutableData<float>();
std::vector<float> data_vec(tensor_data, tensor_data + elem_count);  // COPY #1
FlValue *data_list = vector_to_fl_value(data_vec);  // COPY #2

// Return via method channel → COPY #3 to Dart
```

**Memory Copies**: 3 complete copies of tensor data

### Performance Impact Analysis

For a typical image tensor of size 512×512×3 with float32 values:

- **Tensor size**: 512 × 512 × 3 × 4 bytes = 3,145,728 bytes (~3MB)
- **iOS**: 3MB × 2 copies = **6MB transferred**
- **Android/Linux/Windows**: 3MB × 3 copies = **9MB transferred**

For real-time video processing at 30 FPS:
- **iOS**: 6MB × 30 = 180MB/sec
- **Android/Linux/Windows**: 9MB × 30 = 270MB/sec

This excessive memory copying and bandwidth usage causes:
- High CPU usage for memory allocation and copying
- Increased garbage collection pressure
- UI thread blocking during synchronous data transfer
- Poor performance for latency-sensitive applications

## 3. Root Cause: StandardMethodCodec Serialization Overhead

Flutter's default `StandardMethodCodec` is designed for general-purpose data transfer but is inefficient for large homogeneous arrays.

### How StandardMethodCodec Works

The StandardMethodCodec serializes data using a type-tagged format:

```
[Type Tag][Value][Type Tag][Value][Type Tag][Value]...
```

For a float array `[1.0, 2.0, 3.0]`, the codec:

1. **Writes type tag** for the list container
2. **Writes length** of the list
3. **For each element**:
   - Boxes the primitive (Float → NSNumber on iOS, java.lang.Float on Android)
   - Writes type tag for the number
   - Writes the value

**Example serialization cost for 1 million floats:**

| Operation | Cost per Element | Total Cost |
|-----------|------------------|------------|
| Type tag write | 1 byte | 1 MB |
| Float value write | 4 bytes | 4 MB |
| Boxing overhead | CPU cycles + memory allocation | Significant GC pressure |
| **Total** | **~5 bytes + boxing** | **~5 MB + CPU overhead** |

### Platform-Specific Boxing Overhead

#### iOS (Objective-C/Swift)
```swift
// Each float is boxed into NSNumber
let numbers: [NSNumber] = floatArray.map { NSNumber(value: $0) }
```
- NSNumber allocation per element
- Reference counting overhead
- Autorelease pool pressure

#### Android (Kotlin/Java)
```kotlin
// Each float is boxed into java.lang.Float
val boxedList: List<Float> = floatArray.toList()
```
- Java object allocation per element (16-24 bytes overhead per object)
- Additional memory pressure on heap
- Garbage collection impact

### Memory Layout Comparison

**StandardMethodCodec (Current)**:
```
┌─────────┬─────────┬─────────┬─────────┬─────────┐
│ Type    │ Boxed   │ Type    │ Boxed   │ Type    │
│ Tag(1B) │ Float   │ Tag(1B) │ Float   │ Tag(1B) │
│         │ Object  │         │ Object  │         │
└─────────┴─────────┴─────────┴─────────┴─────────┘
   For each element: ~20-30 bytes (with object overhead)
```

**Binary Transfer (Proposed)**:
```
┌──────────┬──────────┬──────────┬──────────┬──────────┐
│ Float(4B)│ Float(4B)│ Float(4B)│ Float(4B)│ Float(4B)│
└──────────┴──────────┴──────────┴──────────┴──────────┘
   For each element: 4 bytes (raw binary data)
```

**Memory savings: 5-7x reduction in serialized size**

## 4. Proposed Solution: Binary Codec Approach

### Overview

Replace StandardMethodCodec with binary data transfer using:
- **Native → Dart**: `FlutterBinaryCodec` / `BasicMessageChannel`
- **Data format**: Raw byte arrays (`ByteData`/`Uint8List`)
- **Dart side**: TypedData views (zero-copy interpretation)

### Implementation Strategy

#### Step 1: Native Side Changes

**Create dedicated binary channels for tensor data:**

```swift
// iOS
let binaryChannel = FlutterBasicMessageChannel(
    name: "com.masicai.onnxruntime/tensorData",
    binaryMessenger: messenger,
    codec: FlutterBinaryCodec.sharedInstance()
)
```

```kotlin
// Android
val binaryChannel = BasicMessageChannel(
    messenger,
    "com.masicai.onnxruntime/tensorData",
    BinaryCodec.INSTANCE
)
```

#### Step 2: Direct Memory Copy

**iOS Implementation:**
```swift
func handleGetOrtValueData(tensorId: String) -> Data? {
    let tensor = tensorManager.getTensor(id: tensorId)
    let dataPtr = try tensor.tensorData()
    let byteCount = elementCount * MemoryLayout<Float>.size

    // Single copy: Native memory → NSData
    return Data(bytes: dataPtr.bytes, count: byteCount)
}
```

**Memory operations: 1 copy (native ONNX buffer → NSData)**

**Android Implementation:**
```kotlin
fun handleGetOrtValueData(tensorId: String): ByteArray {
    val tensor = tensorManager.getTensor(tensorId)
    val floatBuffer = tensor.floatBuffer
    val byteBuffer = ByteBuffer.allocate(floatBuffer.capacity() * 4)

    // Single copy: FloatBuffer → ByteBuffer
    floatBuffer.rewind()
    byteBuffer.asFloatBuffer().put(floatBuffer)

    return byteBuffer.array()
}
```

**Memory operations: 1 copy (ONNX FloatBuffer → ByteArray)**

#### Step 3: Dart Side Interpretation

```dart
Future<List<dynamic>> asList() async {
  // Fetch binary data
  final Uint8List bytes = await _binaryChannel.send(
    utf8.encode(jsonEncode({'id': id}))
  );

  // Zero-copy view: Uint8List → Float32List
  final Float32List typedData = bytes.buffer.asFloat32List();

  // Reshape and return
  return _reshapeList(typedData, shape);
}
```

**Key optimization**: `bytes.buffer.asFloat32List()` creates a **view** of the same memory, not a copy.

### Data Flow Comparison

**Current Implementation (StandardMethodCodec):**
```
ONNX Tensor → Native Array → Boxed Objects → Encoded Bytes →
  Method Channel → Decoded Objects → Dart List → User Data
    (Copy 1)      (Boxing)         (Serialize)
                                                    (Copy 2)
```

**Proposed Implementation (BinaryCodec):**
```
ONNX Tensor → ByteArray/NSData → Method Channel → Uint8List View → User Data
    (Copy 1)                      (Raw transfer)    (Zero-copy)
```

**Reduction: 2-3 copies → 1 copy**

## 5. Why Binary Codec is Faster: Technical Deep Dive

### 5.1 No Per-Element Overhead

**StandardMethodCodec:**
```
Operation per element:
1. Allocate boxed object (NSNumber/java.lang.Float)     ~20ns
2. Write type tag to buffer                              ~5ns
3. Write value to buffer                                 ~10ns
4. Deallocate boxed object (GC)                         ~10ns
                                                        ------
Total: ~45ns per element

For 1M floats: 45ms overhead (ignoring actual data copy)
```

**BinaryCodec:**
```
Operation for entire array:
1. memcpy(destination, source, byteCount)               ~300µs
                                                        ------
Total: 0.3ms for 1M floats (4MB)

Speed-up: 150x faster than element-wise processing
```

### 5.2 CPU Cache Efficiency

**StandardMethodCodec:**
- Random memory access patterns due to object allocations
- Poor cache locality
- Branch prediction failures from type checking

**BinaryCodec:**
- Sequential memory access (optimal for CPU prefetcher)
- Entire operation fits in L2/L3 cache
- Simple memcpy uses optimized SIMD instructions

### 5.3 Memory Allocator Pressure

**StandardMethodCodec:**
```
For 1M floats on Android:
- Allocates 1M java.lang.Float objects
- Each object: 16 bytes header + 4 bytes value = 20 bytes
- Total heap usage: 20MB (vs 4MB raw data)
- Triggers garbage collection
- GC pause: 50-200ms for 20MB allocation
```

**BinaryCodec:**
```
For 1M floats:
- Allocates 1 contiguous ByteArray
- Total heap usage: 4MB
- No GC pressure (single large allocation)
- GC pause: minimal
```

### 5.4 Dart Side Processing

**StandardMethodCodec Result:**
```dart
List<dynamic> data = [...];  // Untyped list
// Every access requires type checking
double value = data[i] as double;  // Runtime type cast
```

**BinaryCodec Result:**
```dart
Float32List data = bytes.buffer.asFloat32List();
// Direct typed access, no runtime overhead
double value = data[i];  // Direct memory read
```

### Performance Benchmark Estimates

| Tensor Size | Current (ms) | Proposed (ms) | Speed-up |
|-------------|--------------|---------------|----------|
| 224×224×3 (float32, 600KB) | 45ms | 15ms | **3.0x** |
| 512×512×3 (float32, 3MB) | 210ms | 75ms | **2.8x** |
| 1024×1024×3 (float32, 12MB) | 850ms | 300ms | **2.8x** |

*Estimates based on Android device (mid-range processor). iOS may show even better improvements due to more efficient memory management.*

## 6. Implementation Approach

### Phase 1: Add Binary Channel Infrastructure

1. **Create new binary message channels** on each platform
2. **Register channels** during plugin initialization
3. **Implement fallback** to StandardMethodCodec for backward compatibility

### Phase 2: Update Native Implementations

Each platform independently:

1. **iOS** (`ios/Classes/FlutterOnnxruntimePlugin.swift`):
   - Add binary channel handler
   - Modify `handleGetOrtValueData` to return `NSData`
   - Handle endianness for non-float types

2. **Android** (`android/src/main/kotlin/FlutterOnnxruntimePlugin.kt`):
   - Add binary channel handler
   - Modify `getOrtValueData` to return `ByteArray`
   - Use `ByteBuffer.order(ByteOrder.nativeOrder())` for correct endianness

3. **Linux** (`linux/src/tensor_manager.cc`):
   - Create GBytes from raw tensor pointer
   - Return binary FlValue

4. **Windows** (`windows/src/tensor_manager.cc`):
   - Similar to Linux implementation

### Phase 3: Update Dart Implementation

1. **Add binary channel** in `lib/src/ort_value.dart`
2. **Update `asList()` and `asFlattenedList()`**:
   - Use binary channel for data retrieval
   - Convert `Uint8List` to appropriate TypedData view
   - Maintain existing API signature (no breaking changes)

### Phase 4: Testing and Validation

1. **Unit tests** for data integrity across all platforms
2. **Performance benchmarks** comparing old vs new implementation
3. **Integration tests** with various tensor types and sizes
4. **Verify endianness** handling on different architectures

## 7. Risks and Mitigation Strategies

### Risk 1: Endianness Issues

**Description**: Different CPU architectures may use different byte orders (little-endian vs big-endian).

**Impact**: Incorrect interpretation of multi-byte values (floats, ints) could produce garbage data.

**Mitigation**:
- Use platform-native byte order on both sides
- Dart's `ByteData` and native `ByteBuffer` both use native endianness by default
- Add runtime assertions to verify correct data interpretation
- Test on both little-endian (x86, ARM) and big-endian systems (if supported)

**Implementation**:
```dart
// Dart side validation
assert(() {
  final testBytes = Uint8List(4)..buffer.asByteData().setFloat32(0, 1.0);
  final readBack = testBytes.buffer.asByteData().getFloat32(0);
  return (readBack - 1.0).abs() < 0.0001;
}());
```

### Risk 2: Memory Alignment Requirements

**Description**: Some architectures require multi-byte values to be aligned on specific boundaries.

**Impact**: Unaligned memory access could cause crashes or performance degradation.

**Mitigation**:
- ONNX Runtime already provides properly aligned tensor data
- Use platform allocators that guarantee alignment
- Dart TypedData views handle alignment automatically
- Add assertions to verify alignment in debug builds

**Implementation**:
```cpp
// Native side validation
assert(reinterpret_cast<uintptr_t>(tensor_data) % alignof(float) == 0);
```

### Risk 3: Data Type Compatibility

**Description**: ONNX supports many data types (float16, bfloat16, int8, etc.). Not all are natively supported in Dart.

**Impact**: Complex types may still require conversion, reducing performance gains.

**Mitigation**:
- Prioritize common types (float32, int32, int64) for binary transfer
- Keep fallback to StandardMethodCodec for exotic types
- Document supported types clearly
- Add type conversion on Dart side for float16 (2 bytes → float32)

**Supported Types via Binary Transfer**:
| ONNX Type | Dart TypedData | Native Support |
|-----------|----------------|----------------|
| float32 | Float32List | Yes |
| int32 | Int32List | Yes |
| int64 | Int64List | Yes |
| uint8 | Uint8List | Yes |
| int8 | Int8List | Yes |
| float16 | Manual conversion | Requires processing |
| bfloat16 | Manual conversion | Requires processing |

### Risk 4: Error Handling Complexity

**Description**: Binary channels have less built-in error handling than StandardMethodCodec.

**Impact**: Errors may be harder to debug; corrupted data may not be caught.

**Mitigation**:
- Send metadata (size, type, checksum) alongside binary data
- Validate data size matches expected tensor size
- Add magic numbers or version headers to binary protocol
- Implement comprehensive error logging

**Implementation**:
```dart
// Protocol structure
// [4 bytes: magic number][4 bytes: data size][N bytes: data]
const int MAGIC_NUMBER = 0x4F4E4E58; // 'ONNX'

Future<Uint8List> _validateBinaryData(Uint8List bytes) async {
  final byteData = bytes.buffer.asByteData();
  final magic = byteData.getUint32(0);
  if (magic != MAGIC_NUMBER) {
    throw Exception('Invalid binary data: magic number mismatch');
  }
  final size = byteData.getUint32(4);
  if (size != bytes.length - 8) {
    throw Exception('Invalid binary data: size mismatch');
  }
  return Uint8List.sublistView(bytes, 8);
}
```

### Risk 5: Increased Code Complexity

**Description**: Maintaining two code paths (binary + standard) increases complexity.

**Impact**: More code to maintain, test, and debug.

**Mitigation**:
- Use feature flags to switch between implementations
- Clearly document which path is used for each scenario
- Eventually deprecate StandardMethodCodec path after binary is stable
- Share common code between paths where possible

### Risk 6: Platform-Specific Bugs

**Description**: Each platform has different binary handling APIs and quirks.

**Impact**: Bug in one platform may not appear in others.

**Mitigation**:
- Extensive cross-platform testing
- Platform-specific unit tests for binary serialization
- Use platform abstractions to minimize direct API usage
- Share test data across platforms to ensure consistency

### Risk 7: Breaking Changes in Flutter Engine

**Description**: Flutter's binary codec or channel APIs may change in future versions.

**Impact**: Plugin may break on Flutter updates.

**Mitigation**:
- Use stable, documented APIs only
- Pin minimum Flutter version requirement
- Monitor Flutter release notes for channel API changes
- Maintain StandardMethodCodec as fallback

## 8. Expected Performance Impact

### Memory Copy Reduction

| Platform | Current Copies | Proposed Copies | Reduction |
|----------|----------------|-----------------|-----------|
| iOS | 2 | 1 | 50% |
| Android | 3 | 1 | 67% |
| Linux | 3 | 1 | 67% |
| Windows | 3 | 1 | 67% |

### Transfer Overhead Reduction

| Operation | Current (StandardMethodCodec) | Proposed (BinaryCodec) | Speed-up |
|-----------|-------------------------------|------------------------|----------|
| Serialization | O(n) with boxing | O(1) memcpy | ~150x |
| Deserialization | O(n) with unboxing | O(1) view cast | ~200x |
| Memory usage | 5-7x data size | 1x data size | 5-7x |

### Real-World Use Case: Video Frame Processing (30 FPS)

**Scenario**: Process 640×480 RGB video frames at 30 FPS

- Tensor size: 640 × 480 × 3 × 4 bytes = 3,686,400 bytes (~3.5MB per frame)
- Frames per second: 30

**Current Implementation**:
- Time per frame (Android): ~80ms retrieval + 20ms processing = 100ms
- Maximum FPS: 10 FPS (bottlenecked by data transfer)
- User experience: Stuttering, lag

**Proposed Implementation**:
- Time per frame: ~25ms retrieval + 20ms processing = 45ms
- Maximum FPS: 22+ FPS (still processing-bound, but much improved)
- User experience: Smoother, more responsive

**Speed-up: 3.2x for tensor retrieval, 2.2x overall**

### Battery Impact

Reduced CPU usage from:
- Fewer memory allocations
- Less garbage collection
- Optimized memcpy operations

**Estimated battery savings**: 15-25% reduction in CPU power consumption for tensor-intensive applications.

## 9. Alternative Approaches Considered

### Alternative 1: FFI with Shared Memory

**Approach**: Use `dart:ffi` to directly access native memory without method channels.

**Pros**:
- Near-zero copy (pointer sharing)
- Potentially 10x faster than binary codec
- No method channel overhead

**Cons**:
- Much higher implementation complexity
- Requires careful memory management (risk of crashes)
- Platform-specific FFI code
- Harder to maintain and debug
- Security concerns with direct memory access

**Why not chosen**: Overkill for current use case. Binary codec provides 2-3x speedup with much lower risk and complexity.

### Alternative 2: Memory-Mapped Files

**Approach**: Write tensor data to shared memory file, pass file descriptor through method channel.

**Pros**:
- True zero-copy on some platforms
- Works well for very large tensors (>100MB)
- Can persist tensor data

**Cons**:
- File I/O overhead for small tensors
- Platform-specific implementation (Android shared memory, iOS file coordination)
- Requires cleanup logic to delete temporary files
- More complex lifecycle management

**Why not chosen**: Binary codec is faster for typical tensor sizes (<10MB). Memory-mapped files add unnecessary complexity.

### Alternative 3: Protobuf or FlatBuffers

**Approach**: Use structured serialization formats designed for efficiency.

**Pros**:
- Well-tested serialization
- Backward compatibility support
- Schema validation

**Cons**:
- Still requires serialization/deserialization overhead
- Additional dependency
- Not as fast as raw binary for homogeneous arrays
- Learning curve for developers

**Why not chosen**: For raw tensor data (homogeneous numeric arrays), binary transfer is simpler and faster.

### Alternative 4: Keep Current Implementation, Optimize Incrementally

**Approach**: Optimize the existing StandardMethodCodec path (e.g., batch processing, caching).

**Pros**:
- No architectural changes
- Lower risk

**Cons**:
- Limited performance gains (maybe 20-30%)
- Doesn't address root cause (serialization overhead)
- Technical debt remains

**Why not chosen**: Doesn't solve the fundamental problem. Binary codec provides much better ROI.

## 10. Decision: Binary Codec with ByteData

**Selected approach**: Binary codec with direct ByteData transfer

**Rationale**:
1. **Best balance** of performance gain (2-3x) vs implementation complexity
2. **Works on all platforms** without platform-specific hacks
3. **Maintains API compatibility** - internal implementation change only
4. **Low risk** - uses stable Flutter APIs
5. **Quick win** - can be implemented and tested within 1-2 weeks per platform

**Next Steps**:
1. Implement on one platform first (Android recommended - highest copy overhead)
2. Validate performance gains and data correctness
3. Roll out to other platforms incrementally
4. Gather user feedback and iterate

## 11. References

- [Flutter Platform Channels Documentation](https://docs.flutter.dev/development/platform-integration/platform-channels)
- [Flutter Binary Codec API](https://api.flutter.dev/flutter/services/BinaryCodec-class.html)
- [Dart TypedData Documentation](https://api.dart.dev/stable/dart-typed_data/dart-typed_data-library.html)
- [ONNX Runtime Memory Management](https://onnxruntime.ai/docs/performance/tune-performance.html)
- [StandardMethodCodec Implementation](https://github.com/flutter/engine/blob/main/shell/platform/common/client_wrapper/standard_codec.cc)

## 12. Appendix: Code References

### Current Implementation Files

- **Dart**: `lib/src/ort_value.dart` (lines 142-159)
- **iOS**: `ios/Classes/FlutterOnnxruntimePlugin.swift` (lines 771-852)
- **Android**: `android/src/main/kotlin/com/masicai/flutteronnxruntime/FlutterOnnxruntimePlugin.kt` (lines 993-1076)
- **Linux**: `linux/src/tensor_manager.cc` (lines 200-281)
- **Windows**: `windows/src/tensor_manager.cc` (lines 200-285)

### Key Performance Bottlenecks

- **iOS line 797**: `data = Array(floatBuffer)` - First copy
- **Android line 1022**: `tensor.floatBuffer.get(floatArray)` - First copy
- **Android line 1023**: `floatArray.toList()` - Second copy
- **Linux/Windows**: `vector_to_fl_value(data_vec)` - Second copy

---

**Document Version**: 1.0
**Date**: 2025-01-03
**Author**: Technical Analysis Team
**Status**: Proposed
