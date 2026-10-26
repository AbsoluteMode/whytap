# Metadata refusal is not evidence of an exhausted OpenRouter key

The user reported “Key problem” while model requests worked. The previous
checker mapped every HTTP 403 from the free current-key endpoint to out of
credit, and all results stayed fresh for 24 hours. Feature badges read this
cache without making a model request, so a temporary metadata refusal could
keep every OpenRouter feature red while normal usage succeeded.

[OpenRouter documents](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key)
the free `GET /api/v1/key` endpoint. Its [error reference](https://github.com/OpenRouterTeam/docs/blob/main/api_reference/errors-and-debugging.mdx)
distinguishes 401 invalid credentials, 402 insufficient credits and 403 forbidden
permissions/guardrails. A 403 does not establish a credit failure.

A JSON OpenRouter error with code 403 now produces a limited-key result. An
unrecognized/HTML 403 produces a neutral unreachable result, preserving the
key and feature routes. Actual 401 and 402 classifications remain unchanged.
Healthy/limited results retain the daily free-check interval. Rejected results
retry after five minutes and unreachable checks after one minute when Settings
is revisited. No background paid probe, provider fallback or key replacement is
introduced. Synthetic HTTP/status-store/Settings tests cover classification and
recovery without user credentials or model requests.

This code defect is established independently of the exact earlier network
response: the old cached status did not retain its HTTP code or response body,
so it cannot establish whether a historical refusal was 402 or 403.
