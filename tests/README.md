<!-- Target audience: developers and release agents -->
# Gallery core regression checks

Run `python3 tests/run_core_checks.py` through the shared compute queue from the repository root. It discovers each `check_*.py`, fails on the first error, and reports the number of checks run. It requires Python 3, Xcode's Swift compiler and the macOS CryptoKit runtime.

These checks exercise production queue, media, history, storage, sharing and transaction code with controlled doubles and generated data. The storage test writes generated encrypted media to a temporary directory; file-protection APIs are substituted on macOS. The loading tests extract production method bodies into isolated Swift probes, so source refactors may require updating their extraction points. They do not prove visionOS file protection, real PhotoKit permission and transaction behavior, frame timing, or headset rendering. Run the generated native Simulator transition tests and native build separately, and report their evidence and any gaps. Spatial-scene appearance and dual-view comfort require a headset check by the owner.

The PhotoKit-double check asserts exact asset IDs and album memberships, transaction failure, and the reserved Recycle Bin destination. The history check covers migration and store-specific identity; the deletion-plan check covers frozen IDs, epoch, cancel and one-shot authority. The loading checks cover retry after explicit refresh/reactivation, multi-window demand changes, warm media reuse, video metadata and protected speculative-lease limits/cleanup. The transfer host check covers encrypted data integrity, off-main storage work, lock interruption and a post-rename sync error.

The confirmation check runs the production request factory and confirmation method. It checks synchronous enqueue while unlocked, authentication while locked, exact captured target and destination, cancellation and stale-epoch rejection. It does not model the platform authentication dialog.

Shared-media checks exercise borrowing prepared content across viewers and privacy invalidation. A real temporary-file lease check verifies that closing the first consumer keeps playback available and closing the last removes the file; the cache holds only weak references.

The sharing check compiles the production provider input helper with real `NSItemProvider` fixtures. It checks concrete media selection, sender and fallback filenames, temporary representation copying before the callback returns, exact bytes, unsupported items and provider failures.

The vault-index check compiles the production index with generated records and a stand-in Photos scope. It compares bin visibility, counts, sorting and incremental updates with a full rebuild. The publication check runs the production publication methods with controlled storage and delayed detached work to exercise lock and revision races. These extracted host probes do not replace real PhotoKit, native Simulator or headset checks.
