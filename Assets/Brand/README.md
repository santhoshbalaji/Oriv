# Oriv identity

The shipping mark is a quiet woven aperture: two balanced loops borrow the
symmetry and over-under rhythm of Tamil Nadu kolam without depicting a dot grid
or a literal ornamental pattern. The name remains Oriv.

- Plum background: `#652A3A`, dark appearance `#381925`.
- Warm porcelain foreground: `#FFF7ED`.
- Typography: the native San Francisco system family, matching the browser UI.
- Keep the icon as the single expressive element; navigation uses native controls.

`Oriv-Mark.svg` is editable vector artwork on an unmasked 1024-point canvas.
The shipping `Apps/macOS/Resources/AppIcon.icon` contains the same vector layer,
an independent system gradient, and default, dark and tinted appearance settings.
The system supplies corner masking and material rendering. The foreground
contains no raster texture, baked shadows, lighting, text or fine dot details.
`Oriv-Icon-Default.png` is an actual macOS rendition exported by Icon Composer.

Image-generation concepts were made with the built-in image generation tool;
the final small-size asset is constructed as precise native vector geometry.
The final concept prompt is in `concept-prompt.txt`. The raster concept is
retained as `Oriv-Kolam-Concept.png`; it is not bundled in the application.

Guidance followed: [Apple app icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
and [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
This is an implementation based on Apple's guidance, not Apple certification.
