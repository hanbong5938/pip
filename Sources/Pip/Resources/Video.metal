#include <metal_stdlib>
using namespace metal;

struct VideoUniforms {
    float2 scale;
    float2 sourceMin;
    float2 sourceMax;
};
// sourceMin and sourceMax are the texture coordinates for the output's
// top-left and bottom-right corners. Their y components may descend when the
// source texture uses a lower-left origin.

struct VideoVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VideoVertexOut videoVertex(
    uint vertexID [[vertex_id]],
    constant VideoUniforms& uniforms [[buffer(0)]])
{
    // Map the top-left output corner to sourceMin and the bottom-right corner
    // to sourceMax; FrameRenderer supplies the orientation-aware coordinates.
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
    output.texCoord = mix(uniforms.sourceMin, uniforms.sourceMax, coordinates[vertexID]);
    return output;
}

fragment float4 videoFragment(
    VideoVertexOut input [[stage_in]],
    texture2d<float> videoTexture [[texture(0)]],
    sampler videoSampler [[sampler(0)]])
{
    return videoTexture.sample(videoSampler, input.texCoord);
}
