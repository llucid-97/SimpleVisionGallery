<!-- Target audience: humans and agents -->
# Evidence-grounded review rubric

The run ended at the06:00 WAT deadline on5 November2026. It recorded132 real score rows and **zero qualifying wins**. The original gate required every judge to prefer the candidate on the unchanged matched tasks for two consecutive rounds, with no unresolved substantial defect. A positive average is not that gate.

Selected complete pitch: Gallery07b, source`af50d861f7cf5a92fb486ea999a0515e52b76ae1492931e71cb6c243cced3b90`.

| Judge | Candidate matched mean | Apple Photos matched mean |
| --- | ---: | ---: |
| Opus5.5 | 8.108333 | 8.208333 |
| GPT6.1 Sol | 8.633333 | 7.950000 |
| GPT6.1 Terra | 8.066667 | 7.433333 |
| All9 matched task scores | 8.269444 | 7.863889 |

Opus still preferred Photos on its mean, so unanimity failed.07b was selected as the highest complete-pitch mean at the deadline, not declared a win. The three matched tasks remained Albums, Photos library and the Coastal native viewer. LastLight and the theme sample were parent-only supplements, not extra scores. Settings, Vault, overflow and paired viewing had standalone critiques without invented Photos counterparts.

The maintained score/evidence files are `workspaces/design-overhaul/dashboard/council_scores.jsonl` and `workspaces/design-overhaul/council-07/`. Keep exact revision, fixture, route, raw image and crop metadata with any future review. Do not compare a new render against an old score as if it were re-reviewed.

## Reuse the original scoring method

Rate each presented screen from1 to10. Preserve the original categories and weights:

| Category | Weight |
| --- | ---: |
| Legibility | 25% |
| Clear actions and hierarchy | 20% |
| Media prominence/fidelity, or relevant task content on non-media pages | 20% |
| Visual coherence | 15% |
| visionOS fit | 10% |
| Surface/overlay quality | 10% |

The overall screen score is the weighted sum. The matched experience gives equal weight to each unchanged matched task. Record raw category scores, overall score and three concrete pain points with image locations for BOTH candidate and comparator. Missing baselines are null, never zero; standalone pages do not increase the paired mean. Judge screenshots before implementation/rationale/earlier scores; source identity may remain recognizable, so call it theme-blind rather than fully identity-blind. Keep first ratings unchanged after synthesis.

A round qualifies only if all three judges' matched means are strictly above Photos on the same at-least-three-task set and no unresolved confirmed substantial visual/readability/navigation defect remains in any reviewed candidate page. Two consecutive qualifying rounds are required. Expected scroll clipping with clear continuation is not automatically a veto; hidden required content or a broken visible path may be. The parent records the decision and evidence. Reuse this method only with fresh, labelled evidence; do not assign the export sample its parent application's scores.

## Review questions

Use these as checks, not a new unregistered scoring formula:

- **Content first:** can the person see and identify the media or task? Controls must help without hiding content. Normal scroll clipping is distinct from an unreachable or unreadable control.
- **Hierarchy and space:** is the title/scope clear, with readable secondary text? Watch large empty lower bands and heavy repeated docks. Do not trade readable controls for a falsely minimal screen.
- **Actions:** does each icon/caption mean what it does, with distinct reachable targets and honest disabled/loading/selection states? Preserve the displayed item/session when actions mutate media.
- **Material and light:** check actual pixels for softened scene detail and sharp foreground text. Native glass plus tint must stay readable without becoming a pale slab. The shader is static surface lighting, not a simulation of a physical room.
- **Bounds:** inspect the whole viewport and close crops. Rounded layers must not leave rectangular backing slivers; blurred previews clip after effects. Popovers may cover local content, but raised native media must not obscure them.
- **Consistency:** the selected root must remain the same behind overlays. Use the same fixture/data/callback adapter in captures, and label inert mocks and native OS surfaces honestly.
- **Accessibility:** inspect reduced effects, real type-size fallback, search/clear/loading and disabled states. Contrast on one default token pair is not proof for arbitrary injected colors.
- **Native media safety:** retain suitable depth, forward clearance, fixed pair alignment, stable parallax/orientation and privacy covers. More context may use only matching flat previews; private or mutation covers override it.
- **Evidence quality:** an app PID, image file, synthetic replay, source proof or build is not a visual/runtime/hardware pass. Blank/cut frames stay failed or unknown and must be corrected with labelled same-source evidence.

## Findings retained at the deadline

Accepted improvements included labelled external navigation, compact actions, brighter search hints, an About footer that remains reachable, clearer Vault risk copy, removal of the redundant native-image matte, native glass that softens room detail, a smaller viewer gap, and More context without raised-media occlusion.

Limits remained: broad dark Albums space, heavy two-row dock/repeated pair chrome, small or icon-only controls, and the Settings scroll-edge fragment. Those are honest critiques, not permission for new design hill-climbing after the cutoff. Settings reachability evidence is a separate parent verification; a still alone cannot prove it. The exported primitives/sample have not been independently awarded the application scores.

The library pair used the same20 records from10 duplicated licensed sources; ordering/window pose differed. Albums/viewer primary references were historical960x540 WWDC frames with different content/OS, so those comparisons are weaker. LastLight's current Photos reference was supplemental and did not replace the primary baseline. No same-camera, current-OS Albums/viewer superiority is established.

Simulator mono stills do not prove generated stereo, spatial video, Photos permissions/mutations, memory/performance, VoiceOver, scrolling, dynamic motion, off-center parallax or physical headset comfort. Portrait camera framing and mixed-aspect/near-square cases remain limited or unknown. Reuse the theme's visual roles without inheriting claims that have not been tested in your host app.
