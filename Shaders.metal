#include <metal_stdlib>
using namespace metal;

struct RasterizerData {
    float4 position [[position]];
    float2 texCoords;
};

struct PerspectiveUniforms {
    float angle;              // Current lid angle in radians
    float aspect;             // Screen aspect ratio (width / height)
    float keystoneStrength;   // Horizontal taper intensity
    float stretchBalance;     // Aspect ratio compensator
    float settleProgress;     // 0.0 = full perspective, 1.0 = completely flat & unwarped
    float keyboardReflection; // Intensity of simulated keyboard reflection (0.0 to 1.0)
    float keyboardTilt;       // Ground-plane pitch / tilt angle (0.4 to 2.0, default 1.0)
    float keyboardReach;      // Reflection height / reach (0.15 to 0.60, default 0.35)
    float keyboardBacklight;  // Key backlight luminescence brightness (0.0 to 2.0, default 1.0)
    float keyboardOffset;     // Vertical position shift to bring keys right to bottom edge (default 0.00)
    float keyboardWidth;      // Width of the keyboard well (0.60 to 1.00, default 0.94)
    float keyboardDepthBlur;  // Optical depth-of-field blur gradient between closest & furthest row (default 1.0)
    float showCalibrator;     // 1.0 if calibrator is active, 0.0 otherwise
    float frostedGlass;       // Frosted glass intensity (0.0 to 1.0, default 0.10)
    float blurIntensity;      // Screen depth blur intensity (0.0 to 2.0, default 1.00)
    float shadowIntensity;    // Screen depth shadow intensity (0.0 to 2.0, default 1.00)
    float lowAngleCompensation; // Low-angle taper & stretch compensation intensity (0.0 to 2.0, default 1.00)
    float clockProgress;      // Smooth transition progress for clock mode & background dimming (0.0 to 1.0)
    float showClock;          // 1.0 if clock texture is active, 0.0 otherwise
    float transitionBlur;     // Quick entrance blur factor (1.0 = blurred on entry, 0.0 = clear)
    // Head Tracking Extensions (16 bytes)
    float headX;              // Normalized head lateral offset (-1.0 to 1.0, 0.0 = center)
    float headY;              // Normalized head vertical offset (-1.0 to 1.0, 0.0 = center)
    float headZ;              // Head distance ratio (0.5 to 2.2, 1.0 = nominal ~50cm)
    float headTrackingActive; // 1.0 if head tracking is active, 0.0 otherwise
    // Dynamic Head Tracking Tunables (16 bytes)
    float headParallaxSensitivity;     // Lateral shear sensitivity (0.0 to 2.5, default 1.0)
    float headElevationSensitivity;    // Vertical tilt sensitivity (0.0 to 2.5, default 1.0)
    float keyboardParallaxSensitivity; // Keyboard lateral reflection shear with headX (0.0 to 2.5, default 0.85)
    float keyboardPitchSensitivity;    // Keyboard tilt & reach foreshortening with headY (0.0 to 2.5, default 0.85)
    // Padding (16 bytes)
    float pad0;
    float pad1;
    float pad2;
    float pad3;
};

vertex RasterizerData vertex_main(uint vertexID [[vertex_id]]) {
    const float2 positions[6] = {
        float2(-1.0,  1.0), float2(-1.0, -1.0), float2( 1.0, -1.0),
        float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
    };
    const float2 texCoords[6] = {
        float2(0.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0)
    };

    RasterizerData out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoords = texCoords[vertexID];
    return out;
}

// Geometric structure for 1:1 Apple Magic Keyboard / MacBook layout
struct KeyGeometry {
    float centerU;
    float halfWU;
    float centerV;
    float halfHV;
    bool isKey;
    bool isTouchId;
    bool hasHomingBump;
    bool hasCapsDot;
    bool isOuterCorner;
};

// Computes key boundaries, offsets, and metadata across all 6 rows based on the official MacBook keyboard reference
static KeyGeometry getKeyGeometry(int rowIndex, float u, float relV) {
    KeyGeometry g;
    g.centerU = 0.5f;
    g.halfWU = 0.025f;
    g.centerV = 0.5f;
    g.halfHV = 0.39f; // Standard key covers ~78% of row height (0.5 ± 0.39)
    g.isKey = true;
    g.isTouchId = false;
    g.hasHomingBump = false;
    g.hasCapsDot = false;
    g.isOuterCorner = false;

    // Standard horizontal gap between keycaps (in normalized well width units)
    const float gapU = 0.0055f;

    if (rowIndex == 0) {
        // FUNCTION ROW: 14 keys (Esc, 12 F-keys, Touch ID sensor)
        // Esc: 0.000 -> 0.102 (elongated Escape key)
        // F1..F12: 12 keys evenly spaced from 0.106 to 0.922 (width 0.068 each)
        // Touch ID: distinct compact square key at 0.930 -> 0.998 (width 0.068)
        if (u < 0.102f) {
            float left = gapU * 0.5f;
            float right = 0.102f - gapU * 0.5f;
            g.centerU = (left + right) * 0.5f;
            g.halfWU = max((right - left) * 0.5f, 0.005f);
            g.isOuterCorner = true; // Esc top-left fillet
        } else if (u < 0.106f) {
            g.isKey = false; // Gap between Esc and F1
        } else if (u < 0.922f) {
            int fIdx = int(floor((u - 0.106f) / 0.068f));
            fIdx = clamp(fIdx, 0, 11);
            float left = 0.106f + float(fIdx) * 0.068f + gapU * 0.5f;
            float right = 0.106f + float(fIdx + 1) * 0.068f - gapU * 0.5f;
            g.centerU = (left + right) * 0.5f;
            g.halfWU = max((right - left) * 0.5f, 0.005f);
        } else if (u < 0.930f) {
            g.isKey = false; // Aluminum separator between F12 and Touch ID
        } else {
            float left = 0.930f + gapU * 0.5f;
            float right = 0.998f - gapU * 0.5f;
            g.centerU = (left + right) * 0.5f;
            g.halfWU = max((right - left) * 0.5f, 0.005f);
            g.halfHV = 0.36f; // Compact square keycap
            g.isTouchId = true;
            g.isOuterCorner = true; // Touch ID top-right fillet
        }
    } else if (rowIndex == 1) {
        // NUMBER ROW: 14 keys (~, 1..0, -, =, Delete)
        const float B[15] = {0.0f, 0.068f, 0.136f, 0.204f, 0.272f, 0.340f, 0.408f, 0.476f, 0.544f, 0.612f, 0.680f, 0.748f, 0.816f, 0.884f, 1.0f};
        for (int i = 0; i < 14; ++i) {
            if (u <= B[i + 1] || i == 13) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);
                break;
            }
        }
    } else if (rowIndex == 2) {
        // TAB / QWERTY ROW: 14 keys (Tab, Q..P, [, ], \)
        const float B[15] = {0.0f, 0.103f, 0.171f, 0.239f, 0.307f, 0.375f, 0.443f, 0.511f, 0.579f, 0.647f, 0.715f, 0.783f, 0.851f, 0.919f, 1.0f};
        for (int i = 0; i < 14; ++i) {
            if (u <= B[i + 1] || i == 13) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);
                break;
            }
        }
    } else if (rowIndex == 3) {
        // CAPS / HOME ROW: 13 keys (Caps Lock, A..L, ;, ', Return)
        const float B[14] = {0.0f, 0.123f, 0.191f, 0.259f, 0.327f, 0.395f, 0.463f, 0.531f, 0.599f, 0.667f, 0.735f, 0.803f, 0.871f, 1.0f};
        for (int i = 0; i < 13; ++i) {
            if (u <= B[i + 1] || i == 12) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);
                if (i == 0) g.hasCapsDot = true; // Caps lock indicator LED
                if (i == 4) g.hasHomingBump = true; // 'F' tactile homing bar
                if (i == 7) g.hasHomingBump = true; // 'J' tactile homing bar
                break;
            }
        }
    } else if (rowIndex == 4) {
        // SHIFT ROW: 12 keys (Left Shift, Z..M, ,, ., /, Right Shift)
        const float B[13] = {0.0f, 0.158f, 0.226f, 0.294f, 0.362f, 0.430f, 0.498f, 0.566f, 0.634f, 0.702f, 0.770f, 0.838f, 1.0f};
        for (int i = 0; i < 12; ++i) {
            if (u <= B[i + 1] || i == 11) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);
                break;
            }
        }
    } else {
        // ROW 5: BOTTOM MODIFIERS, SPACEBAR & INVERTED-T ARROW KEYS
        // 0: Fn, 1: Control, 2: Option, 3: Command, 4: Spacebar, 5: Command, 6: Option, 7: Left Arrow, 8: Up/Down, 9: Right Arrow
        const float B[11] = {0.0f, 0.071f, 0.142f, 0.227f, 0.322f, 0.678f, 0.773f, 0.858f, 0.905f, 0.953f, 1.0f};
        for (int i = 0; i < 10; ++i) {
            if (u <= B[i + 1] || i == 9) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);

                if (i == 0) {
                    g.isOuterCorner = true; // Fn bottom-left fillet
                } else if (i == 7) {
                    // Left Arrow: half-height key in bottom half
                    if (relV > 0.50f) {
                        g.isKey = false; // Empty aluminum topcase above Left Arrow
                    } else {
                        g.centerV = 0.26f;
                        g.halfHV = 0.20f;
                    }
                } else if (i == 8) {
                    // Up / Down Arrow: two stacked half-height keys
                    if (relV > 0.50f) {
                        g.centerV = 0.74f;
                        g.halfHV = 0.20f;
                    } else {
                        g.centerV = 0.26f;
                        g.halfHV = 0.20f;
                    }
                } else if (i == 9) {
                    // Right Arrow: half-height key in bottom half
                    g.isOuterCorner = true; // Right Arrow bottom-right fillet
                    if (relV > 0.50f) {
                        g.isKey = false; // Empty aluminum topcase above Right Arrow
                    } else {
                        g.centerV = 0.26f;
                        g.halfHV = 0.20f;
                    }
                }
                break;
            }
        }
    }
    return g;
}

// Synthesizes an authentic MacBook keyboard reflection matching the reference hardware layout:
// - Dynamic Screen Light Simulation: The screen acts as an active area light source illuminating the keyboard in real time.
// - Opacity range is 45° to 90°: exactly 0 at 90° and <= 45°, holding normal full strength in the middle (~60° to 75°).
// - Closest row (Row 0 right at the bottom hinge) is in sharp focus, full opacity, and high contrast.
// - As rows recede in depth, all edges blur and opacity smoothly falls off, making distant rows translucent.
static float4 sampleKeyboardReflection(float2 finalUV,
                                        float delta,
                                        float currentTheta,
                                        constant PerspectiveUniforms &uniforms,
                                        texture2d<float> blurredTexture,
                                        sampler textureSampler) {
    const float uprightRad = 1.5707963f; // 90° in radians
    const float minAngleRad = 0.87266f; // 45° in radians (pi / 4)

    if (currentTheta <= minAngleRad || currentTheta >= uprightRad) {
        return float4(0.0f);
    }

    // Distance from bottom hinge (finalUV.y = 1.0) upward into the display
    float vY = max(1.0f - finalUV.y, 0.0f) + uniforms.keyboardOffset;
    float maxReach = clamp(uniforms.keyboardReach, 0.12f, 0.65f);

    // Dynamic 3D Head Tracking for Keyboard Ground Plane:
    // Vertical head motion (headY): reversed to match viewpoint pitch
    float headPitchMod = 1.0f - (uniforms.headY * 0.35f * uniforms.keyboardPitchSensitivity) * uniforms.headTrackingActive;
    float effectiveReach = clamp(maxReach * headPitchMod, 0.10f, 0.75f);
    float tilt = max(uniforms.keyboardTilt * headPitchMod, 0.10f);

    if (vY < 0.0f || vY > effectiveReach || finalUV.x < 0.0f || finalUV.x > 1.0f) {
        return float4(0.0f);
    }

    // Normalized distance on the ground plane (0.0 at hinge, 1.0 at max reach)
    float normY = vY / effectiveReach;

    // Linear keystone taper across the angled plane (straight lines remain straight)
    float taper = 1.0f + normY * (0.45f * tilt);

    // Horizontal head motion (headX): reversed to match user viewpoint shift
    float headParallaxMod = -uniforms.headX * (0.35f * uniforms.keyboardParallaxSensitivity) * uniforms.headTrackingActive;
    float headReflectShift = headParallaxMod * (0.35f + 0.65f * normY);
    float headKeystoneAsymmetry = 1.0f + (finalUV.x - 0.5f) * headParallaxMod * 0.45f;

    float X = (finalUV.x - 0.5f + headReflectShift) * taper * headKeystoneAsymmetry;

    // Keyboard well bounds
    float halfW = clamp(uniforms.keyboardWidth * 0.5f, 0.30f, 0.495f);
    float wellLeft = -halfW;
    float wellRight = halfW;
    float wellWidth = wellRight - wellLeft;
    const float wellBottom = 0.00f; // Anchored directly to bottom screen edge
    float wellTop = maxReach * 0.68f;

    // --- Dynamic Screen Light Simulation (Screen-Space Area Light & Radiance) ---
    // Sample downward radiance from the blurred screen texture
    float screenSampleX = clamp(finalUV.x, 0.02f, 0.98f);
    // Keys near the hinge catch light from the bottom of the screen; distant keys catch light from higher up
    float screenSampleY = clamp(1.0f - normY * 0.45f, 0.45f, 0.98f);
    float3 screenLightDirect = blurredTexture.sample(textureSampler, float2(screenSampleX, screenSampleY)).rgb;
    float3 screenLightAmbient = blurredTexture.sample(textureSampler, float2(0.5f, 0.75f)).rgb;
    float3 screenRadiance = mix(screenLightAmbient, screenLightDirect, 0.75f);
    float screenLightIntensity = clamp(1.0f - normY * 0.60f, 0.20f, 1.0f);

    // Continuous Depth-of-Field (DoF) optical blur parameter:
    // 0.0 at the hinge (Row 0), smoothly accelerating to > 1.0 at Row 5 and the top of the well
    float dofT = clamp(vY / max(maxReach * 0.70f, 0.01f), 0.0f, 1.5f);
    float depthBlur = pow(dofT, 1.4f) * clamp(uniforms.keyboardDepthBlur, 0.0f, 3.0f);

    // Progressive Depth Opacity:
    // Closest row is 100% opaque. Receding rows gracefully fade out and become translucent.
    float rowDepthProgress = clamp(vY / max(wellTop, 0.01f), 0.0f, 1.25f);
    float rowOpacity = mix(1.0f, 0.18f, smoothstep(0.0f, 1.0f, rowDepthProgress));

    // Smooth forward chassis falloff near top of reach
    float forwardFalloff = smoothstep(1.0f, 0.75f, normY);

    // --- 1. Soft Out-of-Focus Well Silhouette ---
    // At the bottom hinge, the well edge is crisp. As it recedes toward the top,
    // the left, right, and top perimeter edges blur and diffuse widely into the chassis.
    float wellEdgeBlur = mix(0.0015f, 0.038f, clamp(depthBlur, 0.0f, 2.0f));
    float wellMaskX = smoothstep(-wellEdgeBlur, wellEdgeBlur, X - wellLeft) *
                      smoothstep(-wellEdgeBlur, wellEdgeBlur, wellRight - X);
    float wellMaskY = smoothstep(-wellEdgeBlur, wellEdgeBlur, wellTop - vY);
    float wellMask = clamp(wellMaskX * wellMaskY, 0.0f, 1.0f);

    // Base aluminum topcase (Space Gray specular sheen) illuminated by screen light
    float3 topcaseCol = float3(0.065f, 0.067f, 0.075f);
    topcaseCol += screenRadiance * float3(0.32f, 0.32f, 0.36f) * screenLightIntensity;
    float grainIntensity = 0.008f * max(1.0f - depthBlur * 0.8f, 0.0f);
    topcaseCol += float3(grainIntensity) * sin(X * 380.0f);

    // Trackpad region (foreshortened wide rectangle centered in front of keyboard)
    float tpBottom = wellTop + 0.015f;
    float tpTop = min(tpBottom + 0.085f * tilt, maxReach);
    if (vY >= tpBottom - 0.02f && vY <= tpTop + 0.02f && abs(X) <= 0.20f) {
        float tpH = (tpTop - tpBottom) * 0.5f;
        float2 tpD = abs(float2(X, vY - (tpBottom + tpTop) * 0.5f)) - float2(0.165f - 0.006f, tpH - 0.006f);
        float tpDist = length(max(tpD, 0.0f)) + min(max(tpD.x, tpD.y), 0.0f) - 0.006f;
        float tpBorderWidth = mix(0.003f, 0.025f, clamp(depthBlur, 0.0f, 2.0f));
        float tpBorder = smoothstep(tpBorderWidth, 0.0f, abs(tpDist));
        float3 tpColor = float3(0.072f, 0.074f, 0.082f) + screenRadiance * float3(0.40f, 0.40f, 0.44f) * screenLightIntensity;
        topcaseCol = mix(topcaseCol, tpColor + float3(0.18f) * tpBorder, tpBorder * 0.8f);
    }

    // --- 2. Keycaps and Backlight Matrix ---
    float3 wellColor = float3(0.024f, 0.024f, 0.028f);

    const int numRows = 6;
    float rowInterval = (wellTop - wellBottom);
    float relProgress = clamp((vY - wellBottom) / rowInterval, 0.0f, 1.0f);
    float warpedRow = pow(relProgress, 0.88f) * float(numRows);
    int rowIndex = clamp(int(floor(warpedRow)), 0, numRows - 1);

    // Compute row bounds in vY space
    float rowNorm0 = pow(float(rowIndex) / float(numRows), 1.0f / 0.88f);
    float rowNorm1 = pow(float(rowIndex + 1) / float(numRows), 1.0f / 0.88f);
    float rowY0 = wellBottom + rowNorm0 * rowInterval;
    float rowY1 = wellBottom + rowNorm1 * rowInterval;
    float rowH = (rowY1 - rowY0);

    // Row depth blur factor:
    // Row 0 = 0.0 (sharpest), Row 5 = 1.0+ (heavily blurred)
    float rowDepthT = float(rowIndex) / 5.0f;
    float rowBlur = pow(rowDepthT, 1.3f) * clamp(uniforms.keyboardDepthBlur, 0.0f, 3.0f);

    // Dynamic optical blur radius for keycap edges:
    // Row 0 has subpixel anti-aliased edge (0.0007f).
    // Row 5 softens by up to 0.035f so edges melt and blend smoothly into neighbors.
    float keyEdgeBlur = mix(0.0007f, 0.035f, rowBlur);

    // High-frequency contrast attenuation:
    // When objects go out of focus, high-frequency spatial variation decays exponentially.
    float gridContrast = exp(-pow(rowBlur * 1.5f, 2.0f));

    // Normalized coordinates across keyboard well
    float normU = clamp((X - wellLeft) / wellWidth, 0.0f, 1.0f);
    float relV = clamp((vY - rowY0) / rowH, 0.0f, 1.0f);

    // Exact key geometry lookup from MacBook reference layout
    KeyGeometry geo = getKeyGeometry(rowIndex, normU, relV);

    if (!geo.isKey) {
        // Empty aluminum cutout (e.g. above Left/Right inverted-T arrows)
        wellColor = topcaseCol;
    } else {
        float keyCenterX = wellLeft + geo.centerU * wellWidth;
        float keyHalfW = geo.halfWU * wellWidth;
        float keyCenterY = rowY0 + geo.centerV * rowH;
        float keyHalfH = geo.halfHV * rowH;

        // Keycap corner fillet radius (larger on outer corners of the keyboard well)
        float radius = mix(0.0035f, 0.007f, rowBlur);
        if (geo.isOuterCorner) {
            radius = mix(0.0055f, 0.009f, rowBlur);
        }

        // Distance to rounded keycap rectangle
        float2 d = abs(float2(X - keyCenterX, vY - keyCenterY)) - float2(keyHalfW - radius, keyHalfH - radius);
        float dist = length(max(d, 0.0f)) + min(max(d.x, d.y), 0.0f) - radius;

        // 1. Soft Keycap Mask:
        float rawKeyMask = smoothstep(keyEdgeBlur, -keyEdgeBlur, dist);
        float keyMask = mix(0.5f, rawKeyMask, gridContrast);

        // 2. Reversed Dish Shading & Crisp Specular Glint:
        // Sharp, defined specular glint focused on the bevel edge facing the display hinge
        float bevelStart = mix(keyHalfH * 0.78f, keyHalfH * 0.92f, rowBlur);
        float bevelEnd = keyHalfH * 0.99f;
        float edgeGlintRaw = smoothstep(bevelStart, bevelEnd, -(vY - keyCenterY));
        float edgeGlint = pow(edgeGlintRaw, 2.2f) * (1.0f - 0.55f * rowBlur);
        
        // Gracefully taper at the rounded lateral corners
        float cornerFade = smoothstep(keyHalfW, keyHalfW * 0.65f, abs(X - keyCenterX));
        edgeGlint *= cornerFade;

        float dishShading = 1.0f - mix(0.18f, 0.04f, rowBlur) * length(float2((X - keyCenterX) / keyHalfW, (vY - keyCenterY) / keyHalfH));
        float bevelSlope = 1.0f + 0.10f * clamp(-(vY - keyCenterY) / keyHalfH, -1.0f, 1.0f);
        
        // Keycap color: matte black base plastic + diffuse screen illumination + sharp specular edge glint
        float3 basePlastic = float3(0.055f, 0.056f, 0.062f) * dishShading * bevelSlope;
        float3 keyCapDiffuse = basePlastic + screenRadiance * float3(0.22f, 0.22f, 0.25f) * screenLightIntensity;
        float3 keyCapSpecular = screenLightDirect * (edgeGlint * 0.55f) * screenLightIntensity;
        float3 keyCap = keyCapDiffuse + keyCapSpecular;

        // Distinct Touch ID sensor key:
        // A clean, compact matte black key with a subtle, dark recessed circular sensor ring.
        // It has NO backlight glow and NO printed legend (matches authentic Apple hardware).
        if (geo.isTouchId) {
            float physAspect = 0.80f / max(tilt, 0.10f);
            float2 localCoord = float2(X - keyCenterX, (vY - keyCenterY) * physAspect);
            float keyRadius = min(keyHalfW, keyHalfH * physAspect);
            float circleR = keyRadius * 0.58f;
            float ringDist = abs(length(localCoord) - circleR);
            float ring = smoothstep(mix(0.0012f, 0.0030f, rowBlur), 0.0f, ringDist);
            float inSensor = smoothstep(0.0f, -0.002f, length(localCoord) - circleR);

            // Darker sapphire sensor surface inside the ring
            keyCap = mix(keyCap, float3(0.022f, 0.022f, 0.025f), inSensor);
            // Subtle dark chamfer groove (darker than keycap, NOT bright glowing white)
            keyCap = mix(keyCap, float3(0.015f, 0.015f, 0.018f), ring);
        }

        // Tactile raised homing bars on 'F' and 'J' keys
        if (geo.hasHomingBump) {
            float bumpY = keyCenterY - keyHalfH * 0.55f;
            float bumpDist = length(max(abs(float2(X - keyCenterX, vY - bumpY)) - float2(0.0045f, 0.0009f), 0.0f));
            float bump = smoothstep(mix(0.0014f, 0.004f, rowBlur), 0.0f, bumpDist);
            keyCap += float3(0.14f) * bump * (1.0f - 0.7f * rowBlur);
        }

        // Caps Lock LED status dot indicator
        if (geo.hasCapsDot) {
            float dotX = keyCenterX - keyHalfW * 0.65f;
            float dotY = keyCenterY + keyHalfH * 0.35f;
            float dotDist = length(float2(X - dotX, vY - dotY));
            float dot = smoothstep(mix(0.0025f, 0.0055f, rowBlur), 0.0f, dotDist);
            keyCap = mix(keyCap, float3(0.22f, 0.88f, 0.38f) * uniforms.keyboardBacklight, dot * (1.0f - 0.4f * rowBlur));
        }

        // 3. Illuminated key legend diffusion (Touch ID key is blank):
        if (!geo.isTouchId) {
            float legDiffusion = 1.0f + 3.5f * rowBlur;
            float legSpread = 3.5f / legDiffusion;
            float legX = (X - keyCenterX) / (keyHalfW * 0.50f);
            float legY = (vY - keyCenterY) / (keyHalfH * 0.65f);
            float legendBrightness = (0.32f / legDiffusion) * uniforms.keyboardBacklight * mix(1.0f, 0.40f, rowDepthProgress);
            float legend = exp(-(legX * legX + legY * legY) * legSpread) * legendBrightness;
            keyCap += float3(0.85f, 0.90f, 1.0f) * legend;
        }

        // 4. Perimeter backlight glow dispersal (Touch ID key is not backlit):
        // Significantly reduced opacity for a soft, subtle, realistic key perimeter glow
        float glowBrightness = geo.isTouchId ? 0.0f : clamp(uniforms.keyboardBacklight, 0.0f, 2.5f) * 0.35f * mix(1.0f, 0.35f, rowDepthProgress);
        float glowSpread = mix(500.0f, 85.0f, clamp(rowBlur, 0.0f, 1.0f));
        float glow = exp(-max(dist, 0.0f) * glowSpread) * glowBrightness;
        float3 backlight = float3(0.82f, 0.88f, 0.96f) * 0.45f;
        
        // Crevice ambient occlusion: key wells are naturally shaded from direct overhead screen light
        float creviceAO = mix(0.40f, 1.0f, keyMask);
        float3 wellGlow = mix(float3(0.024f, 0.024f, 0.028f) * creviceAO, backlight, glow);

        // Keycaps blend with backlight well based on the blurred optical mask
        wellColor = mix(wellGlow, keyCap, keyMask);
    }

    // Smoothly combine well with surrounding topcase using the soft feathered wellMask
    float3 col = mix(topcaseCol, wellColor, wellMask);

    // Distance falloff from hinge upward: quadratic decay ensures natural optical light attenuation
    float distanceFalloff = pow(max(1.0f - normY, 0.0f), 1.6f) * forwardFalloff;

    // Lateral reflection falloff on screen edges to prevent any hard screen edge cuts
    float lateralFalloff = smoothstep(0.0f, 0.04f, finalUV.x) * smoothstep(1.0f, 0.96f, finalUV.x);

    // Angle Opacity Envelope:
    // Active range is 45° to 90°:
    // - Opacity is 0 at 90° (upright) and 0 at 45° (and below 45°)
    // - Smoothly peaks at 1.0 (normal full opacity) in the middle of this range (~60° to 75°)
    float angleNorm = clamp((currentTheta - minAngleRad) / (uprightRad - minAngleRad), 0.0f, 1.0f);
    float sinAngle = sin(angleNorm * 3.14159265f);
    float angleEnvelope = smoothstep(0.0f, 1.0f, clamp(sinAngle * 1.25f, 0.0f, 1.0f));

    // Total reflection alpha modulated by row-by-row depth opacity falloff and angle envelope
    float alpha = distanceFalloff * rowOpacity * lateralFalloff * angleEnvelope * (1.0f - uniforms.settleProgress);
    return float4(col, alpha);
}

static inline float fastHash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

// MARK: - Frosted Glass Grain Pattern Synthesizer
struct FrostedGrainResult {
    float height;        // Surface relief height (0.0 to 1.0)
    float2 gradient;     // Surface normal perturbation (for light reflection & refraction)
    float microSparkle;  // High-frequency silica / crystalline glint
};

static FrostedGrainResult sampleFrostedGlassGrain(float2 uv, float aspect) {
    FrostedGrainResult result;

    // Isotropic coordinates so grain pattern has uniform physical aspect on screen
    // Scale 180 means ~180 grain clusters vertically, giving tactile ~8-14 pixel cellular grain on screen
    float2 p = uv * float2(aspect * 360.0f / 1.5, 360.0f / 1.5);
    float2 ip = floor(p);
    float2 fp = fract(p);

    float minDist = 10.0f;
    float2 bestDiff = float2(0.0f);

    // 3x3 Worley / cellular search to generate distinct acid-etched glass pits and grain boundaries
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            float2 g = float2(float(x), float(y));
            // Stable pseudorandom facet center
            float2 cellCoord = ip + g;
            float3 p3 = fract(float3(cellCoord.xyx) * float3(0.1031f, 0.1030f, 0.0973f));
            p3 += dot(p3, p3.yzx + 33.33f);
            float2 jitter = fract((p3.xx + p3.yz) * p3.zy);

            float2 diff = g + jitter - fp;
            float d = length(diff);
            if (d < minDist) {
                minDist = d;
                bestDiff = diff;
            }
        }
    }

    // Cell facet profile: distinct concave pit with raised rounded grain borders
    float cellFacet = 1.0f - clamp(minDist, 0.0f, 1.0f);
    // Analytical gradient of distance field for refraction & lighting normals
    float2 cellGrad = -bestDiff / max(minDist, 0.001f);

    // Secondary medium grain layer (rotated and offset for natural organic variation)
    float2 pMed = uv * float2(aspect * 760.0f / 1.5, 760.0f / 1.5);
    float2 ipMed = floor(pMed);
    float2 fpMed = fract(pMed);
    float medHash = fastHash21(ipMed);
    float medGrain = medHash * (1.0f - length(fpMed - 0.5f) * 1.4f);

    // Tertiary high-frequency crystal sparkle (sandblasted quartz glitter)
    float2 pSparkle = uv * float2(aspect * 1900.0f / 1.5, 1900.0f / 1.5);
    float sparkle = fastHash21(pSparkle);

    // Composite height and analytical gradient
    result.height = clamp(cellFacet * 0.70f + medGrain * 0.30f, 0.0f, 1.0f);
    result.gradient = cellGrad;
    result.microSparkle = sparkle;

    return result;
}

// MARK: - Blurred Drop Shadow Synthesizer for Digital Clock & Widgets
inline float sampleClockOccupancy(texture2d<float> tex, sampler smp, float2 uv) {
    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f) {
        return 0.0f;
    }
    float a = tex.sample(smp, uv).a;
    // Continuous perceptual alpha mapping: translucent widget cards (alpha ~0.36) cast
    // a soft, refined shadow, while opaque elements (clock hands, text) cast a firm shadow.
    // Avoid hard binarization steps which cause stepped ghost silhouettes.
    return pow(clamp(a, 0.0f, 1.0f), 0.75f);
}

static float sampleClockShadow(float2 clockUV,
                               texture2d<float> clockTexture,
                               sampler textureSampler,
                               float tiltAmount,
                               float headX) {
    // Optical drop shadow direction: light is overhead and slightly in front.
    // In perspective, as the screen tilts back, the shadow projects slightly down the screen plane.
    float shadowOffsetY = mix(0.005f, 0.015f, tiltAmount);
    // Subtle lateral parallax offset responding to head tracking position
    float shadowOffsetX = -headX * 0.003f;
    float2 shadowOffset = float2(shadowOffsetX, shadowOffsetY);

    float2 centerUV = clockUV - shadowOffset;

    // Quick bounds check with safety margin for blur footprint
    if (centerUV.x < -0.10f || centerUV.x > 1.10f || centerUV.y < -0.10f || centerUV.y > 1.10f) {
        return 0.0f;
    }

    float2 texStep = float2(1.0f / max(float(clockTexture.get_width()), 1.0f),
                            1.0f / max(float(clockTexture.get_height()), 1.0f));

    // Dynamic blur radius in texels: tight contact core scaling smoothly with tilt
    float blurRadius = mix(24.0f, 40.0f, tiltAmount);

    // Vogel spiral (golden-angle) sampling distribution:
    // Every sample is at a unique radius and angle, completely eliminating
    // concentric ring banding and stepped ghost silhouettes.
    const float2 vogelOffsets[16] = {
        float2( 0.1768f,  0.0000f),
        float2(-0.2258f,  0.2068f),
        float2( 0.0345f, -0.3938f),
        float2( 0.2869f,  0.3703f),
        float2(-0.4907f, -0.1983f),
        float2( 0.4071f, -0.4208f),
        float2(-0.0631f,  0.6339f),
        float2(-0.3807f, -0.5732f),
        float2( 0.6877f,  0.2185f),
        float2(-0.6402f,  0.4191f),
        float2( 0.2289f, -0.7766f),
        float2( 0.3541f,  0.7709f),
        float2(-0.7675f, -0.4357f),
        float2( 0.8123f, -0.4124f),
        float2(-0.4328f,  0.8661f),
        float2(-0.1996f, -0.9634f)
    };

    // Center tap anchors contact shadow
    float centerVal = sampleClockOccupancy(clockTexture, textureSampler, centerUV);
    float totalWeight = 1.5f;
    float accum = centerVal * 1.5f;

    // Convolve with quadratic falloff (1 - r^2) ensuring C0/C1 continuity at blur perimeter
    for (int i = 0; i < 16; ++i) {
        float rSq = (float(i) + 0.5f) * (1.0f / 16.0f);
        float w = 1.0f - rSq;
        float2 sampleUV = centerUV + vogelOffsets[i] * (texStep * blurRadius);
        accum += sampleClockOccupancy(clockTexture, textureSampler, sampleUV) * w;
        totalWeight += w;
    }

    float shadowVal = accum / totalWeight;
    return clamp(shadowVal, 0.0f, 1.0f);
}

// MARK: - Progressive Optical Defocus & Native Variable Blur
// Eliminates linear cross-dissolve/fading artifacts by dynamically convolving across
// multi-scale frequency bands (LODs) and expanding the Circle of Confusion (CoC) radius,
// seamlessly transitioning into deep Gaussian blur with native Apple vibrancy preservation.
static float4 sampleProgressiveBlur(texture2d<float> sharpTex,
                                    texture2d<float> blurredTex,
                                    sampler smp,
                                    float2 uv,
                                    float blurAmount,
                                    float2 texStep,
                                    float2 chromaticOffset = float2(0.0f)) {
    // 0. Early exit for perfectly sharp content
    if (blurAmount <= 0.0005f) {
        return sharpTex.sample(smp, uv, level(0.0f));
    }

    // Normalized progress with perceptual S-curve response
    float b = clamp(blurAmount, 0.0f, 1.0f);

    // Dynamic Circle of Confusion (CoC) radius in texels:
    // Expands smoothly from 0 -> ~36 texels
    float cocRadius = pow(b, 1.25f) * 36.0f;
    
    // Hardware mipmap level for anti-aliased multi-scale frequency attenuation
    float lod = clamp(log2(1.0f + cocRadius * 0.75f), 0.0f, 5.0f);

    // Center tap
    float centerWeight = 1.2f;
    float4 accum;
    if (dot(chromaticOffset, chromaticOffset) > 0.0000001f) {
        float rCh = sharpTex.sample(smp, uv + chromaticOffset, level(lod)).r;
        float gCh = sharpTex.sample(smp, uv, level(lod)).g;
        float bCh = sharpTex.sample(smp, uv - chromaticOffset, level(lod)).b;
        float aCh = sharpTex.sample(smp, uv, level(lod)).a;
        accum = float4(rCh, gCh, bCh, aCh) * centerWeight;
    } else {
        accum = sharpTex.sample(smp, uv, level(lod)) * centerWeight;
    }
    float totalWeight = centerWeight;

    // 12-tap Vogel / Fibonacci spiral distribution for optimal 2D Poisson-disc spatial uniformity
    // (Aperture-conformed Circle of Confusion)
    const float GOLDEN_ANGLE = 2.39996323f;
    const int NUM_TAPS = 12;

    for (int i = 0; i < NUM_TAPS; ++i) {
        float theta = float(i) * GOLDEN_ANGLE;
        float r = sqrt((float(i) + 0.5f) / float(NUM_TAPS));
        float2 dir = float2(cos(theta), sin(theta));
        float2 tapUV = uv + dir * (r * cocRadius * texStep);
        float w = exp(-r * r * 2.0f);

        if (dot(chromaticOffset, chromaticOffset) > 0.0000001f) {
            float rCh = sharpTex.sample(smp, tapUV + chromaticOffset, level(lod)).r;
            float gCh = sharpTex.sample(smp, tapUV, level(lod)).g;
            float bCh = sharpTex.sample(smp, tapUV - chromaticOffset, level(lod)).b;
            float aCh = sharpTex.sample(smp, tapUV, level(lod)).a;
            accum += float4(rCh, gCh, bCh, aCh) * w;
        } else {
            accum += sharpTex.sample(smp, tapUV, level(lod)) * w;
        }
        totalWeight += w;
    }

    float4 opticalBlur = accum / max(totalWeight, 0.0001f);

    // As blur amount reaches medium-to-deep levels (b > 0.20), smoothly blend into
    // the pre-filtered deep Gaussian blur (sigma=40) to provide ultra-clean, noise-free
    // large-aperture diffusion without undersampling artifacts.
    float deepTransition = smoothstep(0.20f, 0.75f, b);
    float4 deepColor;
    if (dot(chromaticOffset, chromaticOffset) > 0.0000001f) {
        float r = blurredTex.sample(smp, uv + chromaticOffset).r;
        float g = blurredTex.sample(smp, uv).g;
        float bCol = blurredTex.sample(smp, uv - chromaticOffset).b;
        deepColor = float4(r, g, bCol, 1.0f);
    } else {
        deepColor = blurredTex.sample(smp, uv);
    }

    float4 result = mix(opticalBlur, deepColor, deepTransition);

    // Native Apple Material Vibrancy:
    // Preserves luminance, saturation, and contrast so blurred backdrops remain rich and lively
    float luma = dot(result.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    float vibrancy = 1.0f + 0.16f * smoothstep(0.08f, 0.75f, b);
    result.rgb = mix(float3(luma), result.rgb, vibrancy);

    return result;
}

fragment float4 fragment_main(RasterizerData in [[stage_in]],
                              texture2d<float> screenTexture [[texture(0)]],
                              texture2d<float> blurredTexture [[texture(1)]],
                              texture2d<float> calibratorTexture [[texture(2)]],
                              texture2d<float> clockTexture [[texture(3)]],
                              sampler textureSampler [[sampler(0)]],
                              constant PerspectiveUniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.texCoords;

    const float uprightRad = 1.5707963f; // 90° in radians
    const float minReflectAngleRad = 0.7853982f; // 45° in radians
    
    // When settleProgress > 0, smoothly blend angle towards upright 90° (flat)
    float targetAngle = mix(uniforms.angle, uprightRad, clamp(uniforms.settleProgress, 0.0f, 1.0f));
    float currentTheta = min(targetAngle, uprightRad);
    float delta = uprightRad - currentTheta;

    float2 screenTexStep = float2(1.0f / max(float(screenTexture.get_width()), 1.0f),
                                  1.0f / max(float(screenTexture.get_height()), 1.0f));

    // Upright at 90° or wider, or settled: render flat and completely sharp edge-to-edge
    if (delta <= 0.0001f || uniforms.settleProgress >= 0.999f) {
        float4 base = screenTexture.sample(textureSampler, uv);
        if (uniforms.transitionBlur > 0.001f) {
            base = sampleProgressiveBlur(screenTexture, blurredTexture, textureSampler, uv, uniforms.transitionBlur, screenTexStep);
        }
        if (uniforms.showCalibrator > 0.5f) {
            float4 calib = calibratorTexture.sample(textureSampler, uv);
            base.rgb = base.rgb * (1.0f - calib.a) + calib.rgb;
        }
        if (uniforms.showClock > 0.5f && uniforms.clockProgress > 0.001f) {
            float dimFactor = mix(1.0f, 0.52f, uniforms.clockProgress);
            base.rgb *= dimFactor;

            // Very blurred drop & ambient shadow cast underneath the clock onto the screen surface
            float shadowVal = sampleClockShadow(uv, clockTexture, textureSampler, 0.0f, 0.0f);
            float shadowAmount = shadowVal * 0.35f * uniforms.shadowIntensity * uniforms.clockProgress;
            base.rgb *= (1.0f - shadowAmount);

            float4 clockPixel = clockTexture.sample(textureSampler, uv);
            if (clockPixel.a > 0.01f) {
                float2 texStep = float2(1.0f / max(float(clockTexture.get_width()), 1.0f),
                                        1.0f / max(float(clockTexture.get_height()), 1.0f));
                float aL = clockTexture.sample(textureSampler, uv - float2(texStep.x * 2.5f, 0.0f)).a;
                float aR = clockTexture.sample(textureSampler, uv + float2(texStep.x * 2.5f, 0.0f)).a;
                float aT = clockTexture.sample(textureSampler, uv - float2(0.0f, texStep.y * 2.5f)).a;
                float aB = clockTexture.sample(textureSampler, uv + float2(0.0f, texStep.y * 2.5f)).a;
                float2 glassNormal2D = float2(aR - aL, aB - aT);

                // Optical liquid glass refraction
                float2 refractOffset = glassNormal2D * 0.020f;
                float2 refractUV = clamp(uv - refractOffset, 0.0f, 1.0f);
                float4 refBlur = sampleProgressiveBlur(screenTexture, blurredTexture, textureSampler, refractUV, 0.35f, screenTexStep);
                float3 glassBg = refBlur.rgb;

                // Subtle chromatic dispersion
                glassBg.r = mix(glassBg.r, screenTexture.sample(textureSampler, clamp(refractUV - glassNormal2D * 0.003f, 0.0f, 1.0f)).r, 0.35f);
                glassBg.b = mix(glassBg.b, screenTexture.sample(textureSampler, clamp(refractUV + glassNormal2D * 0.003f, 0.0f, 1.0f)).b, 0.35f);

                // Specular meniscus highlight
                float rimGrad = length(glassNormal2D);
                float3 N = normalize(float3(-glassNormal2D * 1.8f, 1.0f));
                float3 L = normalize(float3(0.0f, -0.7f, 0.7f));
                float spec = pow(max(dot(N, L), 0.0f), 10.0f) * 0.28f;
                float rim = smoothstep(0.12f, 0.65f, rimGrad) * 0.22f;

                float3 liquidGlassColor = mix(glassBg, clockPixel.rgb, 0.62f) + float3(spec + rim);
                float clockAlpha = clockPixel.a * uniforms.clockProgress;
                base.rgb = mix(base.rgb, liquidGlassColor, clockAlpha);
            }
        }
        return base;
    }

    // Smooth transition envelope as angle begins closing (smoothly ramps from 0.0 to 1.0 by ~86°)
    float transitionProgress = smoothstep(0.0f, 0.07f, delta);

    float tiltAmount = sin(delta) * transitionProgress;
    float s = 1.0f - uv.y; // 0.0 at bottom hinge, 1.0 at top bezel

    // Progressive low-angle dual compensation (engages below ~80° down to 0°):
    // Simultaneously increases horizontal keystone taper and decreases vertical
    // stretch balance as the lid angle closes toward 0°.
    const float lowAngleOnsetRad = 1.3963f; // ~80° in radians
    float lowAngleKeystoneBoost = 1.0f;
    float lowAngleStretchMultiplier = 1.0f;
    float lowAngleShearBoost = 1.0f;

    if (currentTheta < lowAngleOnsetRad) {
        float lowAngleProgress = clamp((lowAngleOnsetRad - currentTheta) / lowAngleOnsetRad, 0.0f, 1.0f);

        // Dynamically modulate low-angle compensation based on 3D face position:
        // - Eye elevation (headY): Looking down from higher up (headY > 0) reduces oblique foreshortening,
        //   so taper compensation is reduced. Viewing from lower down (headY < 0) grazes the screen plane,
        //   requiring stronger keystone expansion.
        // - Distance (headZ): Closer viewing (headZ < 1.0) increases near-field convergence.
        float faceElevationMod = 1.0f - (uniforms.headY * 0.40f);
        float faceDistanceMod = clamp(1.0f / max(uniforms.headZ, 0.4f), 0.6f, 1.6f);
        float faceAdaptedComp = uniforms.lowAngleCompensation * mix(1.0f, faceElevationMod * faceDistanceMod, uniforms.headTrackingActive);
        float compFactor = clamp(faceAdaptedComp, 0.0f, 2.5f);

        // Keystone taper ramps up smoothly below 80°
        lowAngleKeystoneBoost += compFactor * (0.8f * lowAngleProgress + 0.6f * lowAngleProgress * lowAngleProgress);
        // Stretch balance drops smoothly below 80°
        lowAngleStretchMultiplier -= (1.8f * compFactor) * lowAngleProgress;

        // Enhanced off-axis shear at low angles (receding screen top)
        lowAngleShearBoost += (0.45f * lowAngleProgress) * uniforms.headTrackingActive;
    }

    // Scale effects by transitionProgress and settleFactor
    float settleFactor = 1.0f - clamp(uniforms.settleProgress, 0.0f, 1.0f);

    // Frosted glass intensity
    float frostAmount = clamp(uniforms.frostedGlass, 0.0f, 1.0f) * transitionProgress * settleFactor;

    // Evaluate frosted grain directly ON THE SCREEN (in screen space uv, NOT projected)
    FrostedGrainResult screenGrain;
    float2 grainRefract = float2(0.0f);
    if (frostAmount > 0.001f) {
        screenGrain = sampleFrostedGlassGrain(uv, uniforms.aspect);
        grainRefract = screenGrain.gradient * (0.0055f * frostAmount);
    }

    // Physical screen glass refracts incoming light rays before perspective projection
    float2 effectiveScreenUV = uv + grainRefract;

    // 1. Perspective Depth Coordinate Warping & Head-Tracked Off-Axis Projection
    float distanceMod = mix(1.0f, clamp(1.0f / max(uniforms.headZ, 0.5f), 0.6f, 1.8f), uniforms.headTrackingActive);
    float effectiveKeystone = uniforms.keystoneStrength * transitionProgress * lowAngleKeystoneBoost * distanceMod;
    float hYMod = 1.0f + uniforms.headY * 0.25f * uniforms.headElevationSensitivity * uniforms.headTrackingActive;
    float effectiveStretch = max(uniforms.stretchBalance * lowAngleStretchMultiplier * hYMod, 0.01f);
    float w = max(1.0f - (s * tiltAmount * effectiveKeystone), 0.05f);

    // Off-axis lateral shear from head tracking (0 at bottom hinge s=0, maximum at top s=1)
    float offAxisShearX = -uniforms.headX * (s * tiltAmount * 0.38f * uniforms.headParallaxSensitivity * lowAngleShearBoost) * uniforms.headTrackingActive;

    float warpedX = ((effectiveScreenUV.x - 0.5f + offAxisShearX) / w) + 0.5f;
    float warpedY = 1.0f - (s * (1.0f - (tiltAmount * (1.0f - effectiveStretch))) / w);
    float2 finalUV = float2(warpedX, warpedY);

    // Clean perspective projection coordinates (without grain refraction) for UI elements like Calibrator
    float cleanWarpedX = ((uv.x - 0.5f + offAxisShearX) / w) + 0.5f;
    float2 cleanPerspectiveUV = float2(cleanWarpedX, warpedY);

    // 2. Traveling Focus Wavefront Math
    const float minAngleRad = 60.0f * (3.14159265f / 180.0f); // ~60°
    const float maxAngleRad = 90.0f * (3.14159265f / 180.0f); // ~90°
    
    // Normalized open progress (0.0 when nearly closed, 1.0 when upright)
    float openProgress = clamp((targetAngle - minAngleRad) / (maxAngleRad - minAngleRad), 0.0f, 1.0f);
    float smoothProgress = smoothstep(0.0f, 1.0f, openProgress);

    // The focus horizon sweeps upward from below the screen (-0.35) to above the top (4.0)
    float focusLine = mix(-0.35f, 4.0f, smoothProgress);
    float feather = 4.0f;
    float sweepFactor = smoothstep(focusLine - feather, focusLine + feather, s);
    float gradientIntensity = mix(0.8f, 2.0f, s);

    // Scale blur by transitionProgress, settleFactor, and blurIntensity
    float localBlur = clamp(sweepFactor * gradientIntensity * transitionProgress * settleFactor * uniforms.blurIntensity, 0.0f, 1.0f);

    // 3. Dynamic Silhouette Edge Bleed
    float edgeBleed = mix(0.003f, 0.040f, localBlur) * transitionProgress * settleFactor;

    // Determine if pixel is inside the tilted screen quad
    bool isInside = (finalUV.x >= -edgeBleed && finalUV.x <= (1.0f + edgeBleed) &&
                     finalUV.y >= -edgeBleed && finalUV.y <= (1.0f + edgeBleed));

    float4 frameColor = float4(0.0f, 0.0f, 0.0f, 1.0f);

    if (isInside) {
        // 4. Sample Content with Progressive Optical Blur & Frosted Glass Optical Model
        float effectiveBlurAmount = localBlur;
        if (uniforms.transitionBlur > 0.001f) {
            effectiveBlurAmount = max(effectiveBlurAmount, uniforms.transitionBlur);
        }

        if (frostAmount > 0.001f) {
            // Chromatic dispersion through screen-space grain facets
            float2 dispOffset = float2(0.0022f, 0.0012f) * frostAmount;
            float baseFrost = mix(0.40f, 0.88f, s) * frostAmount;
            float combinedBlur = clamp(max(effectiveBlurAmount, baseFrost * uniforms.blurIntensity), 0.0f, 1.0f);
            frameColor = sampleProgressiveBlur(screenTexture, blurredTexture, textureSampler, clamp(finalUV, 0.0f, 1.0f), combinedBlur, screenTexStep, dispOffset);
        } else {
            frameColor = sampleProgressiveBlur(screenTexture, blurredTexture, textureSampler, clamp(finalUV, 0.0f, 1.0f), effectiveBlurAmount, screenTexStep);
        }

        // 5. Progressive Depth Shadow (Delayed to <= 70°)
        const float shadowStartAngleRad = 70.0f * (3.14159265f / 180.0f);
        const float shadowFullAngleRad  = 30.0f * (3.14159265f / 180.0f);
        float shadowActivation = smoothstep(shadowStartAngleRad, shadowFullAngleRad, targetAngle);

        float maxShadowTop = 2.0f;
        float maxShadowBottom = 1.0f;
        float depthShadow = mix(maxShadowBottom, maxShadowTop, s);
        float shadowAmount = clamp(sweepFactor * depthShadow * shadowActivation * transitionProgress * settleFactor * uniforms.shadowIntensity, 0.0f, 1.0f);
        frameColor.rgb *= (1.0f - shadowAmount);

        // 6. Simulated Keyboard Reflection (Active exclusively between 45° and 90°)
        if (uniforms.keyboardReflection > 0.001f && delta > 0.0001f && uniforms.settleProgress < 0.999f && currentTheta > minReflectAngleRad) {
            float4 kbReflect = sampleKeyboardReflection(finalUV, delta, currentTheta, uniforms, blurredTexture, textureSampler);
            float refAlpha = clamp(kbReflect.a * uniforms.keyboardReflection, 0.0f, 0.85f);
            frameColor.rgb = frameColor.rgb * (1.0f - 0.25f * refAlpha) + kbReflect.rgb * refAlpha;
        }

        // 7. Seamless Silhouette Edge Mask
        float distLeft   = max(-finalUV.x, 0.0f);
        float distRight  = max(finalUV.x - 1.0f, 0.0f);
        float distTop    = max(-finalUV.y, 0.0f);
        float outsideDist = max(max(distLeft, distRight), distTop);
        float borderMask = (edgeBleed > 0.0001f) ? (1.0f - smoothstep(0.0f, edgeBleed, outsideDist)) : (outsideDist <= 0.0f ? 1.0f : 0.0f);
        frameColor.rgb *= borderMask;
    }

    // 8. SCREEN-SPACE Frosted Glass Optical Layer (Directly on physical screen, NOT projected)
    if (frostAmount > 0.001f) {
        // Surface normal of the screen-space etched grain facets
        float bumpFactor = 0.92f * frostAmount;
        float3 grainNormal = normalize(float3(-screenGrain.gradient.x * bumpFactor, -screenGrain.gradient.y * bumpFactor, 1.0f));

        // Directional illumination across the physical laptop screen
        float3 screenLight = normalize(float3(0.20f, 0.55f, 0.81f));
        float grainShading = dot(grainNormal, screenLight);

        // Tactile grain pattern directly on the screen: highlights on ridges, micro-shadows in etched pits
        float ridgeHighlight = pow(max(grainShading, 0.0f), 2.2f) * 0.32f * frostAmount;
        float pitShadow = smoothstep(0.65f, 0.15f, screenGrain.height) * 0.18f * frostAmount;
        float grainRelief = (screenGrain.height - 0.45f) * 0.28f * frostAmount;

        // Crystalline silica micro-sparkle directly on the screen
        float crystalGlint = pow(screenGrain.microSparkle, 18.0f) * 0.35f * frostAmount;

        // Diffuse milky translucent haze across the screen
        float3 milkyMist = float3(0.92f, 0.94f, 0.98f);
        float mistIntensity = (0.065f + 0.045f * (1.0f - screenGrain.height)) * frostAmount;
        frameColor.rgb = mix(frameColor.rgb, milkyMist, mistIntensity);

        // Apply physical grain pattern on the screen
        frameColor.rgb = frameColor.rgb + float3(grainRelief) + float3(ridgeHighlight - pitShadow) + float3(crystalGlint);

        // Subtle satin sheen across the physical screen
        float screenSheen = (0.05f + 0.10f * (1.0f - uv.y)) * tiltAmount * frostAmount * (0.8f + 0.4f * screenGrain.height);
        frameColor.rgb += float3(0.95f, 0.97f, 1.0f) * screenSheen;
    }

    // 9. Background Dimming for Clock Mode (Subtly darkens background quad for contrast)
    if (uniforms.clockProgress > 0.001f) {
        float dimFactor = mix(1.0f, 0.52f, uniforms.clockProgress);
        frameColor.rgb *= dimFactor;
    }

    // 10. Digital Perspective Liquid Glass Clock Overlay (Rendered in 3D perspective over the dimmed background)
    if (uniforms.showClock > 0.5f && uniforms.clockProgress > 0.001f) {
        // 10a. Very blurred drop & ambient shadow cast underneath the clock onto the tilted screen
        if (cleanPerspectiveUV.x >= -0.20f && cleanPerspectiveUV.x <= 1.20f &&
            cleanPerspectiveUV.y >= -0.20f && cleanPerspectiveUV.y <= 1.20f) {
            float headParallax = uniforms.headX * uniforms.headTrackingActive;
            float shadowVal = sampleClockShadow(cleanPerspectiveUV, clockTexture, textureSampler, tiltAmount, headParallax);
            float shadowAmount = shadowVal * 0.38f * uniforms.shadowIntensity * uniforms.clockProgress;
            frameColor.rgb *= (1.0f - shadowAmount);
        }

        // 10b. Liquid Glass Clock digits/widget in perspective
        if (cleanPerspectiveUV.x >= 0.0f && cleanPerspectiveUV.x <= 1.0f &&
            cleanPerspectiveUV.y >= 0.0f && cleanPerspectiveUV.y <= 1.0f) {
            float4 clockPixel = clockTexture.sample(textureSampler, cleanPerspectiveUV);
            if (clockPixel.a > 0.01f) {
                float2 texStep = float2(1.0f / max(float(clockTexture.get_width()), 1.0f),
                                        1.0f / max(float(clockTexture.get_height()), 1.0f));
                float aL = clockTexture.sample(textureSampler, cleanPerspectiveUV - float2(texStep.x * 2.5f, 0.0f)).a;
                float aR = clockTexture.sample(textureSampler, cleanPerspectiveUV + float2(texStep.x * 2.5f, 0.0f)).a;
                float aT = clockTexture.sample(textureSampler, cleanPerspectiveUV - float2(0.0f, texStep.y * 2.5f)).a;
                float aB = clockTexture.sample(textureSampler, cleanPerspectiveUV + float2(0.0f, texStep.y * 2.5f)).a;
                float2 glassNormal2D = float2(aR - aL, aB - aT);

                // Optical liquid glass refraction of the 3D-warped background behind the digits
                float2 refractOffset = glassNormal2D * 0.022f;
                float2 refractUV = clamp(finalUV - refractOffset, 0.0f, 1.0f);
                float4 refBlur = sampleProgressiveBlur(screenTexture, blurredTexture, textureSampler, refractUV, 0.35f, screenTexStep);
                float3 glassBg = refBlur.rgb;

                // Chromatic dispersion through curved meniscus
                glassBg.r = mix(glassBg.r, screenTexture.sample(textureSampler, clamp(refractUV - glassNormal2D * 0.003f, 0.0f, 1.0f)).r, 0.35f);
                glassBg.b = mix(glassBg.b, screenTexture.sample(textureSampler, clamp(refractUV + glassNormal2D * 0.003f, 0.0f, 1.0f)).b, 0.35f);

                // Specular skylight reflection on liquid glass meniscus
                float rimGrad = length(glassNormal2D);
                float3 N = normalize(float3(-glassNormal2D * 1.8f, 1.0f));
                float3 L = normalize(float3(0.0f, -0.7f, 0.7f));
                float spec = pow(max(dot(N, L), 0.0f), 10.0f) * 0.28f;
                float rim = smoothstep(0.12f, 0.65f, rimGrad) * 0.22f;

                float3 liquidGlassColor = mix(glassBg, clockPixel.rgb, 0.62f) + float3(spec + rim);
                float clockAlpha = clockPixel.a * uniforms.clockProgress;
                frameColor.rgb = mix(frameColor.rgb, liquidGlassColor, clockAlpha);
            }
        }
    }

    // 11. Calibrator Overlay in Perspective (Rendered over/on top of frosted glass and clock for crisp readability)
    if (uniforms.showCalibrator > 0.5f) {
        if (cleanPerspectiveUV.x >= 0.0f && cleanPerspectiveUV.x <= 1.0f &&
            cleanPerspectiveUV.y >= 0.0f && cleanPerspectiveUV.y <= 1.0f) {
            float4 calib = calibratorTexture.sample(textureSampler, cleanPerspectiveUV);
            frameColor.rgb = frameColor.rgb * (1.0f - calib.a) + calib.rgb;
        }
    }

    return frameColor;
}


