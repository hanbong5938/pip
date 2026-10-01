#include <metal_stdlib>
using namespace metal;

struct VideoUniforms {
    float2 scale;
    float2 sourceMin;
    float2 sourceMax;
    uint rotation;
};
// sourceMin and sourceMax are the texture coordinates for the source's
// top-left and bottom-right corners. Their y components may descend when the
// source texture uses a lower-left origin. rotation is the number of clockwise
// quarter turns (0-3) applied to the displayed video.

struct VideoVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VideoVertexOut videoVertex(
    uint vertexID [[vertex_id]],
    constant VideoUniforms& uniforms [[buffer(0)]])
{
    // Unrotated, the top-left output corner maps to sourceMin and the
    // bottom-right corner to sourceMax; FrameRenderer supplies the
    // orientation-aware coordinates. Rotation remaps each unit-square output
    // coordinate to the source coordinate shown there before interpolating,
    // so non-square source regions rotate exactly. FrameRenderer swaps the
    // aspect-fit dimensions for quarter turns.
    // Two triangles make the aspect-fit bounds exact at every backing scale.
    constexpr float2 positions[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    constexpr float2 coordinates[6] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(1.0, 0.0)
    };

    VideoVertexOut output;
    output.position = float4(positions[vertexID] * uniforms.scale, 0.0, 1.0);
    float2 c = coordinates[vertexID];
    if (uniforms.rotation == 1) {
        // 90° clockwise: the output's top-left shows the source's bottom-left.
        c = float2(c.y, 1.0 - c.x);
    } else if (uniforms.rotation == 2) {
        // 180°: the output's top-left shows the source's bottom-right.
        c = float2(1.0 - c.x, 1.0 - c.y);
    } else if (uniforms.rotation == 3) {
        // 270° clockwise: the output's top-left shows the source's top-right.
        c = float2(1.0 - c.y, c.x);
    }
    output.texCoord = mix(uniforms.sourceMin, uniforms.sourceMax, c);
    return output;
}

fragment float4 videoFragment(
    VideoVertexOut input [[stage_in]],
    texture2d<float> videoTexture [[texture(0)]],
    sampler videoSampler [[sampler(0)]])
{
    return videoTexture.sample(videoSampler, input.texCoord);
}
