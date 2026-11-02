#!/usr/bin/env bash
# Check the namespace and Demo Production; login availability alone does not imply health.
set -euo pipefail
output=$(iris session IRIS -U WECHAT <<'IRIS'
write !,"WECHAT_HEALTH=",##class(WeChat.Util.Setup).Healthy(),!
halt
IRIS
)
echo "$output" | grep -Eq '^WECHAT_HEALTH=1[[:space:]]*$'
