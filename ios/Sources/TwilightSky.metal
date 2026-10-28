#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float twilightHash(float2 p) {
    p = fract(p * float2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = twilightHash(i);
    float b = twilightHash(i + float2(1.0, 0.0));
    float c = twilightHash(i + float2(0.0, 1.0));
    float d = twilightHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p, int octaves) {
    const float2x2 turn = float2x2(1.6, 1.2, -1.2, 1.6);
    float sum = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        sum += amplitude * valueNoise(p);
        p = turn * p + 17.3;
        amplitude *= 0.5;
    }
    return sum;
}

static float3 starLayer(float2 position, float cellSize, float threshold, float brightness, float time) {
    float2 cell = floor(position / cellSize);
    float seed = twilightHash(cell);
    if (seed <= threshold) return float3(0.0);
    float rank = (seed - threshold) / (1.0 - threshold);
    float2 center = (cell + 0.25 + 0.5 * float2(twilightHash(cell + 7.1), twilightHash(cell + 3.7))) * cellSize;
    float point = exp(-length_squared(position - center) / (0.3 + 1.4 * rank * rank));
    float twinkle = 0.6 + 0.4 * sin(time * (0.7 + rank * 3.5) + seed * 90.0);
    float3 tint = mix(float3(1.0, 0.85, 0.7), float3(0.75, 0.85, 1.0), twilightHash(cell + 1.3));
    return tint * point * twinkle * brightness * (0.25 + 0.75 * rank * rank);
}

static float ramp(float x, float x0, float y0, float x1, float y1) {
    return mix(y0, y1, saturate((x - x0) / (x1 - x0)));
}

// Hour angle sweeps a body left to right; elevation lifts it from the horizon line toward the top.
static float2 skyPosition(float hourAngle, float elevation, float horizon) {
    float x = 0.5 + hourAngle / 200.0;
    float y = elevation >= 0.0 ? horizon - (horizon - 0.05) * pow(saturate(elevation / 65.0), 0.85) : horizon - elevation / 60.0;
    return float2(x, y);
}

// Single-scattering approximation of the sky. Rayleigh scattering (∝ λ⁻⁴) supplies the blue and reddens the sun
// along long air paths; Chappuis-band ozone absorption removes the remaining orange once the sun is down, which is
// what keeps the blue hour deep blue instead of grey.
// sun = (hour angle°, elevation°, cloud cover 0–1, real seconds); moon = (hour angle°, elevation°, phase 0–1, light appearance).
[[ stitchable ]] half4 twilightSky(float2 position, half4 color, float2 size, float time, float4 sun, float4 moon) {
    float2 uv = position / size;
    float v = saturate(uv.y);
    float e = sun.y;
    float cover = sun.z;
    float realTime = sun.w;
    const float horizon = 0.3;
    const float tau = 6.2831853;

    const float3 rayleigh = float3(5.8, 13.5, 33.1) / 33.1;
    const float3 ozone = float3(0.65, 1.88, 0.085) / 1.88;

    float day = smoothstep(-2.0, 10.0, e);
    float night = 1.0 - smoothstep(-15.0, -6.0, e);

    float sunDepth = e > 0.0 ? ramp(e, 0.0, 1.0, 10.0, 0.55)
                   : e > -12.0 ? ramp(e, -12.0, 1.9, 0.0, 1.0)
                   : ramp(e, -18.0, 2.1, -12.0, 1.9);
    float depth = sunDepth * mix(1.2, 2.4, v);
    float3 sky = rayleigh * exp(-(rayleigh * 0.35 + ozone * 0.6) * depth);
    float light = e > -8.0 ? ramp(e, -8.0, 0.6, 8.0, 0.8)
                : e > -12.0 ? ramp(e, -12.0, 0.28, -8.0, 0.6)
                : ramp(e, -18.0, 0.13, -12.0, 0.3);
    sky *= light;

    // Daylight scatters many times near the horizon and washes toward white.
    sky = mix(sky, float3(0.6, 0.7, 0.84) * light, day * 0.5 * smoothstep(0.0, horizon + 0.1, v));

    float2 sunUV = skyPosition(sun.x, e, horizon);
    float2 sunPos = sunUV * size;
    float sunDistance = length(position - sunPos);
    float altitude = max(e, -2.0);
    float airmass = 1.0 / (sin(altitude * M_PI_F / 180.0) + 0.50572 * pow(altitude + 6.07995, -1.6364));
    float3 sunTint = exp(-rayleigh * 0.12 * airmass);
    sunTint /= max(sunTint.r, 1e-3);

    float sunUp = smoothstep(-6.0, 0.5, e);
    float glow = exp(-sunDistance / (size.y * 0.1)) * 0.55 + exp(-sunDistance / (size.y * 0.4)) * 0.22;
    sky += sunTint * glow * sunUp * mix(0.7, 1.0, day);

    // The afterglow lingers on the side the sun went down.
    float sunSide = exp(-pow((uv.x - sunUV.x) / 0.8, 2.0));
    sky *= 1.0 + 0.3 * sunSide * pow(1.0 - v, 2.0) * smoothstep(-14.0, -4.0, e) * (1.0 - day);

    float golden = smoothstep(-6.0, -1.0, e) * (1.0 - smoothstep(5.0, 12.0, e));
    float band = exp(-pow((v - 0.25) / 0.13, 2.0)) * (0.35 + 0.65 * sunSide);
    sky = mix(sky, float3(1.0, 0.48, 0.24) * 0.9, 0.5 * golden * band);

    float aboveHorizon = 1.0 - smoothstep(horizon - 0.004, horizon + 0.012, v);
    float sunDisc = smoothstep(12.0, 10.0, sunDistance) + exp(-sunDistance / 16.0) * 0.5;
    sky += sunTint * sunDisc * 2.5 * aboveHorizon * step(-1.5, e);

    float moonUp = smoothstep(-1.0, 2.0, moon.y) * aboveHorizon;
    float phase = moon.z;
    float illumination = 0.5 - 0.5 * cos(phase * tau);
    float2 moonPos = skyPosition(moon.x, moon.y, horizon) * size;
    float moonDistance = length(position - moonPos);
    const float moonRadius = 9.0;
    float moonBody = smoothstep(moonRadius + 0.8, moonRadius - 0.8, moonDistance) * moonUp;
    if (moonBody > 0.0) {
        float2 local = (position - moonPos) / moonRadius;
        float limb = sqrt(saturate(1.0 - local.y * local.y));
        float terminator = cos(phase * tau) * limb;
        float side = phase < 0.5 ? local.x : -local.x;
        float lit = smoothstep(terminator - 0.06, terminator + 0.06, side);
        float maria = 0.62 + 0.38 * fbm(local * 2.6 + 5.0, 4);
        float3 moonLight = float3(1.0, 0.98, 0.92) * maria * lit * 1.05;
        sky = mix(sky, sky * mix(0.4, 1.0, day) + moonLight * mix(1.0, 0.35, day), moonBody);
    }
    float moonHalo = exp(-moonDistance / (size.y * 0.16)) * illumination * moonUp * (1.0 - day);
    sky += float3(0.45, 0.55, 0.75) * 0.3 * moonHalo + float3(0.01, 0.018, 0.04) * illumination * moonUp * night;

    // Clouds sit on a flat layer seen in perspective: large overhead, thin and crowded toward the horizon.
    float cloudAlpha = 0.0;
    float above = horizon - v;
    if (above > 0.0 && cover > 0.0) {
        float distance = 1.0 / (above + 0.06);
        float across = (position.x - 0.5 * size.x) / size.y;
        float2 p = float2(across * distance * 1.2, distance * 0.5) + float2(time * 0.012, time * 0.003);
        float density = fbm(p, 5);
        float threshold = mix(0.6, 0.4, cover);
        cloudAlpha = smoothstep(threshold, threshold + 0.18, density) * smoothstep(0.0, 0.07, above);

        if (cloudAlpha > 0.0) {
            float2 toward = normalize(sunPos - position + float2(0.0, 1e-3)) * float2(1.0, -1.0);
            float shadowed = fbm(p + toward * 0.12, 4);
            float facing = saturate(0.6 + (density - shadowed) * 3.5);

            float dusk = 1.0 - smoothstep(2.0, 14.0, e);
            float3 lit = mix(float3(1.0, 0.98, 0.95), mix(sunTint, float3(1.0, 0.52, 0.55), 0.35), dusk);
            lit = mix(lit, float3(0.9, 0.45, 0.62), smoothstep(0.0, -4.0, e));
            float strength = e > -1.0 ? ramp(e, -1.0, 0.7, 20.0, 0.95) : ramp(e, -6.0, 0.0, -1.0, 0.7);
            float3 cloudLight = lit * strength + float3(0.1, 0.11, 0.14) * illumination * moonUp * night;
            float3 cloudShade = mix(sky * 0.78, float3(0.42, 0.46, 0.56), day);
            cloudShade = mix(cloudShade, float3(0.26, 0.2, 0.32), golden * 0.7);
            float3 cloud = mix(cloudShade, cloudLight, facing);
            cloud += sunTint * glow * 0.6 * (1.0 - cloudAlpha) * sunUp;
            sky = mix(sky, cloud, cloudAlpha * 0.92);
        }
    }

    // Light appearance: the same sky, brighter, washing into the white page instead of the night.
    if (moon.w > 0.5) {
        float wash = pow(1.0 - smoothstep(0.0, 0.95, v), 1.1) * mix(0.35, 0.95, smoothstep(-8.0, 2.0, e));
        float3 page = mix(float3(1.0), saturate(sky * 1.35), wash);
        return half4(half3(saturate(page + (twilightHash(position) - 0.5) / 255.0)), 1.0);
    }

    float dusky = pow(1.0 - v, 1.7) * exp(-0.6 * v);
    float bright = pow(1.0 - smoothstep(0.0, 1.0, v), 1.2) * mix(1.0, 0.45, smoothstep(horizon - 0.01, horizon + 0.12, v));
    sky *= mix(dusky, bright, smoothstep(-6.0, 6.0, e));

    float clear = (1.0 - cloudAlpha) * (1.0 - moonBody);
    if (night > 0.0) {
        float emerge = mix(smoothstep(0.05, 0.4, v), 1.0, smoothstep(-12.0, -18.0, e)) * (1.0 - smoothstep(0.85, 1.0, v));
        float full = smoothstep(-12.0, -18.0, e);
        float3 stars = starLayer(position, 6.0, mix(0.975, 0.93, full), 0.55, realTime)
                     + starLayer(position + 101.0, 17.0, mix(0.96, 0.86, full), 1.4, realTime);

        float2 along = normalize(float2(1.0, 0.42));
        float band = dot(position / size.x - float2(0.0, 0.05), float2(-along.y, along.x));
        float galaxy = exp(-band * band / 0.012) * smoothstep(0.35, 0.75, fbm(position / 70.0, 4));
        float moonWash = 1.0 - 0.6 * illumination * moonUp;
        sky += (stars + float3(0.55, 0.6, 0.78) * galaxy * 0.07 * moonWash) * emerge * night * clear;

        const float period = 29.0;
        float k = floor(realTime / period);
        float t = realTime - k * period;
        if (night > 0.5 && t < 0.9 && twilightHash(float2(k, 4.2)) > 0.35) {
            float2 origin = float2(0.1 + 0.8 * twilightHash(float2(k, 1.0)), 0.05 + 0.3 * twilightHash(float2(k, 2.0))) * size;
            float2 direction = normalize(float2(twilightHash(float2(k, 3.0)) > 0.5 ? 1.0 : -1.0, 0.45));
            float length = size.x * 0.3;
            float progress = t / 0.9;
            float2 relative = position - (origin + direction * length * progress);
            float behind = dot(relative, -direction);
            float offset = dot(relative, float2(-direction.y, direction.x));
            float streak = step(0.0, behind) * (1.0 - smoothstep(0.0, length * 0.35, behind)) * exp(-offset * offset / 0.5);
            sky += float3(0.9, 0.95, 1.0) * streak * sin(progress * M_PI_F) * night * clear;
        }
    }

    // Dither below one 8-bit step so the long dark gradient never bands.
    sky += (twilightHash(position) - 0.5) / 255.0;

    return half4(half3(saturate(sky)), 1.0);
}
