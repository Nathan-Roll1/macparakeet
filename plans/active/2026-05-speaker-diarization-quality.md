# Speaker Diarization Quality Plan

> Status: ACTIVE PLAN
> Date: 2026-05-27
> Scope: speaker diarization accuracy, speaker-to-word attribution, correction
> UX, and local diagnostics. This is separate from the meeting echo-suppression
> plan, which targets audio bleed into the microphone path.

## Problem

MacParakeet already has the right meeting foundation: microphone and system
audio are retained as separate sources, final meeting transcription is
source-aware, and speaker diarization only refines the isolated system track.
The remaining quality gap is narrower:

- remote speakers inside `Others` can be collapsed, over-split, swapped, or
  attached to the wrong words
- the app has no local diagnostic artifact that explains whether a bad result
  came from diarizer clustering, timestamp reconciliation, or UI labeling
- known speaker counts are not passed into FluidAudio even though the pinned
  offline pipeline supports them
- word-to-speaker reconciliation is strict-overlap only, so small ASR/diarizer
  timestamp drift can leave words unlabeled or assigned too coarsely
- speaker rename is label-only; it does not preserve assignment provenance,
  raw provider identity, or a reversible participant/person mapping

The goal is not to replace the local diarizer by default. The goal is to make
MacParakeet use the best available local-first diarization path and wrap it in
better constraints, reconciliation, diagnostics, and correction primitives.

## Verified Current State

- `Package.resolved` pins FluidAudio `0.14.5`
  (`ce59fb14b8b8978b196f6a34282e20ea6762d164`).
- `DiarizationService` constructs `OfflineDiarizerManager(config: .default)`
  and exposes only `diarize(audioURL:)`, so every call uses the same default
  clustering behavior.
- FluidAudio `0.14.5` exposes speaker-count constraints through
  `OfflineDiarizerConfig.Clustering`:
  - `numSpeakers`
  - `minSpeakers`
  - `maxSpeakers`
- FluidAudio applies those constraints inside the offline VBx clustering path
  before reconstruction.
- `TranscriptionService.transcribeMeetingAudio` diarizes only the system WAV
  and maps results into source-prefixed IDs such as `system:S1`.
- `MeetingTranscriptFinalizer` keeps microphone words as `microphone` / `Me`
  and only refines system words when system diarization exists.
- `SpeakerMerger.mergeWordTimestampsWithSpeakers` assigns speaker IDs by max
  direct overlap only. No overlap means no speaker assignment.
- `SpeakerInfo` currently stores only `{ id, label }`. Renaming a speaker
  updates the `speakers` JSON but does not store whether the label came from
  the model default, the user, a participant hint, or some future provider.

## Non-Goals

- Do not change the default local-first behavior.
- Do not upload audio for diarization without a separate explicit privacy ADR
  and user opt-in.
- Do not treat calendar attendees as speaker identity truth.
- Do not solve microphone/system audio bleed here; that belongs to
  `2026-05-meeting-neural-echo-suppression.md`.
- Do not replace the current `Me` / `Others` source model. Improve it by
  splitting and labeling `Others` better.
- Do not make speaker identity biometric or cross-meeting by default in this
  pass.

## Design Principles

1. Preserve source attribution before diarization.
   Microphone remains the user's channel. System audio is the remote channel.
   Diarization refines the remote channel; it does not decide who is `Me`.

2. Treat diarization output as evidence, not final truth.
   Raw model speaker IDs, user-facing labels, and user/participant assignments
   should be separable.

3. Make quality observable locally.
   A bad result should produce a content-free report showing whether the failure
   is likely speaker count, clustering, timestamp reconciliation, or missing
   speech coverage.

4. Use known speaker counts when available.
   Exact speaker count is a real clustering constraint. Participant counts are
   useful hints but must remain overrideable and non-authoritative.

5. Keep corrections reversible.
   User speaker assignments should not rewrite words or destroy raw diarizer
   IDs.

## Phase 0: Diarization Quality Report

Add a local diagnostic artifact before changing behavior. This gives every
later change a measurable before/after.

### Core Types

Add a lightweight report model in Core:

```swift
public struct DiarizationQualityReport: Codable, Sendable, Equatable {
    public var source: Transcription.SourceType
    public var audioDurationMs: Int?
    public var diarizer: DiarizerRunSummary?
    public var wordAssignment: WordSpeakerAssignmentSummary
    public var speakers: [SpeakerQualitySummary]
    public var warnings: [DiarizationQualityWarning]
}
```

The report must not include transcript text, audio paths, URLs, speaker names,
or raw word content.

### Metrics

Capture at least:

- diarizer model/config summary:
  - FluidAudio version if discoverable
  - clustering threshold
  - `numSpeakers` / `minSpeakers` / `maxSpeakers`
  - `exclusiveSegments`
- detected speaker count
- diarization segment count
- segment count per speaker
- speaking time per speaker
- median and minimum segment duration
- speaker switches per minute
- total words
- words with speaker ID
- words assigned by direct overlap
- words assigned by fallback
- words left unassigned
- longest unassigned gap
- system words that remained `system` after system diarization
- meeting-only source coverage:
  - mic word count
  - system word count
  - system diarized word coverage

### Warnings

Emit deterministic warnings such as:

- `expectedMultipleSpeakersButDetectedOne`
- `detectedSpeakerCountOutsideHint`
- `highUnassignedWordRate`
- `highFallbackAssignmentRate`
- `excessiveShortSegments`
- `excessiveSpeakerSwitchRate`
- `systemDiarizationLowCoverage`

### Surfaces

Start with local developer/user-requested surfaces:

1. `macparakeet-cli meetings diarization-report <id> --json`
   - computes from stored transcript metadata
   - does not re-run STT or diarization
2. `macparakeet-cli transcribe ... --diarization-report <path>`
   - writes the report for a fresh file/URL transcription
3. Debug log line after meeting finalization:
   - warning names only
   - counts only
   - no transcript content

### Tests

- Report builder unit tests over synthetic words/segments.
- Meeting report tests for:
  - no diarization
  - clean two-speaker system diarization
  - one detected remote speaker when hint says two
  - words left as raw `system`
  - high short-segment churn

## Phase 1: Speaker Count Hints

Wire speaker-count constraints into the local offline pipeline.

### Public Core API

Add an explicit options object:

```swift
public struct DiarizationOptions: Sendable, Equatable {
    public var speakerCountHint: SpeakerCountHint?
    public var qualityProfile: DiarizationQualityProfile
}

public struct SpeakerCountHint: Sendable, Codable, Equatable {
    public var exact: Int?
    public var minimum: Int?
    public var maximum: Int?
}
```

Validation rules:

- all values must be positive
- `exact` overrides `minimum` / `maximum`
- if `minimum > maximum`, fail fast at the MacParakeet boundary rather than
  silently clamping user intent
- meeting hints describe remote/system speakers only, not total participants

Extend `DiarizationServiceProtocol` to accept options while keeping a defaulted
compatibility overload:

```swift
func diarize(audioURL: URL, options: DiarizationOptions) async throws
    -> MacParakeetDiarizationResult
```

### Manager Construction

The current `DiarizationService` stores one manager with one immutable config.
Speaker-count hints require one of these shapes:

1. Build a new `OfflineDiarizerManager` per distinct resolved config while
   reusing the same model cache directory.
2. Add a small manager factory/cache keyed by normalized `DiarizationOptions`.

Prefer the factory/cache if repeated meeting retranscribes become common. For
the first implementation, a per-run manager is acceptable if model preparation
is still cached on disk and measured by the quality report.

### Config Mapping

Map `SpeakerCountHint` to:

```swift
var clustering = OfflineDiarizerConfig.Clustering.community
clustering.numSpeakers = hint.exact
clustering.minSpeakers = hint.minimum
clustering.maxSpeakers = hint.maximum
let config = OfflineDiarizerConfig(clustering: clustering)
```

Preserve existing default values for segmentation, embedding, VBx, and
post-processing unless an explicit quality profile changes them.

### CLI

Add file/URL transcription flags:

```text
--speakers <n>
--min-speakers <n>
--max-speakers <n>
```

Rules:

- require speaker detection to be enabled, or enable it implicitly with a clear
  CLI help description
- reject `--speakers` combined with `--min-speakers` / `--max-speakers`
- include hints in JSON output metadata when `--diarization-report` is used

### Meeting UI

Add meeting-level expected remote speaker count only after the Core/CLI path is
validated:

- default: automatic
- optional exact remote speaker count
- optional min/max remote speaker range
- calendar attendees can prefill a suggestion but cannot silently force it

## Phase 2: Word-to-Speaker Reconciliation

Replace strict overlap-only assignment with a measured reconciliation step.

### Algorithm

Create a `SpeakerWordAssigner` that returns both words and stats:

```swift
public struct SpeakerWordAssignmentResult: Sendable, Equatable {
    public var words: [WordTimestamp]
    public var summary: WordSpeakerAssignmentSummary
}
```

Assignment order:

1. Direct max-overlap segment wins.
2. If no overlap, use nearest diarization segment only when the word midpoint is
   within a conservative tolerance.
3. Leave the word unassigned when the nearest segment is too far away.

Initial fallback tolerance:

- 500 ms for file/URL transcription
- 500 ms for meeting system-track reconciliation
- do not bridge across source IDs
- do not assign microphone words from system diarization

The tolerance should be configurable in tests and reportable in diagnostics,
not exposed as a user setting initially.

### Why This Matters

ASR word timestamps and diarization segments are generated by different model
paths. Small boundary drift should not turn otherwise-good diarization into
missing speaker labels.

### Tests

Extend `SpeakerMergerTests` or replace them with `SpeakerWordAssignerTests`:

- exact overlap still wins
- nearest-before fallback within tolerance
- nearest-after fallback within tolerance
- no fallback across large gaps
- no fallback when segments are empty
- tie handling remains deterministic
- summary counts direct/fallback/unassigned words

## Phase 3: Speaker Assignment Overlay

Improve correction and export quality without pretending the model is perfect.

### Data Model

Keep existing speaker IDs stable, but extend the stored speaker metadata with
optional provenance. The smallest compatible path is to extend `SpeakerInfo`
with optional fields:

```swift
public enum SpeakerLabelSource: String, Codable, Sendable {
    case modelDefault
    case user
    case participantHint
}

public struct SpeakerInfo: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var source: AudioSource?
    public var rawProviderSpeakerId: String?
    public var labelSource: SpeakerLabelSource?
    public var assignedParticipantId: String?
    public var assignedParticipantName: String?
}
```

Because `speakers` is JSON and the new fields are optional, this can be
backward-compatible with existing rows. If later needs exceed simple metadata,
add a dedicated `speakerAssignments` JSON column instead of overloading
`SpeakerInfo`.

### Behavior

- Model-created speakers use `labelSource = .modelDefault`.
- User rename sets `labelSource = .user`.
- Participant suggestion sets `labelSource = .participantHint` only after user
  confirmation.
- Raw speaker IDs remain stable even after labels change.
- Exports use display labels but JSON output includes raw IDs and provenance.

### UI

Keep the current inline rename path, then add a small assignment menu:

- `Rename`
- `Assign to participant`
- `Clear assignment`

Do not auto-assign attendees to diarized speakers. Suggest only when the user
has enough context to confirm.

## Phase 4: Evaluation Harness

Add a repeatable local evaluation path before tuning clustering thresholds or
quality profiles.

### Fixtures

Support private, untracked fixtures:

```text
fixtures/private/diarization/
  two-remote-speakers/
    system.wav
    expected.json        # optional coarse expectations
    reference.rttm       # optional, if available
```

Keep real meeting audio out of git.

### Harness

Add a developer command or script that can:

- run the same audio through default config
- run exact/min/max speaker-count variants
- run threshold variants around the current default
- emit `DiarizationQualityReport` for each run
- compute DER/JER only when an RTTM reference is present

The useful first comparison is not a huge benchmark. It is a small repeatable
set of MacParakeet-realistic failures:

- two remote speakers
- three or more remote speakers
- similar-sounding remote speakers
- overlapping speech
- late-joining speaker
- long meeting with topic changes

## Phase 5: Quality Profiles

Only after Phase 0-4 are in place, consider named local quality profiles.

Potential profiles:

- `balanced`: current FluidAudio defaults
- `precise`: lower segmentation step ratio and lower minimum segment duration
  when the user wants best quality over speed
- `fast`: current defaults or future embedding skip strategy if reports show
  minimal quality loss

Do not expose raw clustering threshold, VBx priors, or segmentation internals in
the general UI. Keep those in developer tooling unless repeated evidence shows a
real user-facing need.

## Optional Future: External Benchmark Mode

External/cloud diarization can be useful as a benchmark, but it is not part of
the default product path.

If pursued later:

- require a separate ADR
- require explicit user opt-in per run or provider configuration
- never enable from calendar, meeting type, or speaker count automatically
- persist provider/model provenance
- compare against local FluidAudio on the same audio before deciding whether any
  product integration is worth the privacy and operational cost

## Implementation Order

1. `DiarizationQualityReport` builder and tests.
2. `DiarizationOptions` / `SpeakerCountHint` Core API.
3. Speaker-count config plumbing into `DiarizationService`.
4. CLI flags for file/URL transcription speaker hints.
5. `SpeakerWordAssigner` with direct/fallback/unassigned stats.
6. Meeting system-track reconciliation uses `SpeakerWordAssigner`.
7. JSON/report surfaces expose content-free quality metrics.
8. Optional meeting UI for expected remote speaker count.
9. `SpeakerInfo` provenance extension and user assignment behavior.
10. Private fixture harness and local evaluation script.
11. Quality profiles only after reports show which knobs matter.

## Acceptance Criteria

1. A known two-remote-speaker meeting can be transcribed with an exact remote
   speaker count hint, and the report records that hint.
2. A bad diarization run produces a local report that distinguishes at least
   these failure classes:
   - wrong detected speaker count
   - low word assignment coverage
   - excessive speaker switching
   - raw `system` words left after system diarization
3. The word assignment step reports direct, fallback, and unassigned counts.
4. Speaker rename remains backward-compatible with existing transcripts.
5. User-assigned labels are stored as user corrections, not confused with raw
   model speaker IDs.
6. Calendar or participant metadata never silently asserts speaker identity.
7. No transcript text, audio path, URL, or speaker label is added to telemetry.
8. Existing diarization behavior remains the default when no hints are supplied.

## Verification Plan

Targeted first pass:

```bash
swift test --filter 'DiarizationServiceTests|SpeakerMergerTests|TranscriptionServiceTests|TranscriptSegmenterTests'
```

Before merging implementation:

```bash
swift test
```

Manual validation:

1. Transcribe a local multi-speaker file with no hints.
2. Transcribe the same file with `--speakers 2`.
3. Compare report warnings, speaker count, assignment coverage, and switch rate.
4. Retranscribe a meeting with isolated `system.m4a` and confirm the hint applies
   only to remote/system speakers.
5. Rename or assign a speaker and confirm exports show the display label while
   JSON still preserves the raw speaker ID.
