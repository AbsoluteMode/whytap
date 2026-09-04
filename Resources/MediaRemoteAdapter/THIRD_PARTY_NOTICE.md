# Third-party notice: MediaRemoteAdapter

This directory vendors runtime artifacts from the **mediaremote-adapter**
project, used to read and control the macOS system "Now Playing" state without
any TCC permission prompt.

- **Project:** ungive/mediaremote-adapter
- **Source:** https://github.com/ungive/mediaremote-adapter
- **Pinned commit:** `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a` (tag `v0.7.6`)
- **License:** BSD 3-Clause

## Vendored artifacts

- `run.pl` — verbatim copy of the upstream `bin/mediaremote-adapter.pl` perl
  driver. Carries the BSD-3 header.
- `MediaRemoteAdapter.framework/` — the adapter framework built from upstream
  source at the pinned commit, **universal (x86_64 + arm64)**. Built with the
  upstream CMake project (`cmake -S . -B build -DCMAKE_BUILD_TYPE=Release &&
  cmake --build build`), which sets `CMAKE_OSX_ARCHITECTURES "x86_64;arm64"`.
  The framework's `Versions/A/MediaRemoteAdapter` Mach-O is the dlopen target
  the perl driver loads at runtime.

## License text

```
BSD 3-Clause License

Copyright (c) 2025, Jonas van den Berg and contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
