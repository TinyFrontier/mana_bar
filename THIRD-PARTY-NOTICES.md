# Third-party notices

Mana ships no third-party dependencies. It does, however, derive part of its
provider layer from open-source work, acknowledged below as that work's licence
requires.

## openusage

<https://github.com/robinebers/openusage> — MIT licence.

Mana's Claude and ChatGPT usage providers (`Sources/Providers/`) were written
with reference to openusage's provider implementation: the auth-store / usage-
client / mapper split, the attempt→refresh→retry-once flow, the credential
discovery order for the Claude Code and Codex CLI logins, and the response
shapes those endpoints return. The code here is an independent implementation
against Mana's own `UsageProvider` contract, but the protocol knowledge and
several algorithms (Electron `safeStorage` key derivation, window
classification by `limit_window_seconds`, `resets_at` seconds-vs-milliseconds
heuristics) follow that reference closely enough to warrant this notice.

Per openusage's `TRADEMARK.md`, the MIT licence covers the code only, not the
project's brand: the name and logo "OpenUsage" are therefore not used anywhere
in Mana, and Mana claims no affiliation with or endorsement by the openusage
project or its authors.

```
MIT License

Copyright (c) 2026 Robin Ebers

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
