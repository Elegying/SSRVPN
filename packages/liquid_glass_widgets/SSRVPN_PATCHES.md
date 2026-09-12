# SSRVPN renderer patch

Upstream: https://pub.dev/packages/liquid_glass_widgets/versions/1.4.4
Original MIT license retained in LICENSE. Only runtime lib/ and shaders/ are vendored.

Local change: lib/src/renderer/rendering/liquid_glass_render_object.dart,
paintLiquidGlassWithCapture: use local logical coordinates for Canvas fragment
shaders, instead of physical screen coordinates required by ImageFilter.shader.
Background UV origin, geometry bounds, and optical thickness use matching units.
The live ImageFilter path and optical shader algorithms are unchanged.

App supplies one background-only texture per page, shared by premium surfaces.
Remove the override after an equivalent upstream fix passes device verification.

Capture draw bounds now use the caller's explicit expansion instead of an
unconditional 20x15px margin. The final shader emits transparent pixels outside
the geometry texture rather than extending edge texels into that margin. This
prevents card-edge streaks during horizontal navigation.

Materialize scope keeps its content wrappers mounted at rest and disables only
the zero-sigma filter. Removing wrappers at progress 1 remounted stateful forms
and diagnostics, resetting pending edits and repeating initial requests.

5.0.0 performance review:
- MultiShaderBuilder compares asset-key contents instead of list identities,
  retains shader instances across equal-key rebuilds, disposes owned instances,
  and rejects stale asynchronous loads after a key change/disposal.
- LiquidGlassLayer accepts opt-in captureOnly to retain the first-frame child
  subtree without touching a live backdrop before a capture is ready.
- SSRVPN capture is driven by actual wallpaper paints. Route translation updates
  sampling origins without reallocating unchanged full-resolution textures.
  Static/covered/reduced-motion wallpapers no longer run a capture ticker.
- Shared surface rebuilds are limited to the sampling layer; the glass geometry
  and content subtree are reused. Optical shader/settings are unchanged.
