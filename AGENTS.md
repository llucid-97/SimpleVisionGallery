<!-- Target audience: agents -->
# Simple Vision Gallery

Standalone visionOS photo gallery. Ordinary supported photos become spatial scenes automatically; users can open multiple media windows. Keep the PhotoKit gallery, bounded in-memory preparation, playlist ordering and native rendering contracts from SimpleVisionTools.

## Structure
`SimpleVisionGallery/` contains app code and resources. `resources/` holds shared source/release reference inputs. `docs/` holds user-facing design and release documents. `workspaces/<agent-name>/` is locally ignored scratch space; subagents inherit their parent workspace. New agent tests go in locally ignored `.codex-tests/`, never tracked product tests unless explicitly promoted in PR review.

## Coordination
Use one owned checkout per top-level agent; additional worktrees belong under that agent's workspace. Never overwrite another agent's uncommitted work. Main is the integration branch; the user has authorized pushes and made this repository public on 11 October 2026. Build/validate before pushing. Heavy builds and simulator runs must use agent_queue_mcp. Mutable plans live outside the repository.

Shut down every simulator you boot as soon as you are done or it sits idle (`xcrun simctl shutdown <udid>`), and have subagents do the same. Keep at most one booted unless a task truly needs more, check `xcrun simctl list devices booted` before ending a turn, and leave simulators other agents booted alone.

## Feature updates
For feature updates, use the `full-send` skill (`~/.codex/skills/full-send/SKILL.md`) to carry the work through implementation, checks, feedback, and integration. Follow this repository's main-branch workflow and keep device privacy and user-data rules in force.

## Core requirements and release checks
Read [Core requirements](docs/core-requirements.md) before implementation and review. These are user contracts, not optional polish. Every feature/full-send must run the core regression suite and the transition checks affected by its changes on the final integrated revision. Reviewers must check each requirement and record the command, result and any hardware-only gap before approving full-send. A build or a cache-hit counter alone does not prove responsive browsing.

Do not wave away a known regression as stale or unrelated. Fix it, or report it as a release blocker with the failed check. Never claim unrun or Simulator-only checks prove headset behavior. Use generated data; preserve Pali privacy and the existing no-uninstall rule. Add new core requirements to the document as Gershoma gives them; keep checks and the transition inventory in sync with the code.

## Rendering and scale
Native image/video surfaces need content-local placement and explicit540pt RealityView depth; a surrounding2D GeometryReader otherwise collapses depth and hides pixels behind the window. Known landscape/square photos (aspect>=1) use64pt vertical projection clearance; portrait, unknown/invalid metadata and video retain160pt. Derive the window budget from media height + both clearances +32pt outer insets, preserving fixed widths and resizable heights. The inherited52pt value was horizontal control spacing, not an image-to-button gap; the compact dock uses32pt gaps and44pt action targets. Paired native surfaces use the saved inward yaw and pitch from Settings (defaults +/-10 degrees yaw, 0 pitch), matching the backing. Initialize on attachment and update only for explicit calibration changes; never add continuous billboards or reset orientation on layout/playback updates. These angles approximate an initial centered position, not a sampled head pose. Centered mono Simulator renders do not establish off-center parallax, near-square occlusion, mixed-aspect pairs or headset comfort; portrait camera framing remains limited. Test real ImagePresentationComponent/VideoPlayerComponent mono fixtures in Simulator; generated spatial scenes/stereo require headset checks. Avoid whole-library materialization: lazy PHFetchResult, paged assets, bounded foreground/lookahead generation (default5 ahead/2 behind, shared20-result/80M-pixel speculative cache and2 preparation slots). Bounded512px More previews count toward that prepared-cache pixel budget; privacy covers override More context.

## Design review
Always apply the 100th-use lens in [the project design checklist](docs/design-review-checklist.md), even when those issues are outside a shared review pass's top 36. Preserve essential recovery, security, destructive-action and error details while removing repeated teaching copy.

## Agent registry
| Agent | Status | Workspace | Session ID | Updated | Notes |
| --- | --- | --- | --- | --- | --- |
| Sky Surveyor | active | workspaces/sky-surveyor/ | 01a107b5-7d16-7fb3-8d84-619ad7126389 | 2026-10-11 | Owns standalone gallery dogfooding fixes and latest-main Pali delivery. |
| Sieve | complete | workspaces/sieve/delete-feedback/ | 10f20ccf-ebdd-4061-89c7-739d08a18556 | 2026-10-29 | Immediate delete feedback and asynchronous PhotoKit work. |
