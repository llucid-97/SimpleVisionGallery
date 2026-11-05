<!-- Target audience: humans and agents -->
# Design review: the 100th use

Review the app as someone who already knows it. Keep the next useful action easy to find; do not keep teaching the same action on every visit.

- Remove copy that repeats a nearby button, heading or obvious state. Keep first-use help in About/details or a dismissible notice where it is useful.
- Keep security/destructive confirmations, recovery instructions, errors and progress that change the decision. A dismissed general warning must not remove these safeguards.
- Check Albums for wasted opaque space, large clear covers, thin gutters and readable on-image names/counts. Keep selection, hover and context actions intact.
- Use contextual labels such as Sort when the Albums heading already supplies the object. Check real and mock labels together.
- Make Settings section headings clearly larger/heavier and indented from their rows. Check the rendered sheet, not just font declarations.
- Verify persistent dismissals across sheet reopen and app relaunch in an isolated test bundle. Unlock and needed recovery actions must remain.
- Inspect narrow width, large type, reduced effects and overlay states. Missing evidence is unknown; normal scroll continuation is different from hidden required controls.

Apply these checks on every relevant change, independently of the shared issue ranking. Shared issue keys include repeat-use-expository-overload, album-grid-dead-space and type-hierarchy.
