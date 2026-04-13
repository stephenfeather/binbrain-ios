# On-device CoreML Pre-classification — Scope

Status: Research / design proposal. No production code changes.
Author: Swift1 · 2026-04-13

The open thread (OPEN_THREAD 05385574) asks whether a lightweight on-device classifier should run before upload to pre-populate category suggestions, skip obvious non-bin content, and/or reduce the ~40 s server-side Ollama call. This doc scopes three user-visible modes against the pipeline as it exists today.

## 0. Subject

**Photographic subject:** a single item going into a bin, not a wide shot of the bin's contents. The bin's identity comes from a prior QR scan, not from the image. On-device inference is therefore a **single-object classifier** problem — the whole-image top-K label is directly meaningful as "what this item is." (Future: may evolve to multi-item-per-photo, requiring object detection — out of scope here, see §7.)

## 1. Current pipeline summary

`ImagePipeline.process(_:)` (`ImagePipeline.swift:66`) is a 3-stage actor-owned flow between `capture` and `upload`:

1. **Stage 1 — Quality gates** (`QualityGates.validate`, called at `ImagePipeline.swift:74`): sequential resolution → blur → exposure → saliency checks. Failure throws `PipelineError.qualityGateFailed` and prevents upload.
2. **Stage 2 — Optimize** (`ImageOptimizer.optimize`, called at `ImagePipeline.swift:80`): saliency-guided smart crop, auto-enhance, resize, JPEG encode. Produces the bytes that will be uploaded.
3. **Stage 3 — Extract metadata** (`MetadataExtractors.extract`, called at `ImagePipeline.swift:87`): runs three Vision requests in a single `VNImageRequestHandler.perform([...])` call on a dedicated serial queue (`MetadataExtractors.swift:34-49`): `VNRecognizeTextRequest` (OCR), `VNDetectBarcodesRequest`, and — **critically for this proposal** — `VNClassifyImageRequest` (`MetadataExtractors.swift:45`). Classifications are already filtered and serialized into `DeviceProcessing.classifications` in the `device_metadata` JSON sidecar (`PipelineModels.swift:97`, `ImagePipeline.swift:197`).

**Key data point:** on-device classification *already runs and is already uploaded*. `VNClassifyImageRequest` classifies the whole image, which is exactly what we want for a single-item photo — no region proposal or detection needed. The bin association is supplied by the prior QR scan, so the classifier never needs to identify the bin itself. The server receives `classifications: [ClassificationResult]` with every photo but — as of this scoping — does nothing user-visible with them.

## 2. Three use-case modes

### Mode A — Pre-populated category suggestions
- **User-visible behavior:** as soon as the pipeline finishes (sub-second), `SuggestionReviewView` shows the top-K `ClassificationResult` entries as editable chips. User can start typing / correcting while the ~40 s Ollama call continues in the background; when the server response arrives, its items are merged / replace the tentative chips.
- **Server cost reduction:** none directly. Server still runs Ollama.
- **Risks:** UX churn if on-device top-K contradicts the server result ("I just accepted 'screw' and now it's changed to 'bolt'"). Needs a merge / confirmation strategy. VNClassifyImageRequest's ImageNet-2012 label space rarely contains the actual fastener / hardware vocabulary the app is ultimately targeting — many results will be near-miss synsets ("screw" vs. "nail" vs. "carpenter's kit"). Perceived latency is the main win.

### Mode B — Skip upload for unrecognizable content
- **User-visible behavior:** if *no* item-like class clears confidence T (i.e. top-K is flat / low-confidence across the board), the pipeline short-circuits before Stage 2 with a new failure kind ("This doesn't look like a clear item — take another?"). `PipelineError.qualityGateFailed` already offers a natural analogue; a new `PipelineError.unrecognizableSubject` would reuse the existing "Upload Anyway" escape hatch (`processSkippingQualityGates`, `ImagePipeline.swift:106`). A narrow denylist of "obviously not an item" classes (`"face"`, `"sky"`, `"landscape"`) can run alongside the confidence floor to catch accidental shutter taps and selfies.
- **Server cost reduction:** direct — any short-circuited capture avoids the 40 s Ollama call and the bandwidth to upload the JPEG. Reduces server load from empty-surface captures, pocket shots, and misfires.
- **Risks:** *false negatives on legitimately unusual items* — a real item photo with no close ImageNet synset may fail the confidence floor even though Ollama could have recognized it. The override escape hatch is mandatory. Calibrating T against the app's actual item distribution needs real captures.

### Mode C — Reduce server inference load via a hint
- **User-visible behavior:** none on the client. The client adds a `device_classification` field (or reuses `classifications` already in `device_metadata`) and the server may skip Ollama when `top_k[0].confidence > T_server` and the label matches a server-side catalogue mapping.
- **Server cost reduction:** the largest of the three, proportional to the share of images where the on-device top-K is confidently correct.
- **Risks:** *highest integration cost*. Requires a server-side protocol change, a server-side ImageNet→catalogue mapping (which is a machine-learning problem in its own right), a confidence calibration study, and an A/B rollout plan. Client-side work is small; the project work is server-side.

## 3. Model candidate shortlist

All candidates are single-object / whole-image classifiers, consistent with the one-item-per-photo subject. Detection models belong in §7, not here.

| Model | Source | Size | Inference on A12 | Label space | Domain fit |
|---|---|---|---|---|---|
| `VNClassifyImageRequest` (built-in) | Apple Vision | 0 MB (ships with iOS) | Already measured in-place — *needs benchmarking on-device* but Stage 3 end-to-end (OCR + barcode + classify batched) is in the low hundreds of ms in practice | ImageNet-derived (~1,300 labels) | Partial — has "screw", "nail", "hammer" etc., but sparse coverage of the hardware / kitchen / household subcategories the app targets. **Reuse cost: zero** — already running and already in `device_metadata.classifications`. |
| MobileNetV3-small (Apple CoreML Model Zoo / ml-vision-models) | developer.apple.com/machine-learning/models/ | ~9 MB | ~20–40 ms on A12 (Apple published figures) | ImageNet-1000 | Drop-in alternative to the built-in; designed for object (not scene) recognition. Offers no domain advantage over the built-in unless fine-tuned, but a useful baseline for comparison. |
| EfficientDet / EfficientNet trained on Open Images V7 | TensorFlow → coremltools | 10–25 MB | *Needs benchmarking on-device* | ~9,600 Open Images labels | Broader label space than ImageNet's iconic-object bias — more likely to contain household/consumer items the app actually sees. Trade-off: larger model, more labels to filter / map server-side. |
| Custom fine-tune of MobileNetV3 on the app's confirmed-class corpus | Internally trained; the server already collects confirmed classes via `POST /classes/confirm` | ~5–15 MB | *Needs benchmarking on-device* | App-specific | **Best domain fit** — but requires a training pipeline, labeled dataset collection from the confirmed-class table, and a model-distribution mechanism. Flag as **future**, not now. |

`VNImageRequestHandler.perform()` is synchronous and currently dispatched on `visionQueue` in Stage 3 (`MetadataExtractors.swift:19-35`); any CoreML classifier should follow the same pattern or be added to the same `perform(requests:)` call.

## 4. Integration points

Three candidate slots in `ImagePipeline.process(_:)`:

1. **Before Stage 1** — gate non-bin content out early (Mode B only). Saves ~1 s of Stage 2 + Stage 3 work. Requires a dedicated classifier pass (adds its own latency), but the existing flow already runs one in Stage 3, so this effectively reorders work.
2. **Folded into Stage 3's existing `perform([...])` batch** (`MetadataExtractors.swift:49`) — add the CoreML request to the Vision batch. This is **the lowest-cost integration** because it reuses the already-dispatched `VNImageRequestHandler` and the existing queue; marginal latency is small because the Neural Engine is already warm. Suitable for Modes A and C **only when the classifier consumes the whole frame**. For a crop-classify pass (§7's detect-then-classify), the classifier runs *after* the objectness/detection request returns and therefore cannot share the same `perform([...])` batch — it's inherently two-pass on the `visionQueue` (detect, wait, crop, classify). Call this **slot 2b** when budgeting; it costs more than slot 2a (batched) and should not be assumed equivalent. For Mode B, slot 2 (either flavor) is *too late* to short-circuit upload — short-circuit would have to happen in `ImagePipeline` after Stage 3 rather than before Stage 1.
3. **Replace** `VNClassifyImageRequest` with a custom model. Same integration surface as (2) but with a better label space. All existing downstream code already consumes `ClassificationResult` (`PipelineModels.swift:133`), which means the label values change but no plumbing does.

**Impact on existing `VNClassifyImageRequest`:** the current call is effectively free (Apple-bundled, batched with OCR + barcode), so *keeping it* and *adding* a second classifier is viable for comparison-mode development. Long-term, replacement (option 3) is preferable.

## 5. Open questions for ARCHITECT

1. **Which mode is the actual goal?** Mode A (perceived latency) and Mode C (server cost) have very different implementation footprints and different stakeholders. Is the primary win for the user (A) or for the server bill / throughput (C)?
2. **What is the acceptable false-negative rate for Mode B**, and who decides it? A 2 % false-negative rate on real bin photos would be user-visibly broken; a 10 % rate likely kills adoption. This needs a target number before we ship a denylist.
3. **Do we have a labeled dataset?** The `POST /classes/confirm` flow (`APIClient.confirmClass`) means the server is already collecting confirmed labels. Is that corpus big enough, clean enough, and legally clear to train a custom MobileNetV3 on? Without this, options 1–3 in the shortlist collapse to "ImageNet or COCO."
4. **Does the server team have capacity for the Mode C protocol change** — adding a `device_classification` field to `/ingest` (or reading the existing `device_metadata.classifications`) and implementing a catalogue mapping + short-circuit? If not, C is a theoretical win only.
5. **Client model distribution:** if we ship a custom model, is it bundled with the app (forces App Store release per update) or pulled from the server at first launch (needs a hosting path, signing, cache, and update strategy)? This is a real implementation decision, not a detail.

## 6. Rough estimate

Mode A alone: ~2–3 days (wire existing `classifications` into `SuggestionReviewView`, design the merge UX, tests). All three modes with a custom fine-tuned model, server protocol change, and model-distribution plumbing: ~15–25 days of client+server work, excluding dataset curation and model training.

## 7. Detect-then-classify as a bridge

Even in the single-item world, in-the-wild captures include clutter (hand, benchtop, adjacent items), so whole-frame classification can feed the wrong pixels to the classifier. A lightweight detection pass before classification cleans this up and is the same architecture multi-item capture eventually requires.

**Shape:** detector proposes N bounding boxes → each crop runs through the §3 classifier → Stage 3 emits an array of per-region top-Ks. Detector candidates: `VNGenerateObjectnessBasedSaliencyImageRequest` (already in Vision, zero model cost; `ImageOptimizer` already uses saliency for smart crop), a CoreML-ported YOLOv8n (~6 MB, COCO-80), or `VNDetectRectanglesRequest` for box-shaped items. `PipelineModels.DeviceProcessing.classifications` already tolerates arrays — extending to per-bbox top-Ks is additive.

**Near-term value (not just future):** Mode A gets cleaner chips from a subject crop; Mode B gets a stronger reject signal ("no box clears objectness T *and* no class clears confidence T"); Mode C hint quality improves for the same reason.

**Why it's a bridge, not day-one:** adds a model (or tuned saliency), adds per-region plumbing, and needs a UX decision for N>1 (does `SuggestionReviewView` show one item or a list?). Ship single-item first; detect-then-classify when objectness-only crops prove insufficient on real captures.

## 8. Future scope — multi-item photos

Once §7 ships, multi-item is mostly in place: detector already proposes N boxes, classifier already runs per region, `device_metadata` already carries per-region top-Ks. Remaining work is UX (review N suggestions), server protocol (Mode C hint becomes array-valued), and possibly upgrading the detector to an open-vocabulary model (YOLO-World, Grounding DINO ports) if saliency/COCO crops prove too noisy.

## 9. Proposed order of operations

Sequenced smallest-increment-of-value first, data-collection second, model work last. Each phase produces the evidence that gates the next.

### Phase 1 — Surface what we already have (~3 days, client only)

1. **Mode A with the built-in classifier.** Wire existing `device_metadata.classifications` from `VNClassifyImageRequest` into `SuggestionReviewView` as editable chips shown pre-server-response. Design server-merge UX (chips merge/replace when Ollama returns).
2. **Instrument.** Log on-device top-K vs. final-confirmed label for every capture. **Destination and consent are a Phase 0 decision (§10 T2)** — on-device-only logs serve debugging but do not bootstrap cross-user calibration; cross-user calibration requires an opt-in telemetry channel and is a server change, not "zero server change." Phase 5's legal/privacy review must be pulled forward to Phase 0 if any uploaded logs are retained as training data.

*Value:* immediate perceived-latency win with no model or server work.

### Phase 2 — Objectness-only detect-then-classify (~4 days, client only)

3. Add `VNGenerateObjectnessBasedSaliencyImageRequest` to Stage 3, extract top-1 bbox, classify the crop in addition to the full frame. Emit both in `device_metadata` for A/B.
4. Compare against Phase 1 instrumentation: does crop-classification top-K match the confirmed label more often than full-frame? If yes, promote crop to primary.

*Value:* tests §7's hypothesis cheaply before committing to a detector model. If objectness alone is enough, YOLO never enters the design.

### Phase 3 — Mode B with a calibrated floor (~3 days)

5. Use the Phase 1 confidence distribution to pick T, **augmented with a calibration study** (reliability diagram, temperature scaling if needed) — see §10 E2. Add `PipelineError.unrecognizableSubject` + "Upload Anyway" override. Ship behind the runtime flag established in Phase 0 (§10 T3); monitor override rate.

*Value:* server-cost reduction on misfires with a calibrated T, not a guess.

### Phase 4 — Mode C (≥5 days, joint client+server)

6. Server team adds `device_classification` handling (or reads existing `classifications`), builds the ImageNet→catalogue mapping, runs a calibration study, A/B rolls out the Ollama short-circuit. Client work is trivial at this point.

*Value:* largest server-cost lever. Deferred because it needs the catalogue-mapping work plus Phase 1 data.

### Phase 5 — Custom model (≥10 days, cross-team)

7. Curate a dataset from `POST /classes/confirm` + Phase 1 logs. Legal/privacy review. Fine-tune MobileNetV3 or Open Images EfficientDet. Pick distribution strategy (bundled vs. first-launch download). Replace the ImageNet classifier in Stage 3.

*Value:* best domain fit. Last because prior phases tell us whether it's needed.

### Gates between phases

- **1 → 2:** real capture logs collected, ≥N per category (N is Open Question 2 in §5).
- **2 → 3:** crop vs. full-frame comparison shows measurable classification improvement.
- **3 → 4:** Mode B override rate steady-state below threshold.
- **4 → 5:** server-side short-circuit working but catalogue-mapping quality caps the reachable rate — custom label space becomes worth the cost.

### Pushback

- Don't jump to YOLO or a custom fine-tune without Phase 1's data. Both are expensive bets made blind.
- Don't ship Mode B with a guessed T. Phase 1 gives us the distribution for free.
- Don't bundle a custom model without a distribution/update plan (§5 Open Question 5); that decision blocks Phase 5.

## 10. Known risks & mitigations

Recorded from the pre-mortem pass on this doc (2026-04-13). Tigers block the phases they're attached to; elephants are tracked but do not block.

### T1 — Crop-classify is not batchable with its detector

**Risk.** §4 slot 2 ("fold into Stage 3 `perform([...])`") is cheap for whole-frame classification but does not apply to §7's detect-then-classify, which is inherently a two-pass sequence (objectness → crop → classify). Phase 2's 4-day estimate assumes the wrong integration slot.

**Mitigation.**
- Split §4 slot 2 into **2a** (whole-frame, batched) and **2b** (post-objectness crop, two-pass). Phase 2 uses 2b and carries the extra `visionQueue` round-trip in its latency budget.
- Re-estimate Phase 2 to reflect two Vision dispatches instead of one.

### T2 — Phase 1 instrumentation has no destination or consent path

**Risk.** "Log on-device top-K vs. confirmed label" can't bootstrap cross-user Phase 3 calibration or a Phase 5 training set without (a) an uploaded telemetry channel and (b) a consent/retention policy. The repo has no analytics framework (only `os_log`/`Logger` in `APIClient`), and Phase 5's legal review currently lands after data collection would have already begun.

**Mitigation (Phase 0, prerequisite to Phase 1.2).**
- Decide: on-device-only debug logs (cheap, limited value) vs. opt-in uploaded telemetry (expensive, enables the downstream phases).
- If uploaded: scope a minimal telemetry endpoint (or extend `/ingest`'s `device_metadata` with a `confirmation_feedback` field), define retention, add an in-app consent screen before Phase 1 ships.
- Pull Phase 5's legal/privacy review to Phase 0. No user-capture labels leave the device until that review signs off.

### T3 — No runtime feature-flag infrastructure exists

**Risk.** Phase 3 says "Ship Mode B behind a flag; monitor override rate." Verified: no `FeatureFlag` type or remote-config library in the Bin Brain target. Without a runtime flag, the only rollback for Mode B is an App Store release — which makes "monitor and back out" a days-to-weeks loop instead of hours.

**Mitigation (Phase 0, prerequisite to Phase 3).**
- Add a lightweight flag surface: `UserDefaults`-backed locally, plus a server-driven override (extend an existing settings endpoint, or add one to the binbrain server). Scope: ~1 day client + ~0.5 day server.
- Alternative (cheaper, weaker): gate Mode B on an `Info.plist` build-config key and accept that disabling it requires a release. Only acceptable if the consent+privacy gates above already require a release for Mode B anyway.

### E1 — ~40 s Ollama latency figure is uncited

**Risk.** The cost/benefit for Modes A, B, C all pivot on the intro's "~40 s server-side Ollama call." No source, no distribution (p50/p95/p99), no breakdown by payload size. If real p50 is 10 s, Mode A's perceived-latency pitch weakens substantially; if p95 is 90 s, Mode B's server-cost upside grows.

**Mitigation.** Before Phase 1 commits, collect a 500-sample distribution from production `/ingest` timing (server already logs this) and replace the "~40 s" figure with a measured p50/p95/p99. Update the mode rankings if the distribution is materially different from the point estimate.

### E2 — VNClassifyImageRequest confidence is not well-calibrated

**Risk.** ImageNet CNN confidence scores are known to be poorly calibrated (Guo et al., *On Calibration of Modern Neural Networks*, 2017). Phase 3's "pick T from the Phase 1 confidence distribution" produces a *distribution-aware* cutoff, not an *accuracy-aware* one — 0.7 confidence ≠ 70 % likely correct.

**Mitigation.** Phase 3 adds an explicit calibration step on top of the distribution work:
- Build a reliability diagram from Phase 1 (confidence bin → actual accuracy).
- If the diagram is substantially off-diagonal, apply temperature scaling (single scalar fit on a held-out split) before selecting T.
- Re-state the T selection criterion as "accuracy at T ≥ X %" rather than "T at the Nth percentile of confidence."

### E3 — Mode A merge UX is under-specified

**Risk.** §2 Mode A flags the churn risk ("I just accepted 'screw' and now it's 'bolt'") but proposes no resolution. §9 Phase 1 budgets 2–3 days including "design the merge UX," which is optimistic for an interaction the doc itself calls out as the main UX risk.

**Mitigation.**
- Spike the merge UX as a design deliverable *before* Phase 1's estimate is committed. Options to evaluate: (a) show on-device chips as greyed "preliminary"; commit only when Ollama agrees or user accepts, (b) lock accepted chips even if Ollama disagrees, add a "server disagrees" indicator, (c) don't show on-device chips until the first 2–3 s of Ollama latency passes.
- Re-estimate Phase 1 after the UX decision. If UX research is needed, it belongs in Phase 0.

### Checklist gaps (tracked, not yet mitigated)

- **Classifier failure handling in Stage 3 batch.** If `VNClassifyImageRequest` or a replacement throws, does the upload still proceed (current behavior) or fail? Document explicitly before Phase 2 ships; mishandling adds a silent broken-feature risk.
- **Neural Engine / thermal behavior.** A12+ assumption needs a minimum-iOS-device check; thermal throttling across back-to-back captures is uncharacterized. Benchmark once a candidate model is chosen.
- **Label-space migration.** Replacing `VNClassifyImageRequest` with a custom model silently changes the label strings in `ClassificationResult`. Downstream consumers (server catalogue mapping, SuggestionReviewView display, future UI tests) all need an explicit migration plan. Call out in §4 option 3 and in the Phase 5 deliverables.
