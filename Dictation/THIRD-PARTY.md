# Third-party notices

`CLAUDE.md` Part 1: *"Attribution is mandatory... Do this at the moment of
reuse, not later."* This file was empty until 2026-09-14, while two
dependencies were already shipping. That is fixed here rather than excused.

Nothing in this list is vendored source. Each is a Swift package resolved at
build time, or a model downloaded to the user's own machine at runtime, and
each keeps its own licence.

---

## FluidAudio — Apache-2.0

- Source: https://github.com/FluidInference/FluidAudio
- Version: pinned exactly at `0.15.7`
- Used for: Parakeet TDT v3 speech recognition on device (`AsrManager`,
  `AsrModels`, `AudioConverter`).

```
Copyright (c) FluidInference

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

FluidAudio pulls one binary artifact of its own, `NemoTextProcessing`
(https://github.com/FluidInference/text-processing-rs, v0.3.0), used for
inverse text normalisation. It is fetched by SwiftPM at resolve time.

## Parakeet TDT 0.6B v3 model weights — CC-BY-4.0

- CoreML conversion: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- Upstream weights: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 (NVIDIA)
- Downloaded once to the user's own machine, on request. Never redistributed
  inside the app bundle.

Attribution, as CC-BY-4.0 requires: speech recognition uses NVIDIA's
**Parakeet TDT 0.6B v3**, converted to CoreML by **FluidInference**. The
weights are used unmodified; the CoreML conversion is FluidInference's
change, not ours.

> **Unresolved, and deliberately recorded rather than assumed away.** The
> model card contradicts itself. Its machine-readable front matter says
> `license: cc-by-4.0`; a "## License" section further down the same page
> says "Apache 2.0". Upstream NVIDIA publishes the weights as `cc-by-4.0`,
> and a downstream converter cannot relicense them by writing a different
> sentence in a card, so **CC-BY-4.0 is what this project honours** — it
> permits commercial use and requires the credit given above, which costs us
> nothing to give. Confirm with FluidInference before making any public
> licence claim about the model.

## WhisperKit — MIT

- Source: https://github.com/argmaxinc/WhisperKit
- Version: `1.1.0`
- Used for: the optional Whisper recognizer ("Better hearing" before 1.42.0).
  Shipping since 1.34.0 and unattributed until now.

```
MIT License

Copyright (c) 2024 Argmax, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Whisper `large-v3-turbo` weights are downloaded once to the user's machine
from Hugging Face on request, and are never redistributed in the bundle.

## Not used

`CLAUDE.md` Part 1 bans GPL code outright. **FluidVoice (GPL-3.0) is
reference reading only** — no line of it is copied or paraphrased here, and
any mechanism that came from reading it was reimplemented from described
behaviour. **Yap (MIT)** was read for the same reason; if any of its code is
ever reused, its copyright notice belongs here and in the file that reuses it.
