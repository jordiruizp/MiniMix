// Código MSL de Render, compilado en tiempo de ejecución con
// `MTLDevice.makeLibrary(source:options:)` (no hay compilador `metal` con CLT).
// Si el orquestador añade recursos al target, puede moverse a
// `Shaders/Render.metal.txt` sin cambiar los nombres de función.
//
// Convenciones:
// - Todas las texturas contienen color con alfa PREMULTIPLICADO.
// - uv con origen arriba-izquierda (como las texturas Metal).
// - Los rectángulos de encaje son (origen.xy, tamaño.zw) en uv del destino.

enum ShaderSource {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;

    struct MMVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Triángulo único que cubre el destino (sin vertex buffer).
    vertex MMVertexOut minimix_fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        MMVertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    // Debe coincidir con `CompositorUniforms` (Swift).
    struct CompositorUniforms {
        float4 rectA;
        float4 rectB;
        float4 background;   // premultiplicado
        float mixValue;
        uint kind;           // 0 cut, 1 fade, 2 wipe
        uint hasA;
        uint hasB;
        float wipeSoftness;  // semiancho del borde del wipe, en uv
    };

    static float4 mm_sample_layer(texture2d<float> tex, sampler s, float2 uv, float4 rect) {
        float2 suv = (uv - rect.xy) / rect.zw;
        if (any(suv < 0.0) || any(suv > 1.0)) {
            return float4(0.0);
        }
        return tex.sample(s, suv);
    }

    fragment float4 minimix_compositor_fragment(MMVertexOut in [[stage_in]],
                                                constant CompositorUniforms &u [[buffer(0)]],
                                                texture2d<float> texA [[texture(0)]],
                                                texture2d<float> texB [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 a = u.hasA != 0 ? mm_sample_layer(texA, s, in.uv, u.rectA) : float4(0.0);
        float4 b = u.hasB != 0 ? mm_sample_layer(texB, s, in.uv, u.rectB) : float4(0.0);
        float t;
        if (u.kind == 0) {
            t = u.mixValue >= 0.5 ? 1.0 : 0.0;
        } else if (u.kind == 2) {
            // B entra desde la izquierda; el borde recorre [-soft, 1 + soft].
            float soft = max(u.wipeSoftness, 1e-5);
            float edge = u.mixValue * (1.0 + 2.0 * soft) - soft;
            t = 1.0 - smoothstep(edge - soft, edge + soft, in.uv.x);
        } else {
            t = u.mixValue;
        }
        float4 layer = mix(a, b, t);
        return layer + u.background * (1.0 - layer.a);
    }

    // Debe coincidir con `MonitorUniforms` (Swift). Coordenadas en píxeles del destino.
    struct MonitorUniforms {
        float4 contentRect;
        float4 borderColor;  // premultiplicado
        float2 viewport;
        float borderWidth;
        uint hasTexture;
    };

    fragment float4 minimix_monitor_fragment(MMVertexOut in [[stage_in]],
                                             constant MonitorUniforms &u [[buffer(0)]],
                                             texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 p = in.position.xy;
        float bw = u.borderWidth;
        if (bw > 0.0 && (p.x < bw || p.y < bw || p.x > u.viewport.x - bw || p.y > u.viewport.y - bw)) {
            return u.borderColor;
        }
        if (u.hasTexture == 0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        float2 suv = (p - u.contentRect.xy) / u.contentRect.zw;
        if (any(suv < 0.0) || any(suv > 1.0)) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        float4 c = tex.sample(s, suv);
        return float4(c.rgb, 1.0); // sobre negro (premultiplicado)
    }
    """
}
