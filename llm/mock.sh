#!/usr/bin/env bash
# Stand-in for an LLM, used by the demo and the tests so that they run offline
# and give the same result every time. It ignores the prompt and prints the
# file named by ASS_MOCK_RESPONSE.
set -eu
cat >/dev/null
cat "${ASS_MOCK_RESPONSE:?set ASS_MOCK_RESPONSE to a file containing the reply}"
