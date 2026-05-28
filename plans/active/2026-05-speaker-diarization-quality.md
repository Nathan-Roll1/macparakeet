# Speaker Diarization Quality Plan

> Status: ACTIVE PLAN
> Date: 2026-05-27
> Review: revised after ChatGPT Pro review to reduce overengineering and avoid
> brittle heuristics.
> Scope: speaker diarization accuracy, speaker-to-word attribution, local
> diagnostics, and minimal speaker-label provenance. This is separate from the
> meeting echo-suppression plan, which targets audio bleed into the microphone
> path.

## Problem

MacParakeet already has the right meeting foundation: microphone and system
audio are retained as separate sources, final meeting transcription is
source-aware, and speaker diarization only refines the isolated system track.
The remaining quality gap is narrower:

- remote speakers inside `Others` can be collapsed, over-split, swapped, or
  attached to the wrong words
- known speaker counts are not passed into FluidAudio even though the pinned
  offline pipeline supports them
- word-to-speaker reconciliation is strict-overlap only, so small ASR/diarizer
  timestamp drift can leave system words source-only
- the app has no content-free report for a fresh diarization run
- speaker rename is label-only; it does not record whether a label came from
  the model default or a user correction

The goal is not to replace the local diarizer by default. The goal is to make
MacParakeet use the best available local-first diarization path by adding
constraints, conservative reconciliation, and honest diagnostics around the
current FluidAudio offline pipeline.

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
- FluidAudio resolves those constraints inside the offline VBx clustering path,
  and may clamp them to the available embedding count. A requested hint is not
  proof that the result is correct.
- `TranscriptionService.transcribeMeetingAudio` diarizes only the system WAV
  and maps results into source-prefixed IDs such as `system:S1`.
- `MeetingTranscriptFinalizer` keeps microphone words as `microphone` / `Me`
  and only refines system words when system diarization exists.
- `SpeakerMerger.mergeWordTimestampsWithSpeakers` assigns speaker IDs by max
  direct overlap only. No overlap leaves the original word speaker/source
  unchanged.
- `SpeakerInfo` currently stores only `{ id, label }`. Renaming a speaker
  updates the `speakers` JSON but does not store whether the label came from
  the model default or the user.

## Non-Goals

- Do not change the default local-first behavior.
- Do not upload audio for diarization without a separate explicit privacy ADR
  and user opt-in.
- Do not treat calendar attendees as speaker identity truth.
- Do not solve microphone/system audio bleed here; that belongs to
  `2026-05-meeting-neural-echo-suppression.md`.
- Do not replace the current `Me` / `Others` source model. Improve it by
  splitting and labeling `Others` better.
- Do not make speaker identity biometric or cross-meeting by default.
- Do not add user-facing quality profiles until local evidence shows which
  FluidAudio knobs are worth exposing.
- Do not ship a stored-meeting `diarization-report` command until raw diarizer
  output and assignment summaries are persisted. Current stored
  `diarizationSegments` are word-derived display segments, not raw provider
  output.

## Design Principles

1. Preserve source attribution before diarization.
   Microphone remains the user's channel. System audio is the remote channel.
   Diarization refines the remote channel; it does not decide who is `Me`.

2. Treat diarization output as evidence, not final truth.
   Raw model speaker IDs, source IDs, user-facing labels, and assignment
   methods must not be collapsed into one ambiguous concept.

3. Prefer no speaker assignment over a confident wrong assignment.
   The reconciliation fallback must be conservative and ambiguity-aware.

4. Make fresh-run quality observable without pretending to know ground truth.
   Reports should expose requested hints, detected counts, assignment method
   counts, and coverage symptoms. They should not claim to diagnose clustering
   vs timestamp drift unless raw state proves that distinction.

5. Keep corrections reversible.
   User labels should not rewrite words or destroy raw diarizer IDs.

## Phase 0: Tighten Speaker Identity Helpers

Before adding options or reports, centralize the source-prefixed ID behavior so
future code does not rely on scattered string prefix checks.

Add a small Core helper:

```swift
enum SpeakerID {
    static func systemSpeaker(_ stableID: String) -> String
    static func source(for speakerID: String?) -> AudioSource?
    static func isSourceOnly(_ speakerID: String?) -> Bool
}
```

Rules:

- `"microphone"` maps to `.microphone`
- `"system"` maps to `.system`
- `"system:<stable-id>"` maps to `.system`
- plain `"S1"` is valid for non-meeting file/URL diarization but has no
  meeting source unless explicitly wrapped by the meeting path

This keeps the current storage shape but makes the source-vs-speaker convention
searchable and testable.

### Tests

- microphone source ID
- system source-only ID
- system diarized ID
- plain file speaker ID
- nil ID

## Phase 1: Speaker Count Hints

Wire speaker-count constraints into the local offline pipeline.

### Public Core API

Add only the option we need now:

```swift
public struct DiarizationOptions: Sendable, Equatable {
    public var speakerCountHint: SpeakerCountHint?

    public static let `default` = Self()

    public init(speakerCountHint: SpeakerCountHint? = nil) {
        self.speakerCountHint = speakerCountHint
    }
}

public struct SpeakerCountHint: Sendable, Codable, Equatable {
    public var exact: Int?
    public var minimum: Int?
    public var maximum: Int?
}
```

Do not add `qualityProfile` yet. That would create API surface before the
evaluation harness proves which profile knobs matter.

### Validation

- all values must be positive
- `exact` cannot be combined with `minimum` or `maximum`
- `minimum <= maximum` when both are provided
- meeting hints describe remote/system speakers only, not total attendees

Fail fast at the MacParakeet boundary when user intent is invalid. Do not rely
on FluidAudio's internal clamping as user-facing validation.

### Protocol Shape

Change the protocol so options cannot be silently ignored:

```swift
public protocol DiarizationServiceProtocol: Sendable {
    func diarize(
        audioURL: URL,
        options: DiarizationOptions
    ) async throws -> MacParakeetDiarizationResult
}

public extension DiarizationServiceProtocol {
    func diarize(audioURL: URL) async throws -> MacParakeetDiarizationResult {
        try await diarize(audioURL: audioURL, options: .default)
    }
}
```

Do not add a default implementation of the options-taking method that calls the
old method. That would allow mocks or alternate services to ignore hints while
tests still pass.

### Config Mapping

Preserve the injected base config. Do not rebuild from
`OfflineDiarizerConfig.Clustering.community`, because that would discard any
custom config passed to `DiarizationService.init(config:)`.

```swift
var config = baseConfig
if let hint = options.speakerCountHint {
    if let exact = hint.exact {
        config.clustering.numSpeakers = exact
        config.clustering.minSpeakers = nil
        config.clustering.maxSpeakers = nil
    } else {
        config.clustering.numSpeakers = nil
        config.clustering.minSpeakers = hint.minimum
        config.clustering.maxSpeakers = hint.maximum
    }
}
```

The first implementation can construct a new `OfflineDiarizerManager` per run.
If profiling shows repeated model reloads are costly, add a small manager cache
later keyed only by normalized speaker-count hints.

### CLI

Add file/URL transcription flags:

```text
--speakers <n>
--min-speakers <n>
--max-speakers <n>
```

Rules:

- these flags imply speaker detection for the run
- reject `--speakers` combined with `--min-speakers` or `--max-speakers`
- reject invalid bounds before any transcription starts
- include requested hints in the fresh-run report

### Meeting UI

Defer meeting UI for speaker-count hints until the Core/CLI path has evidence.
Users may enter attendee count instead of active remote speaker count; the UI
needs careful wording and should not be part of the first implementation.

## Phase 2: Conservative Word-to-Speaker Assignment

Replace `SpeakerMerger` with a pure assigner that returns both words and
assignment stats.

```swift
public struct SpeakerWordAssignmentResult: Sendable, Equatable {
    public var words: [WordTimestamp]
    public var summary: WordSpeakerAssignmentSummary
}

public struct WordSpeakerAssignmentSummary: Codable, Sendable, Equatable {
    public var totalWords: Int
    public var directOverlapWords: Int
    public var fallbackNearestWords: Int
    public var sourceOnlyWords: Int
    public var unassignedWords: Int
    public var fallbackToleranceMs: Int
    public var ambiguityMarginMs: Int
}
```

### Assignment Method

Track assignment method separately from final `speakerId`.

```swift
public enum WordSpeakerAssignmentMethod: String, Codable, Sendable {
    case directOverlap
    case fallbackNearest
    case sourceOnly
    case unassigned
}
```

Do not infer assignment quality from `speakerId != nil`. In meetings,
`speakerId = "system"` means source-only attribution, not a diarized speaker.

### Algorithm

1. Direct max-overlap segment wins.
2. If there is no overlap, compute interval boundary gap to nearby diarization
   segments.
3. Fallback only if:
   - best gap is within tolerance
   - candidate is unambiguous
   - assignment does not cross source boundaries
4. Leave meeting words source-only when the nearest candidates are ambiguous or
   too far away.

Use interval boundary gap, not midpoint distance:

```swift
if word.endMs <= segment.startMs {
    gap = segment.startMs - word.endMs
} else if segment.endMs <= word.startMs {
    gap = word.startMs - segment.endMs
} else {
    gap = 0
}
```

Initial conservative defaults:

- fallback tolerance: 250 ms
- ambiguity margin: 150 ms

These values must be injectable in tests and recorded in reports. Do not expose
them in the general UI.

### Finalizer Safety

Before true unassigned/source-only handling lands, fix
`MeetingTranscriptFinalizer.buildDiarizationSegments` so a leading unassigned
word does not cause all later segments to be dropped. It should start from the
first word that has a displayable speaker/source ID.

### Tests

- exact overlap wins
- nearest-before fallback within tolerance
- nearest-after fallback within tolerance
- no fallback across large gaps
- no fallback when two different speakers are close
- no fallback across microphone/system boundaries
- source-only meeting words are counted as source-only, not assigned
- output ordering is deterministic when word start times tie
- leading unassigned/source-only words do not drop later segments

## Phase 3: Fresh-Run Diarization Report

Add a content-free report for fresh transcriptions only. Do not add
`meetings diarization-report <id>` until raw diarization segments and assignment
summaries are persisted.

### Core Type

```swift
public struct DiarizationQualityReport: Codable, Sendable, Equatable {
    public var transcriptionSourceType: Transcription.SourceType
    public var diarizedAudioSource: AudioSource?
    public var requestedSpeakerHint: SpeakerCountHint?
    public var detectedSpeakerCount: Int
    public var rawDiarizationSegmentCount: Int
    public var segmentsPerSpeaker: [String: Int]
    public var speakingTimeMsPerSpeaker: [String: Int]
    public var assignmentSummary: WordSpeakerAssignmentSummary
    public var warnings: [DiarizationQualityWarning]
}
```

The report must not include transcript text, audio paths, URLs, speaker names,
or raw word content.

### Initial Warnings

Warnings should name observable symptoms, not root-cause claims:

- `speakerCountBelowHint`
- `speakerCountAboveHint`
- `lowSystemDiarizedCoverage`
- `highFallbackAssignmentRate`
- `highSourceOnlyWordRate`

Each warning should include the threshold used in the report payload. Avoid
warnings such as `excessiveSpeakerSwitchRate` until a local fixture set proves
that the metric is useful. Rapid speaker switching may be real conversation.

### CLI Surface

Start with:

```text
macparakeet-cli transcribe ... --diarization-report <path>
```

This report is computed while the fresh raw diarizer output and assignment
summary are still in memory.

Defer:

```text
macparakeet-cli meetings diarization-report <id>
```

That command requires persistence changes first.

## Phase 4: Minimal Speaker Label Provenance

Keep current inline rename behavior, but record where labels came from.

Extend `SpeakerInfo` with optional fields only:

```swift
public enum SpeakerLabelSource: String, Codable, Sendable {
    case modelDefault
    case user
}

public struct SpeakerInfo: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var source: AudioSource?
    public var rawProviderSpeakerId: String?
    public var labelSource: SpeakerLabelSource?
}
```

Because `speakers` is JSON and new fields are optional, this can remain
backward-compatible with existing rows.

Behavior:

- model-created speakers use `labelSource = .modelDefault`
- user rename sets `labelSource = .user`
- raw provider IDs remain stable even after labels change
- exports continue to use display labels
- JSON output can expose raw IDs and label provenance

Defer participant assignment fields and UI. There is no shown participant model
to anchor them cleanly, names can become stale, and participant identity is a
separate layer from speaker label provenance.

## Phase 5: Private Evaluation Harness

Add a repeatable local evaluation path before tuning thresholds or exposing
quality profiles.

Support private, untracked fixtures:

```text
fixtures/private/diarization/
  two-remote-speakers/
    system.wav
    expected.json
    reference.rttm       # optional, only when real labels exist
```

`expected.json` can start coarse:

```json
{
  "expectedRemoteSpeakers": 2,
  "maxSourceOnlyWordRate": 0.15,
  "notes": "Two speakers, no overlap"
}
```

The harness should:

- run default config
- run exact/min/max speaker-count variants
- emit `DiarizationQualityReport` for each run
- compute DER/JER only when an RTTM reference is present

Do not treat expected speaker count as a benchmark. It is a coarse symptom
check, not ground truth.

## Deferred Work

These are intentionally not in the first implementation:

- user-facing quality profiles
- raw clustering threshold or VBx tuning UI
- meeting-level expected speaker count UI
- participant assignment menu
- `assignedParticipantName` or participant fields on `SpeakerInfo`
- stored-meeting `diarization-report` without persisted raw diarizer output
- cloud/provider diarization productization

## Implementation Order

1. Add `SpeakerID` helper and tests for source-prefixed speaker IDs.
2. Add `DiarizationOptions` with `SpeakerCountHint` only.
3. Change `DiarizationServiceProtocol` so options cannot be silently ignored.
4. Map hints onto a copy of the injected base config.
5. Add CLI `--speakers`, `--min-speakers`, and `--max-speakers`.
6. Replace `SpeakerMerger` with `SpeakerWordAssigner`.
7. Use conservative, ambiguity-aware fallback assignment for system diarization.
8. Fix `buildDiarizationSegments` for leading source-only/unassigned words.
9. Add fresh-run `--diarization-report <path>`.
10. Extend `SpeakerInfo` minimally with source/raw-ID/label-source metadata.
11. Add the private fixture harness.
12. Reconsider stored-meeting reports and quality profiles only after raw state
    and fixtures exist.

## Acceptance Criteria

1. A known two-remote-speaker file can be transcribed with `--speakers 2`, and
   the fresh-run report records the requested hint and detected speaker count.
2. Invalid speaker hint combinations fail before transcription starts.
3. Existing no-hint behavior remains the default.
4. Word assignment reports direct, fallback, source-only, and unassigned counts.
5. Fallback assignment refuses ambiguous nearby speakers.
6. Meeting microphone words are never assigned from system diarization.
7. A leading source-only/unassigned word does not drop later diarization
   segments.
8. Speaker rename remains backward-compatible with existing transcripts and sets
   `labelSource = .user` for renamed speakers.
9. No transcript text, audio path, URL, or speaker label is added to telemetry
   or diagnostic logs.
10. The first report surface is fresh-run only; stored-meeting reports are not
    shipped until raw diarizer state is persisted.

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
3. Compare requested hint, detected speaker count, assignment coverage, and
   source-only rate.
4. Retranscribe a meeting with isolated `system.m4a` and confirm the hint
   applies only to remote/system speakers.
5. Rename a speaker and confirm exports show the display label while JSON still
   preserves the raw speaker ID and label source.
