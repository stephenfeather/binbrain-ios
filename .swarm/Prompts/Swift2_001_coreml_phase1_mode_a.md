# Swift2 — CoreML Pre-classification, Phase 1 (Mode A)

**Branch:** `feature/coreml-mode-a` off `main`
**Priority:** Medium
**Design doc:** `docs/designs/coreml-preclassification-scope.md` — READ THIS FIRST

## Scope

Implement **Phase 1** only (§9 of the design doc): Mode A with the built-in `VNClassifyImageRequest` results that Stage 3 already produces. No new model files, no server protocol changes, no detector, no custom training.

User-visible result: when the pipeline finishes (sub-second), `SuggestionReviewView` shows top-K on-device classifications as **preliminary** editable chips immediately, while the ~40 s Ollama call continues in the background. When the server responds, its items merge into / replace the tentative chips per the merge UX below.

## Phase 0 prerequisites — DO NOT SKIP

The premortem on the design doc flagged three tigers (T1, T2, T3). Two are blocking for this task. Before writing Phase 1 production code:

1. **T2 — Telemetry/consent decision.** Phase 1.2 in the design ("log on-device top-K vs. final-confirmed label") is **on-device-only debug logging** for this task. You MUST NOT add any uploaded telemetry, analytics SDK, or `device_metadata` field that leaks per-user classification history to the server. If cross-user calibration is ever wanted, that is a separate task behind a consent screen; it is out of scope here. Use `os.Logger` with `privacy: .private` for the on-device log, and only under `#if DEBUG`.
2. **E3 — Merge UX spike.** §10 E3 flags that the 2–3 day estimate is optimistic because merge UX is under-specified. Before committing to an estimate, produce a one-page UX spike (`thoughts/shared/designs/coreml-mode-a-merge-ux.md`) evaluating the three options in E3's mitigation list (greyed-preliminary-until-server-agrees / lock-accepted-chips-with-disagreement-indicator / delay-chips-until-Nseconds). Pick one, justify it, push `ARCHITECT REQUEST:` with the picked option before implementing. Do not guess the UX.

T1 (crop-classify batching) is a Phase 2 concern, explicitly out of scope here.

## Must-haves

- Consume existing `DeviceProcessing.classifications` (`PipelineModels.swift:97`, emitted at `ImagePipeline.swift:197`). Do NOT add a second `VNClassifyImageRequest` or re-invoke Vision — the data is already in the pipeline output.
- Render top-K (start with K=3, make it a constant) in `SuggestionReviewView` as editable chips with a clear visual "preliminary" state per the merge UX decision.
- When the server response arrives, apply the chosen merge strategy. Preserve any edits the user made to the preliminary chips — user edits always win over both on-device and server suggestions.
- If `classifications` is empty or Stage 3 failed, fall back to today's behavior (server-only chips). No crash, no blank state.
- Under `#if DEBUG`, log `(top-K labels, top-K confidences, final-confirmed label)` via `os.Logger` with `.private` interpolation, to the existing subsystem used in `APIClient.swift`.

## Must-NOT-haves

- No new CoreML model bundled or downloaded.
- No `YOLO`, `MobileNetV3`, `EfficientDet`, or custom model. Built-in `VNClassifyImageRequest` output only.
- No server protocol change. No new fields on `/ingest` or `device_metadata`.
- No uploaded telemetry. On-device debug logs only.
- No runtime feature flag plumbing — Phase 3 concern (T3), not Phase 1. If you feel one is needed for rollout, escalate via `ARCHITECT REQUEST:`.
- No changes to `PipelineModels.ClassificationResult` shape.

## TDD plan

- RED: a `SuggestionReviewView` test that, given a `device_metadata.classifications` payload pre-server-response, renders the top-K labels as preliminary chips.
- RED: a merge-logic unit test for each of the three server-response cases (server agrees / server disagrees / server empty) covering the chosen UX.
- RED: a test that user edits to preliminary chips survive a server response.
- GREEN: implement until all pass.
- REFACTOR: keep the merge logic in a pure function (no SwiftUI view state mixed in), testable without rendering.

## References

- `Bin Brain/Bin Brain/Services/ImagePipeline.swift:66-197`
- `Bin Brain/Bin Brain/Services/MetadataExtractors.swift:19-49`
- `Bin Brain/Bin Brain/Services/PipelineModels.swift:97, 133`
- `Bin Brain/Bin Brain/Views/...SuggestionReviewView...` — find exact path
- `docs/designs/coreml-preclassification-scope.md` §1, §2 Mode A, §4, §9 Phase 1, §10 T2 and E3

## Completion

One PR: `feat(pipeline): Mode A preliminary on-device classification chips`. Include screenshots of the three merge states. Push `ARCHITECT TASK COMPLETED: Pull Request #<n>` to the Architect pane when ready for review.
