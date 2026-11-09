// SPDX-License-Identifier: AGPL-3.0-only
#include <metal_stdlib>
using namespace metal;

// Shared with ExtremeLightRig: six float4 values, no platform-dependent padding.
struct LightParameters {
    float4 frame;       // time, sheet/projector index, screen width, intensity
    float4 left;
    float4 right;
    float4 top;
    float4 bottom;
    float4 behavior;    // source energy, motion scale, reduce motion, reserved
};
struct SheetVertex { packed_float3 position; packed_float3 normal; float2 uv; };

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f*f*(3.0-2.0*f);
    return mix(mix(hash21(i), hash21(i+float2(1,0)), f.x),
               mix(hash21(i+float2(0,1)), hash21(i+float2(1,1)), f.x), f.y);
}
float field(float2 p) {
    float value = .57*noise2(p);
    p = float2(1.62*p.x-1.18*p.y, 1.18*p.x+1.62*p.y) + 7.1;
    value += .28*noise2(p);
    p = float2(1.62*p.x-1.18*p.y, 1.18*p.x+1.62*p.y) + 13.4;
    return value + .15*noise2(p);
}
float2 flowWarp(float2 uv, float t, float seed) {
    float2 p = uv * float2(2.3, 3.1);
    // Smooth nested domain warping: coherent folds rather than per-frame noise.
    float2 q = float2(field(p + float2(-t*.10,seed)),
                      field(p + float2(seed+7.2,t*.07)));
    return uv + float2(.10,.21) * (q-.5);
}
float filamentField(float2 uv, float t, float seed) {
    float2 q = flowWarp(uv, t, seed);
    float fold = .12*sin(q.x*7.0-t*.24+seed)
               + .045*sin(q.x*17.0+t*.15+seed*2.0);
    float w = q.y + fold + .07*field(float2(q.x*4.0-t*.12,q.y*3.0+seed));
    // Irregular ridges break into small strands; there is no uniformly spaced
    // sine grating. Wider caustics and a faint body keep this a sheet of silk.
    float fine = pow(1.0-abs(2.0*noise2(float2(q.x*2.5-t*.06+seed,w*47.0))-1.0),9.0);
    float hair = pow(1.0-abs(2.0*noise2(float2(q.x*5.0+t*.04+seed+11.0,w*91.0))-1.0),16.0);
    float breakup = smoothstep(.18,.78,field(float2(q.x*3.1+seed,w*8.0-t*.05)));
    float ridgeA = (w-(.34+.10*sin(q.x*6.0-t*.13+seed)))*17.0;
    float ridgeB = (w-(.69+.08*sin(q.x*8.0+t*.11+seed)))*24.0;
    float broad = exp(-ridgeA*ridgeA)+.62*exp(-ridgeB*ridgeB);
    float body = .045+.08*field(float2(q.x*2.0+seed,w*6.0));
    return body+.48*broad+(.44*fine+.13*hair)*(.18+.82*breakup);
}
float3 cubic(float3 a, float3 b, float3 c, float3 d, float s) {
    float k=1.0-s; return k*k*k*a+3.0*k*k*s*b+3.0*k*s*s*c+s*s*s*d;
}
float3 centerline(float s, uint sheet) {
    if (sheet==0) return cubic(float3(-.53,-.20,-.11),float3(-1.13,.18,-.22),
                              float3(-.73,.74,.02),float3(.18,.38,-.17),s);
    if (sheet==1) return cubic(float3(.51,-.16,-.09),float3(1.00,.08,-.16),
                              float3(.85,.65,-.02),float3(1.43,.92,-.20),s);
    if (sheet==2) return cubic(float3(-.56,.31,-.16),float3(-.06,.65,-.25),
                              float3(.52,.43,-.10),float3(1.12,.44,-.20),s);
    return cubic(float3(-.51,-.31,-.13),float3(-.02,-.30,-.04),
                 float3(.48,-.91,.06),float3(.94,-.35,-.13),s);
}
float3 sheetPosition(float2 uv, uint sheet, constant LightParameters &p) {
    float s=uv.x, r=uv.y*2.0-1.0;
    float t=p.frame.x*p.behavior.y*(1.0-p.behavior.z);
    float3 c=centerline(s,sheet);
    float3 tangent=normalize(centerline(min(1.0,s+.002),sheet)-centerline(max(0.0,s-.002),sheet));
    float3 across=normalize(float3(-tangent.y,tangent.x,0));
    float envelope=pow(max(.0,sin(M_PI_F*s)),.65);
    float width=(sheet==2 ? .19 : .25)*(.20+.80*envelope);
    float bend=.035*sin(s*9.0-t*.23+float(sheet)*1.9)*envelope;
    c += across*bend;
    float3 position=c+across*(r*width);
    position.z += envelope*(.07*sin(s*10.0+r*2.5-t*.21+float(sheet))
                          +.032*sin(s*19.0-r*4.0+t*.17));
    // The picture stays clear even if its SwiftUI attachment is alpha-composited.
    // Inside the screen's XY rectangle the body remains well behind its plane.
    if (abs(position.x)<.53 && abs(position.y)<.315) position.z=min(position.z,-.16);
    return position*p.frame.z;
}
kernel void extremeSheetVertices(device SheetVertex *vertices [[buffer(0)]],
                                 constant LightParameters &p [[buffer(1)]],
                                 uint2 id [[thread_position_in_grid]]) {
    const uint columns=129, rows=41;
    if(id.x>=columns || id.y>=rows) return;
    float2 uv=float2(id)/float2(columns-1,rows-1);
    float3 position=sheetPosition(uv,uint(p.frame.y),p);
    float3 du=sheetPosition(float2(min(1.0,uv.x+.001),uv.y),uint(p.frame.y),p)
             -sheetPosition(float2(max(0.0,uv.x-.001),uv.y),uint(p.frame.y),p);
    float3 dv=sheetPosition(float2(uv.x,min(1.0,uv.y+.001)),uint(p.frame.y),p)
             -sheetPosition(float2(uv.x,max(0.0,uv.y-.001)),uint(p.frame.y),p);
    vertices[id.y*columns+id.x]={packed_float3(position),packed_float3(normalize(cross(du,dv))),uv};
}
float3 paletteAt(float x, uint sheet, constant LightParameters &p) {
    float3 c=mix(p.left.rgb,p.right.rgb,smoothstep(-.65,.65,x));
    if(sheet==2) c=mix(c,p.top.rgb,.27);
    if(sheet==3) c=mix(c,p.bottom.rgb,.24);
    // Preserve the game's hue and black level, with a bounded luminous exposure.
    return 1.0-exp(-max(c,float3(0))*3.4);
}
kernel void extremeSheetTexture(texture2d<half,access::write> target [[texture(0)]],
                                constant LightParameters &p [[buffer(0)]],
                                uint2 id [[thread_position_in_grid]]) {
    if(id.x>=target.get_width() || id.y>=target.get_height()) return;
    float2 uv=(float2(id)+.5)/float2(target.get_width(),target.get_height());
    uint sheet=uint(p.frame.y);
    float t=p.frame.x*p.behavior.y*(1.0-p.behavior.z);
    float seed=float(sheet)*4.13;
    float density=filamentField(uv,t,seed);
    float edge=pow(max(0.0,sin(M_PI_F*uv.y)),1.8);
    float ends=smoothstep(.0,.10,uv.x)*(1.0-smoothstep(.78,1.0,uv.x));
    float alpha=clamp(density*edge*ends*p.frame.w*p.behavior.x,.0,.82);
    float3 color=paletteAt(centerline(uv.x,sheet).x,sheet,p);
    float highlight=smoothstep(.45,.9,density)*.12;
    color=mix(color,float3(max(max(color.r,color.g),color.b)),highlight);
    target.write(half4(half3(color*1.55),half(alpha)),id);
}
kernel void extremeProjectionTexture(texture2d<half,access::write> target [[texture(0)]],
                                     constant LightParameters &p [[buffer(0)]],
                                     uint2 id [[thread_position_in_grid]]) {
    if(id.x>=target.get_width() || id.y>=target.get_height()) return;
    float2 uv=(float2(id)+.5)/float2(target.get_width(),target.get_height());
    float2 centered=uv*2.0-1.0;
    float falloff=pow(max(0.0,1.0-dot(centered,centered)),1.6);
    float t=p.frame.x*p.behavior.y*(1.0-p.behavior.z);
    float sheet=p.frame.y==0 ? 0 : (p.frame.y==1 ? 1 : 3);
    float2 sampleUV=float2(uv.y*.8+.1,uv.x*.8+.1);
    float texture=filamentField(sampleUV,t,sheet*4.13);
    float body=.12+.5*field(flowWarp(uv,t,sheet)*2.2);
    float3 color;
    if(p.frame.y==0) color=mix(p.left.rgb,p.top.rgb,uv.y*.25);
    else if(p.frame.y==1) color=mix(p.right.rgb,p.top.rgb,uv.y*.25);
    else color=mix(p.left.rgb,p.right.rgb,uv.x)*.6+p.bottom.rgb*.4;
    color=1.0-exp(-max(color,float3(0))*2.8);
    float energy=falloff*(body+.65*texture)*p.behavior.x*p.frame.w;
    target.write(half4(half3(color*energy),1),id);
}
