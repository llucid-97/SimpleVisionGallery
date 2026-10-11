<!-- Target audience: agents -->
# Simple Vision Gallery

Standalone visionOS photo gallery. Ordinary supported photos become spatial scenes automatically; users can open multiple media windows. Keep the PhotoKit gallery, bounded in-memory preparation, playlist ordering and native rendering contracts from SimpleVisionTools.

## Structure
`SimpleVisionGallery/` contains app code and resources. `resources/` holds shared source/release reference inputs. `docs/` holds user-facing design and release documents. `workspaces/<agent-name>/` is locally ignored scratch space; subagents inherit their parent workspace. New agent tests go in locally ignored `.codex-tests/`, never tracked product tests unless explicitly promoted in PR review.

## Coordination
Use one owned checkout per top-level agent; additional worktrees belong under that agent's workspace. Never overwrite another agent's uncommitted work. Main is the integration branch; the user has authorized private repository creation and pushes. Build/validate before pushing. Heavy builds and simulator runs must use agent_queue_mcp. Mutable plans live outside the repository.

## Rendering and scale
Native image/video surfaces need content-local placement and explicit 540pt RealityView depth; a surrounding 2D GeometryReader otherwise collapses depth and hides pixels behind the window. Keep 96pt vertical media clearance and 52pt lower button gaps, fixed window widths and resizable heights. Paired native surfaces use fixed inward ±10-degree angles matching the backing; initialize on attachment and never add continuous billboards or reset orientation on layout/playback updates. These angles approximate the initial centered viewing position, not a sampled head pose. Test real ImagePresentationComponent/VideoPlayerComponent mono fixtures in Simulator; generated spatial scenes/stereo require headset checks. Avoid whole-library materialization: lazy PHFetchResult, paged assets, bounded foreground/lookahead generation (default5 ahead/2 behind, shared20-result/80M-pixel speculative cache and2 preparation slots).

## Agent registry
| Agent | Status | Workspace | Session ID | Updated | Notes |
| --- | --- | --- | --- | --- | --- |
| Sky Surveyor | active | workspaces/sky-surveyor/ | 01a107b5-7d16-7fb3-8d84-619ad7126389 | 2026-10-11 | Owns standalone gallery dogfooding fixes and latest-main Pali delivery. |
