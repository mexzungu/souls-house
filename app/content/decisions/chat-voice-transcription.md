---
title: Keep ElevenLabs for chat voice notes
slug: chat-voice-transcription
date: 2026-10-18
status: decided
summary: We tested local and cloud alternatives. For current voice-note usage, the modest saving does not justify another service or a compromise in transcription quality.
---

## What we decided

**Keep ElevenLabs for chat voice notes.** Do not build a local replacement or a duration-based hybrid at this stage. Daniel made this decision after the evaluation, with Lume's review and agreement.

We investigated CPU-local Whisper tiny, base and small, Parakeet v3 INT8, and Gemini 3.8 Flash. The current ElevenLabs path remains the best fit for our accuracy and response-time needs at current usage. This is a decision about the house's workload, not a universal ranking of speech models.

Meeting transcription remains on ElevenLabs too, but **we did not evaluate meeting alternatives**. These voice-note tests establish nothing about noisy meetings, overlapping speakers or diarization. Telegram is unchanged.

## What we measured

The local pilot used 18 English recordings from two speakers, about 20 minutes in total, on CPU with two inference threads. Tiny and base made some meaning-bearing wording mistakes; small was the stronger consistent local candidate but slower. The tested Parakeet setup omitted substantial content in some notes. A second chunk-size test did not resolve that reliably.

We then timed four recordings against the existing ElevenLabs-backed chat endpoint and Gemini:

| Recording length | Existing ElevenLabs-backed chat | Local base | Local small | Gemini 3.8 Flash |
|---|---:|---:|---:|---:|
| 12 seconds | 1.14 s | 0.82 s | 2.36 s | 2.54 s |
| 30 seconds | 1.54 s | 1.10 s | 3.24 s | 3.00 s |
| 1m08s | 2.80 s | 2.91 s | 8.47 s | 3.82 s |
| 4m47s | 7.02 s | 10.15 s | 26.80 s | No transcript |

These are individual measurements, not averages. The existing-chat measurement includes server upload, the ElevenLabs call and audio storage, but not a person's phone connection or rendering. Local times include decoding and inference only; a deployed worker would add overhead. Gemini times measure its API request.

Gemini blocked the longest clip with `blockReason: OTHER` after 7.37 seconds; the cause is unspecified. An HTTP success was not a successful transcription. The first ElevenLabs attempt on the 1m08s clip returned an HTTP error; the table shows the successful retry. Its initial status and duration were not captured, so its cause remains unknown.

On the three clips Gemini completed, disagreement with saved messages was 1.3% for ElevenLabs, 6.0% for Gemini and 12.0% for both local candidates. **These are not independently verified error rates:** saved messages were possibly edited and originated in the existing transcription workflow, favouring ElevenLabs. The proposed audio-grounded base-versus-small meaning check was not completed. We stopped because the realistic saving did not warrant building another service, not because the pilot proved universal accuracy superiority.

## Why not a hybrid?

A scan of 405 saved voice notes across 286 active and archived account conversations found 274 minutes of audio and a median note length of 21 seconds.

- Routing notes below 30 seconds locally would move **61% of requests but only 18% of audio minutes** off ElevenLabs.
- Routing notes below one minute locally would move **79% of requests and 37% of audio minutes**.

For the proposed small-below-30-seconds hybrid, October-to-date usage projected about **80 transcription minutes saved per 30-day month**; the busier last week's rate projected about **110 minutes**. These are historical usage projections, not guaranteed savings or a cash estimate. The corpus excludes deleted and unsent recordings and is not a billing ledger.

That saving is not worth maintaining a resident model in RAM, a private worker, another transcription route and its failure handling. A roughly three-second wait for short notes would have been acceptable; the limited benefit, quality uncertainty and added maintenance decided it.

## What would change the decision?

A deployment that must not depend on ElevenLabs has a different requirement and could revisit the local work. A substantial change in usage, price or model capability could also warrant a fresh decision. No further benchmarking or implementation is scheduled.

[Preserving the original audio when transcription fails (#453)](https://github.com/swombat/souls-house/issues/453) is a separate reliability concern with the existing path, not a reason to change providers.

## Evidence and return point

- [Research and implementation-scope issue #451](https://github.com/swombat/souls-house/issues/451), closed as not planned.
- [Local-model research report](/api/v1/conversations/wYGGEY/messages/YLWvxe/attachments/3317) and [Gemini comparison report](/api/v1/conversations/wYGGEY/messages/eZwQrY/attachments/3323).
- [Source conversation, including the latency table, duration census and decision](/accounts/gNDMev/chats/wYGGEY).

The reports and source conversation require account access; this public page does not publish recordings or transcripts. The private benchmark harness and measurement receipts are retained with the investigation, referenced from #451; future work must obtain appropriate access rather than treating private recordings as public test fixtures.
