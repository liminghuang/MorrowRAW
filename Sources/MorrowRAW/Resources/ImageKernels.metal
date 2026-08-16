#include <metal_stdlib>
using namespace metal;

struct NLMUniforms {
    float hSquared;
};

struct LabUniforms {
    float saturation;
    float vibrance;
};

struct DistortionUniforms {
    float k1;
    float k2;
    float2 center;
    float2 scale;
};

struct InpaintUniforms {
    float2 center;
    float radius;
    float searchRadius;
    float strength;
    uint iteration;
    uint iterations;
};

struct PoissonUniforms {
    float2 sourceCenter;
    float2 targetCenter;
    float radius;
    float strength;
    uint iteration;
    uint iterations;
};

inline float pixelLuma(float3 rgb) {
    return dot(rgb, float3(0.2126, 0.7152, 0.0722));
}

inline int2 clampedPoint(int2 point, int2 maximum) {
    return clamp(point, int2(0), maximum);
}

kernel void nonLocalMeans(texture2d<half, access::read> input [[texture(0)]],
                          texture2d<half, access::write> output [[texture(1)]],
                          constant NLMUniforms& uniforms [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    const int2 maximum = int2(output.get_width() - 1, output.get_height() - 1);
    const int2 center = int2(gid);
    const int2 cross[5] = { int2(0, 0), int2(-1, 0), int2(1, 0),
                            int2(0, -1), int2(0, 1) };
    half3 sum = half3(0.0h);
    float totalWeight = 0.0;

    for (int offsetY = -4; offsetY <= 4; offsetY += 2) {
        for (int offsetX = -4; offsetX <= 4; offsetX += 2) {
            const int2 candidate = clampedPoint(center + int2(offsetX, offsetY), maximum);
            float patchError = 0.0;
            for (uint sample = 0; sample < 5; sample++) {
                const int2 centerPoint = clampedPoint(center + cross[sample], maximum);
                const int2 candidatePoint = clampedPoint(candidate + cross[sample], maximum);
                const float centerLuma = pixelLuma(float3(input.read(uint2(centerPoint)).rgb));
                const float candidateLuma = pixelLuma(float3(input.read(uint2(candidatePoint)).rgb));
                const float delta = centerLuma - candidateLuma;
                patchError += delta * delta;
            }
            patchError /= 5.0;
            const float weight = exp(-patchError / uniforms.hSquared);
            sum += half3(input.read(uint2(candidate)).rgb) * half(weight);
            totalWeight += weight;
        }
    }

    const half4 original = input.read(gid);
    output.write(half4(half3(float3(sum) / max(totalWeight, 0.0001)), original.a), gid);
}

inline float labPivot(float value) {
    const float epsilon = 216.0 / 24389.0;
    const float kappa = 24389.0 / 27.0;
    return value > epsilon ? pow(value, 1.0 / 3.0) : (kappa * value + 16.0) / 116.0;
}

inline float inverseLabPivot(float value) {
    const float epsilon = 216.0 / 24389.0;
    const float kappa = 24389.0 / 27.0;
    const float cube = value * value * value;
    return cube > epsilon ? cube : (116.0 * value - 16.0) / kappa;
}

inline float linearize(float value) {
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

inline float delinearize(float value) {
    const float clamped = max(0.0, value);
    return clamped <= 0.0031308
        ? clamped * 12.92
        : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055;
}

kernel void labChroma(texture2d<half, access::read> input [[texture(0)]],
                      texture2d<half, access::write> output [[texture(1)]],
                      constant LabUniforms& uniforms [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    const half4 source = input.read(gid);
    const float3 rgb = float3(source.rgb);
    const float r = linearize(rgb.r);
    const float g = linearize(rgb.g);
    const float b = linearize(rgb.b);
    const float x = labPivot((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047);
    const float y = labPivot(0.2126729 * r + 0.7151522 * g + 0.0721750 * b);
    const float z = labPivot((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883);
    const float lightness = 116.0 * y - 16.0;
    float a = 500.0 * (x - y);
    float chromaB = 200.0 * (y - z);
    const float chroma = sqrt(a * a + chromaB * chromaB);
    const float lowChromaWeight = max(0.0, 1.0 - min(1.0, chroma / 100.0));
    const float factor = 1.0 + uniforms.saturation
        + uniforms.vibrance * lowChromaWeight;
    a *= factor;
    chromaB *= factor;

    const float fy = (lightness + 16.0) / 116.0;
    const float fx = fy + a / 500.0;
    const float fz = fy - chromaB / 200.0;
    const float X = 0.95047 * inverseLabPivot(fx);
    const float Y = inverseLabPivot(fy);
    const float Z = 1.08883 * inverseLabPivot(fz);
    const float outR = delinearize(3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z);
    const float outG = delinearize(-0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z);
    const float outB = delinearize(0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z);
    output.write(half4(half3(outR, outG, outB), source.a), gid);
}

kernel void brownConrady(texture2d<half, access::read> input [[texture(0)]],
                         texture2d<half, access::write> output [[texture(1)]],
                         constant DistortionUniforms& uniforms [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    const int2 maximum = int2(output.get_width() - 1, output.get_height() - 1);
    const float2 destination = float2(gid);
    const float2 normalized = (destination - uniforms.center) / uniforms.scale;
    const float radiusSquared = dot(normalized, normalized);
    const float radial = 1.0 + uniforms.k1 * radiusSquared
        + uniforms.k2 * radiusSquared * radiusSquared;
    const float2 source = uniforms.center + normalized * radial * uniforms.scale;
    const int2 sourcePoint = clampedPoint(int2(source + 0.5), maximum);
    output.write(input.read(uint2(sourcePoint)), gid);
}

// Parallel fast-marching approximation. Each dispatch advances one radial
// frontier layer, so pixels can be filled concurrently while still reading
// only values from an earlier layer in the previous texture.
kernel void teleaIterative(texture2d<half, access::read> original [[texture(0)]],
                           texture2d<half, access::read> previous [[texture(1)]],
                           texture2d<half, access::write> output [[texture(2)]],
                           constant InpaintUniforms& uniforms [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    const float2 point = float2(gid);
    const float2 delta = point - uniforms.center;
    const float distanceFromCenter = length(delta);
    const bool inside = distanceFromCenter <= uniforms.radius;
    const half4 originalPixel = original.read(gid);
    if (!inside) {
        output.write(originalPixel, gid);
        return;
    }

    const float layer = max(0.0, uniforms.radius - distanceFromCenter);
    const float currentLayer = float(uniforms.iteration);
    if (layer > currentLayer + 1.0) {
        output.write(previous.read(gid), gid);
        return;
    }

    const int2 maximum = int2(output.get_width() - 1, output.get_height() - 1);
    const int2 center = int2(gid);
    const int searchRadius = max(1, int(uniforms.searchRadius));
    half3 sum = half3(0.0h);
    float totalWeight = 0.0;
    for (int y = -searchRadius; y <= searchRadius; y++) {
        for (int x = -searchRadius; x <= searchRadius; x++) {
            if (x == 0 && y == 0) continue;
            const int2 samplePoint = clampedPoint(center + int2(x, y), maximum);
            const float sampleDistance = length(float2(samplePoint) - uniforms.center);
            const bool sampleInside = sampleDistance <= uniforms.radius;
            const float sampleLayer = max(0.0, uniforms.radius - sampleDistance);
            if (sampleInside && sampleLayer >= layer) continue;
            const half4 sample = previous.read(uint2(samplePoint));
            const float weight = 1.0 / max(1.0, float(x * x + y * y));
            sum += half3(sample.rgb) * half(weight);
            totalWeight += weight;
        }
    }

    const float3 estimate = totalWeight > 0.0
        ? float3(sum) / totalWeight
        : float3(previous.read(gid).rgb);
    const float amount = clamp(uniforms.strength, 0.0, 1.0);
    const float3 blended = mix(float3(originalPixel.rgb), estimate, amount);
    output.write(half4(half3(blended), originalPixel.a), gid);
}

// Jacobi iteration for gradient-domain cloning. Source gradients are sampled
// at the translated source location; target pixels outside the disk provide
// the Dirichlet boundary condition from the original texture.
kernel void poissonIterative(texture2d<half, access::read> original [[texture(0)]],
                             texture2d<half, access::read> previous [[texture(1)]],
                             texture2d<half, access::write> output [[texture(2)]],
                             constant PoissonUniforms& uniforms [[buffer(0)]],
                             threadgroup half4* previousTile [[threadgroup(0)]],
                             uint2 tid [[thread_position_in_threadgroup]],
                             uint2 threadsPerGroup [[threads_per_threadgroup]],
                             uint2 tgid [[threadgroup_position_in_grid]],
                             uint2 gid [[thread_position_in_grid]]) {
    const uint tileWidth = threadsPerGroup.x + 2;
    const uint tileHeight = threadsPerGroup.y + 2;
    for (uint tileY = tid.y; tileY < tileHeight; tileY += threadsPerGroup.y) {
        for (uint tileX = tid.x; tileX < tileWidth; tileX += threadsPerGroup.x) {
            const int2 tilePoint = int2(tgid * threadsPerGroup + uint2(tileX, tileY))
                + int2(-1, -1);
            const int2 maximum = int2(previous.get_width() - 1, previous.get_height() - 1);
            const int2 clamped = clampedPoint(tilePoint, maximum);
            previousTile[tileY * tileWidth + tileX] = previous.read(uint2(clamped));
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    const float2 point = float2(gid);
    const float2 targetDelta = point - uniforms.targetCenter;
    const bool inside = length(targetDelta) <= uniforms.radius;
    const half4 originalPixel = original.read(gid);
    if (!inside) {
        output.write(originalPixel, gid);
        return;
    }

    const int2 maximum = int2(output.get_width() - 1, output.get_height() - 1);
    const int2 neighbours[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    half3 sum = half3(0.0h);
    float count = 0.0;
    const int2 targetPoint = int2(gid);
    const int2 sourcePoint = int2(uniforms.sourceCenter + targetDelta);

    for (uint n = 0; n < 4; n++) {
        const int2 offset = neighbours[n];
        const int2 targetNeighbour = clampedPoint(targetPoint + offset, maximum);
        const int2 sourceNeighbour = clampedPoint(sourcePoint + offset, maximum);
        const int2 sourceCurrent = clampedPoint(sourcePoint, maximum);
        const half3 sourceGradient = half3(original.read(uint2(sourceCurrent)).rgb)
            - half3(original.read(uint2(sourceNeighbour)).rgb);
        const bool neighbourInside = length(float2(targetNeighbour) - uniforms.targetCenter)
            <= uniforms.radius;
        const int2 localNeighbour = int2(tid) + offset + int2(1, 1);
        const half3 neighbourValue = neighbourInside
            ? half3(previousTile[uint(localNeighbour.y) * tileWidth + uint(localNeighbour.x)].rgb)
            : half3(original.read(uint2(targetNeighbour)).rgb);
        sum += neighbourValue + sourceGradient;
        count += 1.0;
    }

    const float3 estimate = float3(sum) / max(count, 1.0);
    const float amount = clamp(uniforms.strength, 0.0, 1.0);
    const bool lastIteration = uniforms.iteration + 1 >= uniforms.iterations;
    const float3 result = lastIteration
        ? mix(float3(originalPixel.rgb), estimate, amount)
        : estimate;
    output.write(half4(half3(result), originalPixel.a), gid);
}
